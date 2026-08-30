-- HMX Slice 2: additive import primitives and target-state diagnostics.
-- Self-contained forward delta; baseline mirrors live in db/04 and db/48.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION assign_to_episode()
RETURNS TRIGGER AS $$
DECLARE
    current_episode_id UUID;
    last_memory_time TIMESTAMPTZ;
    new_seq INT;
BEGIN
    -- HMX imports reconstruct their exported episode topology explicitly.
    -- Auto-assignment here would attach each imported memory to ambient local
    -- state before the importer's ID remap is complete.
    IF NEW.metadata->>'embedding_status' = 'pending_import' THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('episode_manager'));
    SELECT e.id INTO current_episode_id
    FROM episodes e
    WHERE e.ended_at IS NULL
    ORDER BY e.started_at DESC
    LIMIT 1;
    IF current_episode_id IS NOT NULL THEN
        SELECT MAX(m.created_at), COALESCE(MAX(fem.sequence_order), 0)
        INTO last_memory_time, new_seq
        FROM find_episode_memories_graph(current_episode_id) fem
        JOIN memories m ON fem.memory_id = m.id;

        new_seq := COALESCE(new_seq, 0) + 1;
    END IF;
    IF current_episode_id IS NULL OR
       (last_memory_time IS NOT NULL AND NEW.created_at - last_memory_time > INTERVAL '30 minutes')
    THEN
        IF current_episode_id IS NOT NULL THEN
            UPDATE episodes
            SET ended_at = last_memory_time
            WHERE id = current_episode_id;
        END IF;
        INSERT INTO episodes (started_at, metadata)
        VALUES (NEW.created_at, jsonb_build_object('episode_type', 'autonomous'))
        RETURNING id INTO current_episode_id;

        new_seq := 1;
    END IF;
    PERFORM link_memory_to_episode_graph(NEW.id, current_episode_id, new_seq);
    INSERT INTO memory_neighborhoods (memory_id, is_stale)
    VALUES (NEW.id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION hexis_instance_is_empty() RETURNS JSONB AS $$
DECLARE
    blockers JSONB := '[]'::jsonb;
    details JSONB;
    row_count BIGINT;
    table_name TEXT;
    graph_count BIGINT := 0;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'kind', 'protected_memory',
        'id', m.id,
        'type', m.type,
        'acquisition_mode', COALESCE(m.metadata#>>'{provenance,acquisition_mode}', 'missing')
    )), '[]'::jsonb)
    INTO details
    FROM memories m
    WHERE m.type IN ('worldview', 'goal')
      AND COALESCE(m.metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
    blockers := blockers || details;

    SELECT count(*) INTO row_count FROM emotional_triggers;
    IF row_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'emotional_triggers', 'count', row_count,
            'reason', 'emotional trigger provenance is not bootstrap'
        ));
    END IF;

    SELECT count(*) INTO row_count
    FROM drives
    WHERE abs(current_level - baseline) > 0.000001 OR last_satisfied IS NOT NULL;
    IF row_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'experienced_drive_state', 'count', row_count
        ));
    END IF;

    BEGIN
        SELECT replace(n::text, '"', '')::bigint INTO graph_count
        FROM ag_catalog.cypher('memory_graph', $q$
            MATCH (n)
            WHERE n:SelfNode OR n:LifeChapterNode OR n:TurningPointNode
               OR n:NarrativeThreadNode OR n:ValueConflictNode
            RETURN count(n)
        $q$) AS (n ag_catalog.agtype);
    EXCEPTION WHEN OTHERS THEN
        graph_count := 0;
    END;
    IF graph_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'identity_or_narrative_graph', 'count', graph_count
        ));
    END IF;

    FOREACH table_name IN ARRAY ARRAY[
        'protected_replacement_audit',
        'protected_section_verified_audit',
        'protected_replacement_reversion_audit',
        'hmx_consent'
    ] LOOP
        IF to_regclass('public.' || table_name) IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM %I', table_name) INTO row_count;
            IF row_count > 0 THEN
                blockers := blockers || jsonb_build_array(jsonb_build_object(
                    'kind', 'protected_audit', 'table', table_name, 'count', row_count
                ));
            END IF;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'is_empty', jsonb_array_length(blockers) = 0,
        'state', CASE WHEN jsonb_array_length(blockers) = 0 THEN 'empty' ELSE 'active' END,
        'blockers', blockers
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION hmx_import_memories(p_records JSONB) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    local_id UUID;
    source_ref TEXT;
    metadata JSONB;
    ref_map JSONB := '{}'::jsonb;
    duplicate_refs JSONB := '[]'::jsonb;
    errors JSONB := '[]'::jsonb;
    inserted_count INT := 0;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        BEGIN
            source_ref := item->>'ref';
            IF NULLIF(source_ref, '') IS NULL OR NULLIF(item->>'content', '') IS NULL THEN
                RAISE EXCEPTION 'memory ref and content are required';
            END IF;

            SELECT m.id INTO local_id
            FROM memories m
            WHERE regexp_replace(lower(btrim(m.content)), '\s+', ' ', 'g') =
                  item->>'_transient_normalized_content'
            ORDER BY m.created_at, m.id
            LIMIT 1;

            IF local_id IS NOT NULL THEN
                ref_map := ref_map || jsonb_build_object(source_ref, local_id::text);
                duplicate_refs := duplicate_refs || jsonb_build_array(source_ref);
                CONTINUE;
            END IF;

            metadata := COALESCE(item->'metadata', '{}'::jsonb)
                || jsonb_build_object(
                    'embedding_status', 'pending_import',
                    'hmx', COALESCE(item->'metadata'->'hmx', '{}'::jsonb)
                        || jsonb_build_object('content_hash_v1', item->>'content_hash_v1')
                );
            metadata := jsonb_set(
                metadata,
                '{provenance}',
                COALESCE(item->'provenance', '{}'::jsonb),
                true
            );

            INSERT INTO memories (
                type, status, content, embedding, importance, trust_level,
                decay_rate, created_at, updated_at, valid_from, valid_until,
                access_count, last_accessed, source_attribution, metadata
            ) VALUES (
                (item->>'type')::memory_type,
                CASE WHEN item->>'status' IN ('active','archived','invalidated','staged')
                     THEN (item->>'status')::memory_status ELSE 'active'::memory_status END,
                item->>'content',
                array_fill(0.0::float, ARRAY[embedding_dimension()])::vector,
                COALESCE((item->>'importance')::float, 0.5),
                LEAST(1.0, GREATEST(0.0, COALESCE((item->>'trust_level')::float, 0.5))),
                COALESCE((item->>'decay_rate')::float, 0.01),
                COALESCE((item->>'created_at')::timestamptz, CURRENT_TIMESTAMP),
                COALESCE((item->>'updated_at')::timestamptz,
                         (item->>'created_at')::timestamptz, CURRENT_TIMESTAMP),
                NULLIF(item->>'valid_from', '')::timestamptz,
                NULLIF(item->>'valid_until', '')::timestamptz,
                GREATEST(COALESCE((item->>'access_count')::int, 0), 0),
                NULLIF(item->>'last_accessed', '')::timestamptz,
                COALESCE(item->'source_attribution', '{}'::jsonb),
                metadata
            ) RETURNING id INTO local_id;

            PERFORM sync_memory_node(local_id);
            INSERT INTO memory_neighborhoods (memory_id, is_stale)
            VALUES (local_id, TRUE)
            ON CONFLICT (memory_id) DO UPDATE SET is_stale = TRUE;

            ref_map := ref_map || jsonb_build_object(source_ref, local_id::text);
            inserted_count := inserted_count + 1;
        EXCEPTION WHEN OTHERS THEN
            errors := errors || jsonb_build_array(jsonb_build_object(
                'ref', source_ref, 'error', SQLERRM
            ));
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'ref_map', ref_map,
        'inserted', inserted_count,
        'duplicate_refs', duplicate_refs,
        'errors', errors
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_episodes(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    memory_ref JSONB;
    episode_id UUID;
    memory_id UUID;
    source_ref TEXT;
    ref_map JSONB := COALESCE(p_ref_map, '{}'::jsonb);
    warnings JSONB := '[]'::jsonb;
    inserted_count INT := 0;
    sequence_order INT;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        source_ref := item->>'ref';
        INSERT INTO episodes (started_at, ended_at, summary, metadata)
        VALUES (
            COALESCE((item->>'started_at')::timestamptz, CURRENT_TIMESTAMP),
            NULLIF(item->>'ended_at', '')::timestamptz,
            item->>'summary',
            COALESCE(item->'metadata', '{}'::jsonb)
        ) RETURNING id INTO episode_id;
        PERFORM sync_episode_node(episode_id);
        ref_map := ref_map || jsonb_build_object(source_ref, episode_id::text);
        inserted_count := inserted_count + 1;
        sequence_order := 0;

        FOR memory_ref IN SELECT value FROM jsonb_array_elements(COALESCE(item->'memory_refs', '[]'::jsonb))
        LOOP
            sequence_order := sequence_order + 1;
            BEGIN
                memory_id := (ref_map->>trim(both '"' from memory_ref::text))::uuid;
            EXCEPTION WHEN OTHERS THEN
                memory_id := NULL;
            END;
            IF memory_id IS NULL THEN
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'orphaned_reference',
                    'section', 'episodes',
                    'ref', trim(both '"' from memory_ref::text)
                ));
            ELSE
                PERFORM link_memory_to_episode_graph(memory_id, episode_id, sequence_order);
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'ref_map', ref_map, 'inserted', inserted_count, 'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_clusters(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    member_ref JSONB;
    cluster_id UUID;
    memory_id UUID;
    source_ref TEXT;
    ref_map JSONB := COALESCE(p_ref_map, '{}'::jsonb);
    warnings JSONB := '[]'::jsonb;
    inserted_count INT := 0;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        source_ref := item->>'ref';
        INSERT INTO clusters (cluster_type, name, centroid_embedding)
        VALUES (
            COALESCE(NULLIF(item->>'cluster_type', ''), 'mixed')::cluster_type,
            COALESCE(NULLIF(item->>'name', ''), 'Imported cluster'),
            NULL
        ) RETURNING id INTO cluster_id;
        PERFORM sync_cluster_node(cluster_id);
        ref_map := ref_map || jsonb_build_object(source_ref, cluster_id::text);
        inserted_count := inserted_count + 1;

        FOR member_ref IN SELECT value FROM jsonb_array_elements(COALESCE(item->'member_refs', '[]'::jsonb))
        LOOP
            BEGIN
                memory_id := (ref_map->>trim(both '"' from member_ref::text))::uuid;
            EXCEPTION WHEN OTHERS THEN
                memory_id := NULL;
            END;
            IF memory_id IS NULL THEN
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'orphaned_reference',
                    'section', 'clusters',
                    'ref', trim(both '"' from member_ref::text)
                ));
            ELSE
                PERFORM link_memory_to_cluster_graph(memory_id, cluster_id, 1.0);
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'ref_map', ref_map, 'inserted', inserted_count, 'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_relationships(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    source_id TEXT;
    target_id TEXT;
    source_type TEXT;
    target_type TEXT;
    edge_type TEXT;
    props JSONB;
    inserted_count INT := 0;
    duplicate_count INT := 0;
    affected_count INT;
    warnings JSONB := '[]'::jsonb;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        source_id := p_ref_map->>(item->>'source_ref');
        target_id := p_ref_map->>(item->>'target_ref');
        IF source_id IS NULL OR target_id IS NULL THEN
            warnings := warnings || jsonb_build_array(jsonb_build_object(
                'code', 'orphaned_reference',
                'section', 'relationships',
                'source_ref', item->>'source_ref',
                'target_ref', item->>'target_ref'
            ));
            CONTINUE;
        END IF;

        props := COALESCE(item->'properties', '{}'::jsonb);
        source_type := COALESCE(NULLIF(props->>'source_type', ''), 'memory');
        target_type := COALESCE(NULLIF(props->>'target_type', ''), 'memory');
        edge_type := item->>'edge_type';

        INSERT INTO memory_edges (
            src_type, src_id, rel_type, dst_type, dst_id,
            weight, kind, source, properties
        ) VALUES (
            source_type, source_id, edge_type, target_type, target_id,
            COALESCE((props->>'weight')::float, (props->>'strength')::float, 1.0),
            props->>'kind', props->>'source', props
        ) ON CONFLICT (src_type, src_id, rel_type, dst_type, dst_id) DO NOTHING;
        GET DIAGNOSTICS affected_count = ROW_COUNT;
        IF affected_count = 1 THEN
            inserted_count := inserted_count + 1;
        ELSE
            duplicate_count := duplicate_count + 1;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
            WHERE t.typname = 'graph_edge_type' AND e.enumlabel = edge_type
        ) THEN
            warnings := warnings || jsonb_build_array(jsonb_build_object(
                'code', 'unknown_edge_type', 'edge_type', edge_type
            ));
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'inserted', inserted_count,
        'duplicates', duplicate_count,
        'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;


