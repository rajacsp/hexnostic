-- HMX Slice 2: protected-section provenance and empty-target import.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE drives ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE emotional_triggers ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

UPDATE drives
SET metadata = jsonb_build_object(
    'replaceable_during_bootstrap', true,
    'provenance', jsonb_build_object('acquisition_mode', 'bootstrap')
)
WHERE metadata->'provenance' IS NULL;

UPDATE emotional_triggers
SET metadata = jsonb_set(
    metadata, '{provenance}', jsonb_build_object('acquisition_mode', 'experienced'), true
)
WHERE metadata->'provenance' IS NULL;

CREATE OR REPLACE FUNCTION hmx_export_drives() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name', d.name,
        'description', d.description,
        'current_level', d.current_level,
        'baseline', d.baseline,
        'accumulation_rate', d.accumulation_rate,
        'decay_rate', d.decay_rate,
        'satisfaction_cooldown', d.satisfaction_cooldown::text,
        'last_satisfied', d.last_satisfied,
        'urgency_threshold', d.urgency_threshold,
        'metadata', d.metadata
    ) ORDER BY d.name), '[]'::jsonb)
    FROM drives d;
$$ LANGUAGE sql STABLE;

-- Emotional triggers (protected). Embedding omitted by design.
CREATE OR REPLACE FUNCTION hmx_export_emotional_triggers() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', t.id,
        'trigger_pattern', t.trigger_pattern,
        'valence_delta', t.valence_delta,
        'arousal_delta', t.arousal_delta,
        'dominance_delta', t.dominance_delta,
        'typical_emotion', t.typical_emotion,
        'confidence', t.confidence,
        'times_activated', t.times_activated,
        'origin', t.origin,
        'source_memory_ids', COALESCE(to_jsonb(t.source_memory_ids), '[]'::jsonb),
        'metadata', t.metadata
    ) ORDER BY t.trigger_pattern, t.id), '[]'::jsonb)
    FROM emotional_triggers t;
$$ LANGUAGE sql STABLE;

-- Clusters without centroid embeddings (recomputed on import).

CREATE OR REPLACE FUNCTION hmx_export_narrative() RETURNS JSONB AS $$
DECLARE
    chapters JSONB;
    turning_points JSONB;
    threads JSONB;
    conflicts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        (props::text::jsonb - 'hmx_payload')
        || COALESCE(NULLIF(props::text::jsonb->>'hmx_payload', '')::jsonb, '{}'::jsonb)
        || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO chapters
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:LifeChapterNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        (props::text::jsonb - 'hmx_payload')
        || COALESCE(NULLIF(props::text::jsonb->>'hmx_payload', '')::jsonb, '{}'::jsonb)
        || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO turning_points
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:TurningPointNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        (props::text::jsonb - 'hmx_payload')
        || COALESCE(NULLIF(props::text::jsonb->>'hmx_payload', '')::jsonb, '{}'::jsonb)
        || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO threads
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:NarrativeThreadNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        (props::text::jsonb - 'hmx_payload')
        || COALESCE(NULLIF(props::text::jsonb->>'hmx_payload', '')::jsonb, '{}'::jsonb)
        || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO conflicts
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:ValueConflictNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    RETURN jsonb_build_object(
        'life_chapters', chapters,
        'turning_points', turning_points,
        'narrative_threads', threads,
        'value_conflicts', conflicts
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Identity (protected): the self-model facets plus the initialized profile.
CREATE OR REPLACE FUNCTION hmx_export_identity() RETURNS JSONB AS $$
DECLARE
    profile JSONB;
    facets JSONB;
BEGIN
    SELECT value->'agent' INTO profile FROM config WHERE key = 'agent.init_profile';
    facets := get_self_model_context(200);
    RETURN jsonb_build_array(jsonb_build_object(
        'key', 'core_identity',
        'content', COALESCE(profile->>'description', ''),
        'profile', COALESCE(profile, '{}'::jsonb),
        'facets', COALESCE(facets, '[]'::jsonb),
        'metadata', jsonb_build_object(
            'provenance', COALESCE(
                (SELECT value FROM config WHERE key = 'agent.hmx_identity_provenance'),
                jsonb_build_object('acquisition_mode', 'experienced')
            )
        )
    ));
END;
$$ LANGUAGE plpgsql STABLE;

-- In-flight work (port/duplicate): memories-in-becoming.

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

    SELECT count(*) INTO row_count
    FROM emotional_triggers
    WHERE COALESCE(metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
    IF row_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'emotional_triggers', 'count', row_count,
            'reason', 'emotional trigger provenance is not bootstrap'
        ));
    END IF;

    SELECT count(*) INTO row_count
    FROM drives
    WHERE COALESCE(metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
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


CREATE OR REPLACE FUNCTION hmx_mark_drive_experienced() RETURNS TRIGGER AS $$
BEGIN
    IF OLD.metadata#>>'{provenance,acquisition_mode}' = 'bootstrap'
       AND NEW.metadata = OLD.metadata
       AND (NEW.current_level IS DISTINCT FROM OLD.current_level
            OR NEW.baseline IS DISTINCT FROM OLD.baseline
            OR NEW.last_satisfied IS DISTINCT FROM OLD.last_satisfied) THEN
        NEW.metadata := jsonb_set(
            jsonb_set(NEW.metadata, '{provenance,acquisition_mode}', '"experienced"'::jsonb, true),
            '{replaceable_during_bootstrap}', 'false'::jsonb, true
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_default_emotional_trigger_provenance() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.metadata->'provenance' IS NULL THEN
        NEW.metadata := jsonb_set(
            COALESCE(NEW.metadata, '{}'::jsonb),
            '{provenance}',
            jsonb_build_object('acquisition_mode', 'experienced'),
            true
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_drives(p_records JSONB) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    inserted_count INT := 0;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        INSERT INTO drives (
            name, description, current_level, baseline, accumulation_rate,
            decay_rate, satisfaction_cooldown, last_satisfied,
            urgency_threshold, metadata
        ) VALUES (
            item->>'name', item->>'description',
            COALESCE((item->>'current_level')::float, 0.5),
            COALESCE((item->>'baseline')::float, 0.5),
            COALESCE((item->>'accumulation_rate')::float, 0.01),
            COALESCE((item->>'decay_rate')::float, 0.05),
            COALESCE(NULLIF(item->>'satisfaction_cooldown', '')::interval, '1 hour'::interval),
            NULLIF(item->>'last_satisfied', '')::timestamptz,
            COALESCE((item->>'urgency_threshold')::float, 0.8),
            jsonb_set(
                COALESCE(item->'metadata', '{}'::jsonb),
                '{provenance}', COALESCE(item->'provenance', '{}'::jsonb), true
            )
        ) ON CONFLICT (name) DO UPDATE SET
            description = EXCLUDED.description,
            current_level = EXCLUDED.current_level,
            baseline = EXCLUDED.baseline,
            accumulation_rate = EXCLUDED.accumulation_rate,
            decay_rate = EXCLUDED.decay_rate,
            satisfaction_cooldown = EXCLUDED.satisfaction_cooldown,
            last_satisfied = EXCLUDED.last_satisfied,
            urgency_threshold = EXCLUDED.urgency_threshold,
            metadata = EXCLUDED.metadata;
        inserted_count := inserted_count + 1;
    END LOOP;
    RETURN jsonb_build_object('imported', inserted_count, 'warnings', '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_emotional_triggers(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    source_ref JSONB;
    source_ids UUID[];
    mapped_id UUID;
    inserted_count INT := 0;
    duplicate_count INT := 0;
    affected_count INT;
    warnings JSONB := '[]'::jsonb;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        source_ids := '{}'::uuid[];
        FOR source_ref IN SELECT value FROM jsonb_array_elements(COALESCE(item->'source_memory_refs', '[]'::jsonb))
        LOOP
            BEGIN
                mapped_id := (p_ref_map->>trim(both '"' from source_ref::text))::uuid;
            EXCEPTION WHEN OTHERS THEN
                mapped_id := NULL;
            END;
            IF mapped_id IS NULL THEN
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'orphaned_reference', 'section', 'emotional_triggers',
                    'ref', trim(both '"' from source_ref::text)
                ));
            ELSE
                source_ids := array_append(source_ids, mapped_id);
            END IF;
        END LOOP;

        IF EXISTS (
            SELECT 1 FROM emotional_triggers t
            WHERE regexp_replace(lower(btrim(t.trigger_pattern)), '\s+', ' ', 'g') =
                  item->>'_transient_normalized_content'
        ) THEN
            duplicate_count := duplicate_count + 1;
            CONTINUE;
        END IF;

        INSERT INTO emotional_triggers (
            trigger_pattern, trigger_embedding, valence_delta, arousal_delta,
            dominance_delta, typical_emotion, times_activated, confidence,
            origin, source_memory_ids, metadata
        ) VALUES (
            item->>'trigger_pattern',
            array_fill(0.0::float, ARRAY[embedding_dimension()])::vector,
            COALESCE((item->>'valence_delta')::float, 0.0),
            COALESCE((item->>'arousal_delta')::float, 0.0),
            COALESCE((item->>'dominance_delta')::float, 0.0),
            item->>'typical_emotion',
            GREATEST(COALESCE((item->>'times_activated')::int, 0), 0),
            LEAST(1.0, GREATEST(0.0, COALESCE((item->>'confidence')::float, 0.5))),
            COALESCE(NULLIF(item->>'origin', ''), 'imported'),
            source_ids,
            jsonb_set(
                COALESCE(item->'metadata', '{}'::jsonb),
                '{provenance}', COALESCE(item->'provenance', '{}'::jsonb), true
            )
        );
        GET DIAGNOSTICS affected_count = ROW_COUNT;
        inserted_count := inserted_count + affected_count;
    END LOOP;
    RETURN jsonb_build_object(
        'inserted', inserted_count, 'duplicates', duplicate_count, 'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_identity(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    facet JSONB;
    evidence_id UUID;
    imported_count INT := 0;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        PERFORM set_config(
            'agent.init_profile',
            jsonb_build_object(
                'agent', COALESCE(item->'profile', jsonb_build_object('description', item->>'content'))
            )
        );
        PERFORM set_config(
            'agent.hmx_identity_provenance', COALESCE(item->'provenance', '{}'::jsonb)
        );
        PERFORM ensure_self_node();
        FOR facet IN SELECT value FROM jsonb_array_elements(COALESCE(item->'facets', '[]'::jsonb))
        LOOP
            BEGIN
                evidence_id := (p_ref_map->>(facet->>'evidence_memory_ref'))::uuid;
            EXCEPTION WHEN OTHERS THEN
                evidence_id := NULL;
            END;
            PERFORM upsert_self_concept_edge(
                COALESCE(NULLIF(facet->>'type', ''), 'identity'),
                facet->>'concept',
                COALESCE((facet->>'strength')::float, 0.8),
                evidence_id
            );
        END LOOP;
        imported_count := imported_count + 1;
    END LOOP;
    RETURN jsonb_build_object('imported', imported_count, 'warnings', '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_narrative(
    p_data JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    group_name TEXT;
    label_name TEXT;
    item JSONB;
    local_id UUID;
    ref_field TEXT;
    source_ref JSONB;
    mapped_refs JSONB;
    payload JSONB;
    ref_map JSONB := COALESCE(p_ref_map, '{}'::jsonb);
    imported_count INT := 0;
    warnings JSONB := '[]'::jsonb;
BEGIN
    -- Allocate every narrative ID first so cross-node references can resolve
    -- regardless of subsection or record order.
    FOREACH group_name IN ARRAY ARRAY[
        'life_chapters', 'turning_points', 'narrative_threads', 'value_conflicts'
    ] LOOP
        FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_data->group_name, '[]'::jsonb))
        LOOP
            ref_map := ref_map || jsonb_build_object(item->>'ref', gen_random_uuid()::text);
        END LOOP;
    END LOOP;

    FOREACH group_name IN ARRAY ARRAY[
        'life_chapters', 'turning_points', 'narrative_threads', 'value_conflicts'
    ] LOOP
        label_name := CASE group_name
            WHEN 'life_chapters' THEN 'LifeChapterNode'
            WHEN 'turning_points' THEN 'TurningPointNode'
            WHEN 'narrative_threads' THEN 'NarrativeThreadNode'
            WHEN 'value_conflicts' THEN 'ValueConflictNode'
        END;
        FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_data->group_name, '[]'::jsonb))
        LOOP
            local_id := (ref_map->>(item->>'ref'))::uuid;
            payload := item - 'ref';
            FOREACH ref_field IN ARRAY ARRAY[
                'memory_refs', 'chapter_refs', 'supporting_refs', 'contesting_refs'
            ] LOOP
                IF payload ? ref_field THEN
                    mapped_refs := '[]'::jsonb;
                    FOR source_ref IN SELECT value FROM jsonb_array_elements(COALESCE(payload->ref_field, '[]'::jsonb))
                    LOOP
                        IF ref_map ? trim(both '"' from source_ref::text) THEN
                            mapped_refs := mapped_refs || jsonb_build_array(
                                ref_map->>trim(both '"' from source_ref::text)
                            );
                        ELSE
                            warnings := warnings || jsonb_build_array(jsonb_build_object(
                                'code', 'orphaned_reference', 'section', 'narrative',
                                'ref', trim(both '"' from source_ref::text)
                            ));
                        END IF;
                    END LOOP;
                    payload := jsonb_set(payload, ARRAY[ref_field], mapped_refs, true);
                END IF;
            END LOOP;
            EXECUTE format(
                'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                    CREATE (n:%s {hmx_id: %L, hmx_payload: %L}) RETURN n
                $q$) AS (n ag_catalog.agtype)',
                label_name, local_id::text, payload::text
            );
            imported_count := imported_count + 1;
        END LOOP;
    END LOOP;
    RETURN jsonb_build_object(
        'ref_map', ref_map, 'imported', imported_count, 'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;


DROP TRIGGER IF EXISTS trg_hmx_drive_provenance ON drives;
CREATE TRIGGER trg_hmx_drive_provenance
    BEFORE UPDATE ON drives
    FOR EACH ROW
    EXECUTE FUNCTION hmx_mark_drive_experienced();

DROP TRIGGER IF EXISTS trg_hmx_emotional_trigger_provenance ON emotional_triggers;
CREATE TRIGGER trg_hmx_emotional_trigger_provenance
    BEFORE INSERT ON emotional_triggers
    FOR EACH ROW
    EXECUTE FUNCTION hmx_default_emotional_trigger_provenance();
CREATE OR REPLACE FUNCTION hmx_remap_goal_references(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    blocked_ref JSONB;
    local_id UUID;
    parent_id UUID;
    blocked_ids JSONB;
    warnings JSONB := '[]'::jsonb;
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        BEGIN
            local_id := (p_ref_map->>(item->>'ref'))::uuid;
        EXCEPTION WHEN OTHERS THEN
            local_id := NULL;
        END;
        IF local_id IS NULL THEN
            CONTINUE;
        END IF;

        BEGIN
            parent_id := (p_ref_map->>(item->>'parent_ref'))::uuid;
        EXCEPTION WHEN OTHERS THEN
            parent_id := NULL;
        END;
        IF item->>'parent_ref' IS NOT NULL AND parent_id IS NULL THEN
            warnings := warnings || jsonb_build_array(jsonb_build_object(
                'code', 'orphaned_reference', 'section', 'goals',
                'ref', item->>'parent_ref'
            ));
        END IF;

        blocked_ids := '[]'::jsonb;
        FOR blocked_ref IN SELECT value FROM jsonb_array_elements(COALESCE(item->'blocked_by', '[]'::jsonb))
        LOOP
            IF p_ref_map ? trim(both '"' from blocked_ref::text) THEN
                blocked_ids := blocked_ids || jsonb_build_array(
                    p_ref_map->>trim(both '"' from blocked_ref::text)
                );
            ELSE
                warnings := warnings || jsonb_build_array(jsonb_build_object(
                    'code', 'orphaned_reference', 'section', 'goals',
                    'ref', trim(both '"' from blocked_ref::text)
                ));
            END IF;
        END LOOP;

        UPDATE memories
        SET metadata = metadata
            || jsonb_build_object('parent_goal_id', parent_id, 'blocked_by', blocked_ids)
            - 'parent_ref'
        WHERE id = local_id AND type = 'goal';
    END LOOP;
    RETURN jsonb_build_object('warnings', warnings);
END;
$$ LANGUAGE plpgsql;

