-- HMX Slice 7: portable in-flight work and safe task restoration.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS hmx_imported_work_refs (
    source_ref TEXT PRIMARY KEY,
    export_id TEXT NOT NULL,
    task_group TEXT NOT NULL
        CHECK (task_group IN ('consolidation_tasks', 'reconsolidation_tasks')),
    recmem_task_id UUID REFERENCES recmem_consolidation_tasks(id) ON DELETE CASCADE,
    reconsolidation_task_id UUID REFERENCES reconsolidation_tasks(id) ON DELETE CASCADE,
    source_status TEXT NOT NULL CHECK (source_status IN ('pending', 'in_progress', 'failed')),
    source_error TEXT,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    retried_at TIMESTAMPTZ,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT hmx_imported_work_ref_target CHECK (
        (task_group = 'consolidation_tasks'
            AND recmem_task_id IS NOT NULL
            AND reconsolidation_task_id IS NULL)
        OR
        (task_group = 'reconsolidation_tasks'
            AND recmem_task_id IS NULL
            AND reconsolidation_task_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_hmx_imported_work_recmem
    ON hmx_imported_work_refs (recmem_task_id)
    WHERE recmem_task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_hmx_imported_work_reconsolidation
    ON hmx_imported_work_refs (reconsolidation_task_id)
    WHERE reconsolidation_task_id IS NOT NULL;

-- Export durable task intent and diagnostics, never claim/completion state.
CREATE OR REPLACE FUNCTION hmx_export_in_flight_work() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'consolidation_tasks', COALESCE((
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'id', t.id,
                'task_type', t.task_type,
                'status', t.status,
                'created_at', t.created_at,
                'updated_at', t.updated_at,
                'input_ids', COALESCE(to_jsonb(t.source_unit_ids), '[]'::jsonb),
                'trigger_unit_id', t.trigger_unit_id,
                'target_memory_id', t.target_memory_id,
                'attempt_count', t.attempts,
                'recurrence_count', t.recurrence_count,
                'max_similarity', t.max_similarity,
                'error', t.error,
                'properties', COALESCE(t.task_payload, '{}'::jsonb)
                    - ARRAY['target_memory_id', 'source_unit_ids', 'task_id']
            )) ORDER BY t.created_at, t.id)
            FROM recmem_consolidation_tasks t
            WHERE t.status IN ('pending', 'in_progress', 'failed')
        ), '[]'::jsonb),
        'reconsolidation_tasks', COALESCE((
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'id', r.id,
                'status', r.status,
                'memory_ids', jsonb_build_array(r.belief_id),
                'reason', r.transformation_type,
                'created_at', r.created_at,
                'properties', jsonb_strip_nulls(jsonb_build_object(
                    'old_content', r.old_content,
                    'new_content', r.new_content,
                    'error', r.error_message
                ))
            )) ORDER BY r.created_at, r.id)
            FROM reconsolidation_tasks r
            WHERE r.status IN ('pending', 'in_progress', 'failed')
        ), '[]'::jsonb)
    );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_restore_imported_unit_routes(
    p_unit_ids UUID[],
    p_task_type TEXT,
    p_task_id UUID,
    p_source_status TEXT
) RETURNS INT AS $$
DECLARE
    affected INT := 0;
BEGIN
    UPDATE subconscious_units u
    SET route_status = CASE p_task_type
            WHEN 'episode_merge' THEN 'merge_queued'
            WHEN 'episode_create' THEN 'create_queued'
            ELSE CASE
                WHEN u.metadata#>>'{hmx,source_route_status}' IN (
                    'raw_only', 'merged', 'episode_created'
                ) THEN u.metadata#>>'{hmx,source_route_status}'
                ELSE 'raw_only'
            END
        END,
        route_result = COALESCE(u.route_result, '{}'::jsonb)
            || jsonb_build_object(
                'hmx_imported_task_id', p_task_id,
                'hmx_imported_task_status', p_source_status
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE u.id = ANY(COALESCE(p_unit_ids, '{}'::uuid[]))
      AND u.status = 'active';
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_in_flight_work(
    p_work JSONB,
    p_export_id TEXT,
    p_ref_map JSONB,
    p_retry_failed BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    ref_value TEXT;
    mapped_value TEXT;
    current_source_ref TEXT;
    source_status TEXT;
    task_type TEXT;
    source_ids UUID[];
    trigger_unit_id UUID;
    target_memory_id UUID;
    belief_id UUID;
    local_task_id UUID;
    existing hmx_imported_work_refs%ROWTYPE;
    missing_refs JSONB;
    properties JSONB;
    imported_status TEXT;
    attempt_count INT;
    recurrence_count INT;
    max_similarity FLOAT;
    inserted_count INT := 0;
    consolidation_count INT := 0;
    reconsolidation_count INT := 0;
    duplicate_count INT := 0;
    dropped_count INT := 0;
    failed_preserved_count INT := 0;
    requeued_count INT := 0;
    retried_count INT := 0;
    warnings JSONB := '[]'::jsonb;
    ref_map JSONB := '{}'::jsonb;
BEGIN
    FOR item IN
        SELECT value
        FROM jsonb_array_elements(COALESCE(p_work->'consolidation_tasks', '[]'::jsonb))
    LOOP
        BEGIN
            current_source_ref := item->>'ref';
            source_status := item->>'status';
            task_type := item->>'task_type';

            SELECT * INTO existing
            FROM hmx_imported_work_refs
            WHERE hmx_imported_work_refs.source_ref = current_source_ref;
            IF FOUND THEN
                IF existing.task_group <> 'consolidation_tasks' THEN
                    warnings := warnings || jsonb_build_array(jsonb_build_object(
                        'code', 'in_flight_ref_conflict',
                        'section', 'in_flight_work',
                        'ref', current_source_ref,
                        'error', 'source ref already belongs to another task group'
                    ));
                    dropped_count := dropped_count + 1;
                    CONTINUE;
                END IF;
                local_task_id := existing.recmem_task_id;
                IF p_retry_failed AND source_status = 'failed' THEN
                    UPDATE recmem_consolidation_tasks
                    SET status = 'pending',
                        started_at = NULL,
                        completed_at = NULL,
                        next_attempt_at = CURRENT_TIMESTAMP,
                        attempts = 0,
                        error = NULL,
                        task_payload = task_payload || jsonb_build_object(
                            'hmx_retry_requested_at', CURRENT_TIMESTAMP
                        ),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = local_task_id
                      AND status = 'failed';
                    IF FOUND THEN
                        UPDATE hmx_imported_work_refs
                        SET retried_at = CURRENT_TIMESTAMP
                        WHERE hmx_imported_work_refs.source_ref = current_source_ref;
                        retried_count := retried_count + 1;
                        requeued_count := requeued_count + 1;
                        PERFORM hmx_restore_imported_unit_routes(
                            (SELECT source_unit_ids FROM recmem_consolidation_tasks WHERE id = local_task_id),
                            (SELECT recmem_consolidation_tasks.task_type FROM recmem_consolidation_tasks WHERE id = local_task_id),
                            local_task_id,
                            'failed_retry_requested'
                        );
                    END IF;
                END IF;
                ref_map := ref_map || jsonb_build_object(current_source_ref, local_task_id::text);
                duplicate_count := duplicate_count + 1;
                CONTINUE;
            END IF;

            source_ids := '{}'::uuid[];
            missing_refs := '[]'::jsonb;
            FOR ref_value IN
                SELECT value FROM jsonb_array_elements_text(COALESCE(item->'input_refs', '[]'::jsonb))
            LOOP
                mapped_value := p_ref_map->>ref_value;
                BEGIN
                    IF mapped_value IS NOT NULL AND EXISTS (
                        SELECT 1 FROM subconscious_units WHERE id = mapped_value::uuid
                    ) THEN
                        source_ids := array_append(source_ids, mapped_value::uuid);
                    ELSE
                        missing_refs := missing_refs || to_jsonb(ref_value);
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    missing_refs := missing_refs || to_jsonb(ref_value);
                END;
            END LOOP;

            trigger_unit_id := NULL;
            ref_value := item->>'trigger_ref';
            IF NULLIF(ref_value, '') IS NOT NULL THEN
                mapped_value := p_ref_map->>ref_value;
                BEGIN
                    IF mapped_value IS NOT NULL AND EXISTS (
                        SELECT 1 FROM subconscious_units WHERE id = mapped_value::uuid
                    ) THEN
                        trigger_unit_id := mapped_value::uuid;
                    ELSE
                        missing_refs := missing_refs || to_jsonb(ref_value);
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    missing_refs := missing_refs || to_jsonb(ref_value);
                END;
            ELSIF cardinality(source_ids) > 0 THEN
                trigger_unit_id := source_ids[1];
            END IF;

            target_memory_id := NULL;
            IF jsonb_array_length(COALESCE(item->'output_refs', '[]'::jsonb)) > 1 THEN
                RAISE EXCEPTION 'consolidation task has more than one target memory';
            END IF;
            ref_value := item#>>'{output_refs,0}';
            IF NULLIF(ref_value, '') IS NOT NULL THEN
                mapped_value := p_ref_map->>ref_value;
                BEGIN
                    IF mapped_value IS NOT NULL AND EXISTS (
                        SELECT 1 FROM memories WHERE id = mapped_value::uuid
                    ) THEN
                        target_memory_id := mapped_value::uuid;
                    ELSE
                        missing_refs := missing_refs || to_jsonb(ref_value);
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    missing_refs := missing_refs || to_jsonb(ref_value);
                END;
            END IF;

            IF cardinality(source_ids) = 0
               OR jsonb_array_length(missing_refs) > 0
               OR (task_type = 'episode_merge' AND target_memory_id IS NULL) THEN
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'dropped_in_flight_task',
                    'section', 'in_flight_work',
                    'task_group', 'consolidation_tasks',
                    'ref', current_source_ref,
                    'reason', 'required inputs were not imported',
                    'missing_refs', missing_refs
                ));
                dropped_count := dropped_count + 1;
                CONTINUE;
            END IF;

            imported_status := CASE
                WHEN source_status = 'failed' AND NOT p_retry_failed THEN 'failed'
                ELSE 'pending'
            END;
            attempt_count := CASE
                WHEN source_status = 'failed' AND p_retry_failed THEN 0
                ELSE GREATEST(COALESCE((item->>'attempt_count')::int, 0), 0)
            END;
            recurrence_count := GREATEST(COALESCE((item->>'recurrence_count')::int, 0), 0);
            max_similarity := NULLIF(item->>'max_similarity', '')::float;
            properties := COALESCE(item->'properties', '{}'::jsonb);
            properties := properties || jsonb_build_object(
                'hmx', COALESCE(properties->'hmx', '{}'::jsonb)
                    || jsonb_strip_nulls(jsonb_build_object(
                        'export_id', p_export_id,
                        'source_ref', current_source_ref,
                        'source_status', source_status,
                        'source_error', item->>'error',
                        'imported_at', CURRENT_TIMESTAMP,
                        'retry_requested', p_retry_failed AND source_status = 'failed'
                    ))
            );

            INSERT INTO recmem_consolidation_tasks (
                created_at, updated_at, started_at, completed_at, next_attempt_at,
                status, task_type, trigger_unit_id, target_memory_id,
                source_unit_ids, recurrence_count, max_similarity, attempts,
                error, task_payload
            ) VALUES (
                COALESCE(NULLIF(item->>'created_at', '')::timestamptz, CURRENT_TIMESTAMP),
                CURRENT_TIMESTAMP, NULL, NULL, CURRENT_TIMESTAMP,
                imported_status, task_type, trigger_unit_id, target_memory_id,
                source_ids, recurrence_count, max_similarity, attempt_count,
                CASE WHEN imported_status = 'failed' THEN item->>'error' ELSE NULL END,
                properties
            ) RETURNING id INTO local_task_id;

            INSERT INTO hmx_imported_work_refs (
                source_ref, export_id, task_group, recmem_task_id,
                source_status, source_error, retried_at, details
            ) VALUES (
                current_source_ref, p_export_id, 'consolidation_tasks', local_task_id,
                source_status, item->>'error',
                CASE WHEN source_status = 'failed' AND p_retry_failed
                     THEN CURRENT_TIMESTAMP ELSE NULL END,
                jsonb_build_object('task_type', task_type)
            );
            PERFORM hmx_restore_imported_unit_routes(
                source_ids, task_type, local_task_id, source_status
            );

            ref_map := ref_map || jsonb_build_object(current_source_ref, local_task_id::text);
            inserted_count := inserted_count + 1;
            consolidation_count := consolidation_count + 1;
            IF source_status = 'failed' AND NOT p_retry_failed THEN
                failed_preserved_count := failed_preserved_count + 1;
            ELSE
                requeued_count := requeued_count + 1;
                IF source_status = 'failed' THEN
                    retried_count := retried_count + 1;
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            warnings := warnings || jsonb_build_array(jsonb_build_object(
                'code', 'invalid_in_flight_task',
                'section', 'in_flight_work',
                'task_group', 'consolidation_tasks',
                'ref', current_source_ref,
                'error', SQLERRM
            ));
            dropped_count := dropped_count + 1;
        END;
    END LOOP;

    FOR item IN
        SELECT value
        FROM jsonb_array_elements(COALESCE(p_work->'reconsolidation_tasks', '[]'::jsonb))
    LOOP
        BEGIN
            current_source_ref := item->>'ref';
            source_status := item->>'status';

            SELECT * INTO existing
            FROM hmx_imported_work_refs
            WHERE hmx_imported_work_refs.source_ref = current_source_ref;
            IF FOUND THEN
                IF existing.task_group <> 'reconsolidation_tasks' THEN
                    warnings := warnings || jsonb_build_array(jsonb_build_object(
                        'code', 'in_flight_ref_conflict',
                        'section', 'in_flight_work',
                        'ref', current_source_ref,
                        'error', 'source ref already belongs to another task group'
                    ));
                    dropped_count := dropped_count + 1;
                    CONTINUE;
                END IF;
                local_task_id := existing.reconsolidation_task_id;
                IF p_retry_failed AND source_status = 'failed' THEN
                    UPDATE reconsolidation_tasks
                    SET status = 'pending',
                        started_at = NULL,
                        completed_at = NULL,
                        error_message = NULL,
                        total_candidates = 0,
                        processed_count = 0,
                        accepted_count = 0,
                        newly_contested_count = 0,
                        still_contested_count = 0,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = local_task_id
                      AND status = 'failed';
                    IF FOUND THEN
                        UPDATE hmx_imported_work_refs
                        SET retried_at = CURRENT_TIMESTAMP
                        WHERE hmx_imported_work_refs.source_ref = current_source_ref;
                        retried_count := retried_count + 1;
                        requeued_count := requeued_count + 1;
                    END IF;
                END IF;
                ref_map := ref_map || jsonb_build_object(current_source_ref, local_task_id::text);
                duplicate_count := duplicate_count + 1;
                CONTINUE;
            END IF;

            missing_refs := '[]'::jsonb;
            belief_id := NULL;
            IF jsonb_array_length(COALESCE(item->'memory_refs', '[]'::jsonb)) <> 1 THEN
                RAISE EXCEPTION 'reconsolidation task requires exactly one belief memory';
            END IF;
            ref_value := item#>>'{memory_refs,0}';
            mapped_value := p_ref_map->>ref_value;
            BEGIN
                IF mapped_value IS NOT NULL AND EXISTS (
                    SELECT 1 FROM memories WHERE id = mapped_value::uuid
                ) THEN
                    belief_id := mapped_value::uuid;
                ELSE
                    missing_refs := missing_refs || to_jsonb(ref_value);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                missing_refs := missing_refs || to_jsonb(ref_value);
            END;

            IF belief_id IS NULL OR jsonb_array_length(missing_refs) > 0 THEN
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'dropped_in_flight_task',
                    'section', 'in_flight_work',
                    'task_group', 'reconsolidation_tasks',
                    'ref', current_source_ref,
                    'reason', 'required inputs were not imported',
                    'missing_refs', missing_refs
                ));
                dropped_count := dropped_count + 1;
                CONTINUE;
            END IF;

            properties := COALESCE(item->'properties', '{}'::jsonb);
            IF NULLIF(properties->>'old_content', '') IS NULL
               OR NULLIF(properties->>'new_content', '') IS NULL THEN
                RAISE EXCEPTION 'reconsolidation old_content and new_content are required';
            END IF;
            imported_status := CASE
                WHEN source_status = 'failed' AND NOT p_retry_failed THEN 'failed'
                ELSE 'pending'
            END;

            INSERT INTO reconsolidation_tasks (
                belief_id, old_content, new_content, transformation_type,
                status, total_candidates, processed_count, accepted_count,
                newly_contested_count, still_contested_count, error_message,
                created_at, started_at, completed_at, updated_at
            ) VALUES (
                belief_id, properties->>'old_content', properties->>'new_content',
                COALESCE(NULLIF(item->>'reason', ''), 'shift'),
                imported_status, 0, 0, 0, 0, 0,
                CASE WHEN imported_status = 'failed' THEN properties->>'error' ELSE NULL END,
                COALESCE(NULLIF(item->>'created_at', '')::timestamptz, CURRENT_TIMESTAMP),
                NULL, NULL, CURRENT_TIMESTAMP
            ) RETURNING id INTO local_task_id;

            INSERT INTO hmx_imported_work_refs (
                source_ref, export_id, task_group, reconsolidation_task_id,
                source_status, source_error, retried_at, details
            ) VALUES (
                current_source_ref, p_export_id, 'reconsolidation_tasks', local_task_id,
                source_status, properties->>'error',
                CASE WHEN source_status = 'failed' AND p_retry_failed
                     THEN CURRENT_TIMESTAMP ELSE NULL END,
                jsonb_build_object('reason', item->>'reason')
            );

            ref_map := ref_map || jsonb_build_object(current_source_ref, local_task_id::text);
            inserted_count := inserted_count + 1;
            reconsolidation_count := reconsolidation_count + 1;
            IF source_status = 'failed' AND NOT p_retry_failed THEN
                failed_preserved_count := failed_preserved_count + 1;
            ELSE
                requeued_count := requeued_count + 1;
                IF source_status = 'failed' THEN
                    retried_count := retried_count + 1;
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            warnings := warnings || jsonb_build_array(jsonb_build_object(
                'code', 'invalid_in_flight_task',
                'section', 'in_flight_work',
                'task_group', 'reconsolidation_tasks',
                'ref', current_source_ref,
                'error', SQLERRM
            ));
            dropped_count := dropped_count + 1;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'inserted', inserted_count,
        'consolidation_tasks', consolidation_count,
        'reconsolidation_tasks', reconsolidation_count,
        'duplicates', duplicate_count,
        'dropped', dropped_count,
        'failed_preserved', failed_preserved_count,
        'requeued', requeued_count,
        'retried', retried_count,
        'ref_map', ref_map,
        'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;
