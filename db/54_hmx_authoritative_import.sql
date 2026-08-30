-- HMX Slice 10: whole-section authoritative protected-state replacement.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE hmx_pending_replacements
    ADD COLUMN IF NOT EXISTS reference_map JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(reference_map) = 'object'),
    ADD COLUMN IF NOT EXISTS snapshot_id UUID
        REFERENCES protected_replacement_snapshots(snapshot_id),
    ADD COLUMN IF NOT EXISTS execution_audit_id TEXT
        REFERENCES protected_replacement_audit(audit_id),
    ADD COLUMN IF NOT EXISTS executed_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION hmx_link_current_chapter_identity(
    p_strength FLOAT,
    p_hmx_id TEXT DEFAULT NULL,
    p_name TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    chapter_updates TEXT := '';
    linked_chapter ag_catalog.agtype;
BEGIN
    PERFORM ensure_self_node();
    IF p_name IS NOT NULL THEN
        chapter_updates := format(
            'SET c.key = ''current'', c.name = %L',
            p_name
        );
    END IF;
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MATCH (s:SelfNode {key: ''self''})
            MATCH (c:LifeChapterNode)
            WHERE c.key = ''current'' OR c.hmx_id = %L
            %s
            MERGE (s)-[r:ASSOCIATED]->(c)
            SET r.kind = ''life_chapter_current'', r.strength = %s
            RETURN r
        $q$) AS (result ag_catalog.agtype)',
        p_hmx_id,
        chapter_updates,
        LEAST(1.0, GREATEST(0.0, COALESCE(p_strength, 0.8)))
    ) INTO linked_chapter;
    IF linked_chapter IS NULL THEN
        RETURN FALSE;
    END IF;
    PERFORM upsert_memory_edge(
        'self', 'self', 'ASSOCIATED', 'life_chapter', 'current',
        p_strength, 'life_chapter_current', NULL,
        jsonb_strip_nulls(jsonb_build_object(
            'kind', 'life_chapter_current',
            'name', p_name
        ))
    );
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_identity(
    p_records JSONB,
    p_ref_map JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    facet JSONB;
    facet_kind TEXT;
    evidence_id UUID;
    imported_count INT := 0;
BEGIN
    FOR item IN
        SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        PERFORM set_config(
            'agent.init_profile',
            jsonb_build_object(
                'agent', COALESCE(
                    item->'profile',
                    jsonb_build_object('description', item->>'content')
                )
            )
        );
        PERFORM set_config(
            'agent.hmx_identity_provenance',
            COALESCE(item->'provenance', '{}'::jsonb)
        );
        PERFORM ensure_self_node();
        FOR facet IN
            SELECT value FROM jsonb_array_elements(COALESCE(item->'facets', '[]'::jsonb))
        LOOP
            facet_kind := COALESCE(
                NULLIF(facet->>'kind', ''),
                NULLIF(facet->>'type', ''),
                'identity'
            );
            BEGIN
                evidence_id := (p_ref_map->>(facet->>'evidence_memory_ref'))::uuid;
            EXCEPTION WHEN OTHERS THEN
                evidence_id := NULL;
            END;
            IF facet_kind = 'life_chapter_current' THEN
                IF NOT hmx_link_current_chapter_identity(
                    COALESCE((facet->>'strength')::float, 0.8)
                ) THEN
                    PERFORM upsert_self_concept_edge(
                        facet_kind,
                        facet->>'concept',
                        COALESCE((facet->>'strength')::float, 0.8),
                        evidence_id
                    );
                END IF;
            ELSE
                PERFORM upsert_self_concept_edge(
                    facet_kind,
                    facet->>'concept',
                    COALESCE((facet->>'strength')::float, 0.8),
                    evidence_id
                );
            END IF;
        END LOOP;
        imported_count := imported_count + 1;
    END LOOP;
    RETURN jsonb_build_object(
        'imported', imported_count,
        'warnings', '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_clear_protected_section(p_section TEXT)
RETURNS INTEGER AS $$
DECLARE
    memory_id UUID;
    affected INTEGER := 0;
BEGIN
    IF p_section NOT IN (
        'identity', 'worldview', 'goals', 'drives',
        'emotional_triggers', 'narrative'
    ) THEN
        RAISE EXCEPTION 'unsupported protected section: %', p_section;
    END IF;

    IF p_section IN ('worldview', 'goals') THEN
        IF p_section = 'goals' THEN
            DELETE FROM memory_edges
            WHERE src_type IN ('goal', 'goals_root')
               OR dst_type IN ('goal', 'goals_root');
            PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
                MATCH (g:GoalNode) DETACH DELETE g
            $cypher$) AS (result ag_catalog.agtype);
        END IF;

        FOR memory_id IN
            SELECT id FROM memories
            WHERE type::text = CASE p_section
                WHEN 'goals' THEN 'goal'
                ELSE p_section
            END
            ORDER BY created_at, id
        LOOP
            IF NOT delete_memory_fully(memory_id) THEN
                RAISE EXCEPTION 'failed to delete protected % memory %', p_section, memory_id;
            END IF;
            affected := affected + 1;
        END LOOP;
        RETURN affected;
    END IF;

    IF p_section = 'drives' THEN
        DELETE FROM drives;
        GET DIAGNOSTICS affected = ROW_COUNT;
        RETURN affected;
    END IF;

    IF p_section = 'emotional_triggers' THEN
        DELETE FROM emotional_triggers;
        GET DIAGNOSTICS affected = ROW_COUNT;
        RETURN affected;
    END IF;

    IF p_section = 'identity' THEN
        DELETE FROM memory_edges
        WHERE (src_type = 'self' AND src_id = 'self')
           OR (dst_type = 'self' AND dst_id = 'self');
        PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
            MATCH (s:SelfNode) DETACH DELETE s
        $cypher$) AS (result ag_catalog.agtype);
        DELETE FROM config
        WHERE key IN (
            'agent.init_profile',
            'agent.hmx_identity_provenance',
            'agent.self'
        );
        GET DIAGNOSTICS affected = ROW_COUNT;
        RETURN affected;
    END IF;

    DELETE FROM memory_edges
    WHERE src_type IN (
            'life_chapter', 'turning_point', 'narrative_thread', 'value_conflict'
        )
       OR dst_type IN (
            'life_chapter', 'turning_point', 'narrative_thread', 'value_conflict'
        );
    PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
        MATCH (n:LifeChapterNode) DETACH DELETE n
    $cypher$) AS (result ag_catalog.agtype);
    PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
        MATCH (n:TurningPointNode) DETACH DELETE n
    $cypher$) AS (result ag_catalog.agtype);
    PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
        MATCH (n:NarrativeThreadNode) DETACH DELETE n
    $cypher$) AS (result ag_catalog.agtype);
    PERFORM * FROM ag_catalog.cypher('memory_graph', $cypher$
        MATCH (n:ValueConflictNode) DETACH DELETE n
    $cypher$) AS (result ag_catalog.agtype);
    RETURN affected;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_protected_memories(p_records JSONB)
RETURNS JSONB AS $$
DECLARE
    item JSONB;
    local_id UUID;
    source_ref TEXT;
    metadata JSONB;
    imported_type TEXT;
    ref_map JSONB := '{}'::jsonb;
    inserted_ids UUID[] := '{}'::uuid[];
    inserted_count INTEGER := 0;
    prior_import_setting TEXT := current_setting('hexis.hmx_import', true);
BEGIN
    PERFORM pg_catalog.set_config('hexis.hmx_import', 'on', true);
    FOR item IN
        SELECT value FROM jsonb_array_elements(COALESCE(p_records, '[]'::jsonb))
    LOOP
        source_ref := NULLIF(item->>'ref', '');
        imported_type := item->>'type';
        IF source_ref IS NULL OR NULLIF(item->>'content', '') IS NULL THEN
            RAISE EXCEPTION 'protected memory ref and content are required';
        END IF;
        IF imported_type NOT IN ('worldview', 'goal') THEN
            RAISE EXCEPTION 'authoritative protected memory type must be worldview or goal';
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
            imported_type::memory_type,
            CASE WHEN item->>'status' IN ('active', 'archived', 'invalidated', 'staged')
                 THEN (item->>'status')::memory_status
                 ELSE 'active'::memory_status END,
            item->>'content',
            array_fill(0.0::float, ARRAY[embedding_dimension()])::vector,
            COALESCE((item->>'importance')::float, 0.5),
            LEAST(1.0, GREATEST(0.0, COALESCE((item->>'trust_level')::float, 0.5))),
            COALESCE((item->>'decay_rate')::float, 0.01),
            COALESCE((item->>'created_at')::timestamptz, CURRENT_TIMESTAMP),
            COALESCE(
                (item->>'updated_at')::timestamptz,
                (item->>'created_at')::timestamptz,
                CURRENT_TIMESTAMP
            ),
            NULLIF(item->>'valid_from', '')::timestamptz,
            NULLIF(item->>'valid_until', '')::timestamptz,
            GREATEST(COALESCE((item->>'access_count')::integer, 0), 0),
            NULLIF(item->>'last_accessed', '')::timestamptz,
            COALESCE(item->'source_attribution', '{}'::jsonb),
            metadata
        ) RETURNING id INTO local_id;

        IF NOT sync_memory_node(local_id) THEN
            RAISE EXCEPTION 'failed to synchronize protected memory node %', local_id;
        END IF;
        INSERT INTO memory_neighborhoods (memory_id, is_stale)
        VALUES (local_id, TRUE)
        ON CONFLICT (memory_id) DO UPDATE SET is_stale = TRUE;

        ref_map := ref_map || jsonb_build_object(source_ref, local_id::text);
        inserted_ids := array_append(inserted_ids, local_id);
        inserted_count := inserted_count + 1;
    END LOOP;

    PERFORM hmx_queue_reembed(inserted_ids);
    PERFORM pg_catalog.set_config(
        'hexis.hmx_import', COALESCE(prior_import_setting, 'off'), true
    );
    RETURN jsonb_build_object(
        'ref_map', ref_map,
        'inserted', inserted_count,
        'memory_ids', to_jsonb(inserted_ids),
        'warnings', '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_import_authoritative(
    p_sections JSONB,
    p_replace_sections TEXT[],
    p_ref_map JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    section_name TEXT;
    section_data JSONB;
    section_result JSONB;
    goal_record JSONB;
    goal_id UUID;
    parent_id UUID;
    worldview_record JSONB;
    evidence_ref JSONB;
    evidence_id UUID;
    worldview_id UUID;
    current_chapter JSONB;
    current_chapter_id TEXT;
    combined_ref_map JSONB := COALESCE(p_ref_map, '{}'::jsonb);
    warnings JSONB := '[]'::jsonb;
    results JSONB := '{}'::jsonb;
BEGIN
    IF COALESCE(cardinality(p_replace_sections), 0) = 0 THEN
        RAISE EXCEPTION 'authoritative import requires at least one protected section';
    END IF;
    IF jsonb_typeof(COALESCE(p_sections, '{}'::jsonb)) <> 'object' THEN
        RAISE EXCEPTION 'authoritative import sections must be a JSON object';
    END IF;

    FOREACH section_name IN ARRAY p_replace_sections LOOP
        IF section_name NOT IN (
            'identity', 'worldview', 'goals', 'drives',
            'emotional_triggers', 'narrative'
        ) THEN
            RAISE EXCEPTION 'unsupported protected section: %', section_name;
        END IF;
        IF NOT p_sections ? section_name THEN
            RAISE EXCEPTION 'authoritative import is missing section %', section_name;
        END IF;

        section_data := p_sections->section_name;
        PERFORM hmx_clear_protected_section(section_name);

        CASE section_name
            WHEN 'worldview' THEN
                section_result := hmx_import_protected_memories(section_data);
                combined_ref_map := combined_ref_map
                    || COALESCE(section_result->'ref_map', '{}'::jsonb);

                FOR worldview_record IN
                    SELECT value FROM jsonb_array_elements(COALESCE(section_data, '[]'::jsonb))
                LOOP
                    worldview_id := (combined_ref_map->>(worldview_record->>'ref'))::uuid;
                    FOR evidence_ref IN
                        SELECT value FROM jsonb_array_elements(
                            COALESCE(worldview_record->'supporting_refs', '[]'::jsonb)
                        )
                    LOOP
                        BEGIN
                            evidence_id := (
                                combined_ref_map->>trim(both '"' from evidence_ref::text)
                            )::uuid;
                        EXCEPTION WHEN OTHERS THEN
                            evidence_id := NULL;
                        END;
                        IF evidence_id IS NULL THEN
                            warnings := warnings || jsonb_build_array(jsonb_build_object(
                                'code', 'orphaned_reference',
                                'section', 'worldview',
                                'ref', trim(both '"' from evidence_ref::text)
                            ));
                        ELSE
                            PERFORM create_memory_relationship(
                                evidence_id, worldview_id, 'SUPPORTS', '{}'::jsonb
                            );
                        END IF;
                    END LOOP;
                    FOR evidence_ref IN
                        SELECT value FROM jsonb_array_elements(
                            COALESCE(worldview_record->'contesting_refs', '[]'::jsonb)
                        )
                    LOOP
                        BEGIN
                            evidence_id := (
                                combined_ref_map->>trim(both '"' from evidence_ref::text)
                            )::uuid;
                        EXCEPTION WHEN OTHERS THEN
                            evidence_id := NULL;
                        END;
                        IF evidence_id IS NULL THEN
                            warnings := warnings || jsonb_build_array(jsonb_build_object(
                                'code', 'orphaned_reference',
                                'section', 'worldview',
                                'ref', trim(both '"' from evidence_ref::text)
                            ));
                        ELSE
                            PERFORM create_memory_relationship(
                                evidence_id, worldview_id, 'CONTRADICTS', '{}'::jsonb
                            );
                        END IF;
                    END LOOP;
                END LOOP;

            WHEN 'goals' THEN
                section_result := hmx_import_protected_memories(section_data);
                combined_ref_map := combined_ref_map
                    || COALESCE(section_result->'ref_map', '{}'::jsonb);
                warnings := warnings || COALESCE(
                    hmx_remap_goal_references(section_data, combined_ref_map)->'warnings',
                    '[]'::jsonb
                );
                PERFORM ensure_goals_root();

                FOR goal_record IN
                    SELECT value FROM jsonb_array_elements(COALESCE(section_data, '[]'::jsonb))
                LOOP
                    goal_id := (combined_ref_map->>(goal_record->>'ref'))::uuid;
                    IF NOT sync_goal_node(goal_id) THEN
                        RAISE EXCEPTION 'failed to synchronize imported goal %', goal_id;
                    END IF;
                    PERFORM upsert_memory_edge(
                        'goals_root', 'goals', 'CONTAINS', 'goal', goal_id::text,
                        1.0, NULL, NULL,
                        jsonb_build_object('priority', goal_record->>'priority')
                    );
                    EXECUTE format(
                        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                            MATCH (root:GoalsRoot {key: ''goals''})
                            MATCH (g:GoalNode {goal_id: %L})
                            MERGE (root)-[:CONTAINS]->(g)
                            RETURN g
                        $q$) AS (result ag_catalog.agtype)',
                        goal_id
                    );
                    BEGIN
                        parent_id := (combined_ref_map->>(goal_record->>'parent_ref'))::uuid;
                    EXCEPTION WHEN OTHERS THEN
                        parent_id := NULL;
                    END;
                    IF parent_id IS NOT NULL AND NOT link_goal_subgoal(parent_id, goal_id) THEN
                        RAISE EXCEPTION 'failed to link imported goal % to parent %',
                            goal_id, parent_id;
                    END IF;
                END LOOP;

            WHEN 'drives' THEN
                section_result := hmx_import_drives(section_data);

            WHEN 'emotional_triggers' THEN
                section_result := hmx_import_emotional_triggers(
                    section_data, combined_ref_map
                );
                warnings := warnings || COALESCE(
                    section_result->'warnings', '[]'::jsonb
                );

            WHEN 'identity' THEN
                section_result := hmx_import_identity(section_data, combined_ref_map);
                PERFORM hmx_link_current_chapter_identity(1.0);

            WHEN 'narrative' THEN
                section_result := hmx_import_narrative(section_data, combined_ref_map);
                combined_ref_map := combined_ref_map
                    || COALESCE(section_result->'ref_map', '{}'::jsonb);
                SELECT value INTO current_chapter
                FROM jsonb_array_elements(
                    COALESCE(section_data->'life_chapters', '[]'::jsonb)
                )
                WHERE value->>'key' = 'current'
                LIMIT 1;
                current_chapter_id := combined_ref_map->>(current_chapter->>'ref');
                IF current_chapter IS NOT NULL AND NOT hmx_link_current_chapter_identity(
                        1.0,
                        current_chapter_id,
                        COALESCE(
                            NULLIF(current_chapter->>'name', ''),
                            NULLIF(current_chapter->>'title', '')
                        )
                    ) THEN
                    RAISE EXCEPTION 'failed to link imported current life chapter';
                END IF;
                warnings := warnings || COALESCE(
                    section_result->'warnings', '[]'::jsonb
                );
        END CASE;

        results := results || jsonb_build_object(section_name, section_result);
    END LOOP;

    RETURN jsonb_build_object(
        'sections', results,
        'ref_map', combined_ref_map,
        'warnings', warnings
    );
END;
$$ LANGUAGE plpgsql;
