-- ============================================================================
-- RECONSOLIDATION SWEEP FUNCTIONS
--
-- After a worldview belief transforms, re-evaluate memories that were
-- connected to the old belief. Two directions:
--   1. CONTESTED_BECAUSE → belief: rejected because of old belief, may now accept
--   2. SUPPORTS → belief: supported old belief, may now contradict
-- ============================================================================

SET search_path = public, ag_catalog, "$user";

-- ---------------------------------------------------------------------------
-- queue_reconsolidation: called after successful attempt_worldview_transformation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION queue_reconsolidation(
    p_belief_id UUID,
    p_old_content TEXT,
    p_new_content TEXT,
    p_transformation_type TEXT DEFAULT 'shift'
) RETURNS UUID AS $$
DECLARE
    task_id UUID;
    candidate_count INT := 0;
    cnt_contested INT := 0;
    cnt_supports INT := 0;
BEGIN
    -- Count contested-because candidates
    BEGIN
        EXECUTE format(
            'SELECT COUNT(*)
             FROM (
                 SELECT (replace(mid::text, ''"'', ''''))::uuid AS memory_id
                 FROM ag_catalog.cypher(''memory_graph'', $q$
                     MATCH (m:MemoryNode)-[:CONTESTED_BECAUSE]->(w:MemoryNode {memory_id: %L})
                     RETURN m.memory_id
                 $q$) AS (mid ag_catalog.agtype)
             ) sub
             JOIN memories m ON m.id = sub.memory_id
             WHERE m.status = ''active''',
            p_belief_id
        ) INTO cnt_contested;
    EXCEPTION WHEN OTHERS THEN
        cnt_contested := 0;
    END;

    -- Count supports candidates
    BEGIN
        EXECUTE format(
            'SELECT COUNT(*)
             FROM (
                 SELECT (replace(mid::text, ''"'', ''''))::uuid AS memory_id
                 FROM ag_catalog.cypher(''memory_graph'', $q$
                     MATCH (m:MemoryNode)-[:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                     RETURN m.memory_id
                 $q$) AS (mid ag_catalog.agtype)
             ) sub
             JOIN memories m ON m.id = sub.memory_id
             WHERE m.status = ''active''',
            p_belief_id
        ) INTO cnt_supports;
    EXCEPTION WHEN OTHERS THEN
        cnt_supports := 0;
    END;

    candidate_count := cnt_contested + cnt_supports;

    INSERT INTO reconsolidation_tasks (
        belief_id, old_content, new_content, transformation_type,
        status, total_candidates
    ) VALUES (
        p_belief_id, p_old_content, p_new_content,
        COALESCE(p_transformation_type, 'shift'),
        'pending', candidate_count
    ) RETURNING id INTO task_id;

    RETURN task_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- claim_reconsolidation_task: atomically claim the oldest pending task
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_reconsolidation_task()
RETURNS JSONB AS $$
DECLARE
    task RECORD;
BEGIN
    SELECT * INTO task
    FROM reconsolidation_tasks
    WHERE status = 'pending'
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    UPDATE reconsolidation_tasks
    SET status = 'in_progress',
        started_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = task.id;

    RETURN jsonb_build_object(
        'task_id', task.id,
        'belief_id', task.belief_id,
        'old_content', task.old_content,
        'new_content', task.new_content,
        'transformation_type', task.transformation_type,
        'total_candidates', task.total_candidates
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- get_reconsolidation_candidates: batched retrieval of affected memories
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_reconsolidation_candidates(
    p_belief_id UUID,
    p_batch_size INT DEFAULT 10,
    p_offset INT DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
    direction_1 JSONB := '[]'::jsonb;
    direction_2 JSONB := '[]'::jsonb;
BEGIN
    -- Direction 1: memories with CONTESTED_BECAUSE edges to the belief
    BEGIN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(row_to_json(sub)), ''[]''::jsonb)
             FROM (
                 SELECT m.id, m.content, m.type::text, m.trust_level,
                        m.importance, m.source_attribution,
                        COALESCE(m.source_attribution->>''contested'', ''false'') AS is_contested,
                        ''contested_because'' AS direction
                 FROM (
                     SELECT (replace(mid::text, ''"'', ''''))::uuid AS memory_id
                     FROM ag_catalog.cypher(''memory_graph'', $q$
                         MATCH (m:MemoryNode)-[:CONTESTED_BECAUSE]->(w:MemoryNode {memory_id: %L})
                         RETURN m.memory_id
                     $q$) AS (mid ag_catalog.agtype)
                 ) edges
                 JOIN memories m ON m.id = edges.memory_id
                 WHERE m.status = ''active''
                 ORDER BY m.created_at
                 LIMIT %s OFFSET %s
             ) sub',
            p_belief_id, p_batch_size, p_offset
        ) INTO direction_1;
    EXCEPTION WHEN OTHERS THEN
        direction_1 := '[]'::jsonb;
    END;

    -- Direction 2: memories with SUPPORTS edges to the belief
    BEGIN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(row_to_json(sub)), ''[]''::jsonb)
             FROM (
                 SELECT m.id, m.content, m.type::text, m.trust_level,
                        m.importance, m.source_attribution,
                        ''false'' AS is_contested,
                        ''supports'' AS direction
                 FROM (
                     SELECT (replace(mid::text, ''"'', ''''))::uuid AS memory_id
                     FROM ag_catalog.cypher(''memory_graph'', $q$
                         MATCH (m:MemoryNode)-[:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                         RETURN m.memory_id
                     $q$) AS (mid ag_catalog.agtype)
                 ) edges
                 JOIN memories m ON m.id = edges.memory_id
                 WHERE m.status = ''active''
                 ORDER BY m.created_at
                 LIMIT %s OFFSET %s
             ) sub',
            p_belief_id, p_batch_size, p_offset
        ) INTO direction_2;
    EXCEPTION WHEN OTHERS THEN
        direction_2 := '[]'::jsonb;
    END;

    RETURN jsonb_build_object(
        'contested_candidates', direction_1,
        'supporting_candidates', direction_2
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- apply_reconsolidation_verdict: apply LLM verdicts to memories and graph
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_reconsolidation_verdict(
    p_task_id UUID,
    p_verdicts JSONB  -- array of {memory_id, verdict, reason, strength, create_supports}
) RETURNS JSONB AS $$
DECLARE
    task RECORD;
    verdict JSONB;
    v_memory_id UUID;
    v_verdict TEXT;
    v_reason TEXT;
    v_strength FLOAT;
    v_create_supports BOOLEAN;
    accepted INT := 0;
    newly_contested INT := 0;
    still_contested INT := 0;
    kept INT := 0;
    processed INT := 0;
    mem RECORD;
BEGIN
    SELECT * INTO task FROM reconsolidation_tasks WHERE id = p_task_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'task_not_found');
    END IF;

    FOR verdict IN SELECT * FROM jsonb_array_elements(p_verdicts)
    LOOP
        BEGIN
            v_memory_id := (verdict->>'memory_id')::uuid;
            v_verdict := verdict->>'verdict';
            v_reason := COALESCE(verdict->>'reason', '');
            v_strength := COALESCE((verdict->>'strength')::float, 0.7);
            v_strength := LEAST(1.0, GREATEST(0.0, v_strength));
            v_create_supports := COALESCE((verdict->>'create_supports')::boolean, false);

            SELECT * INTO mem FROM memories WHERE id = v_memory_id AND status = 'active';
            IF NOT FOUND THEN
                CONTINUE;
            END IF;

            processed := processed + 1;

            IF v_verdict = 'accept' THEN
                -- Previously contested → now accepted: restore trust, remove flag, fix edges
                UPDATE memories
                SET source_attribution = source_attribution - 'contested',
                    trust_level = LEAST(1.0, trust_level / 0.4),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = v_memory_id;

                -- Remove CONTESTED_BECAUSE edge to the belief
                BEGIN
                    EXECUTE format(
                        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                            MATCH (m:MemoryNode {memory_id: %L})-[r:CONTESTED_BECAUSE]->(w:MemoryNode {memory_id: %L})
                            DELETE r
                        $q$) AS (result ag_catalog.agtype)',
                        v_memory_id, task.belief_id
                    );
                    PERFORM delete_memory_edge('memory', v_memory_id::text, 'CONTESTED_BECAUSE', 'memory', task.belief_id::text);
                EXCEPTION WHEN OTHERS THEN NULL;
                END;

                -- Optionally create SUPPORTS edge
                IF v_create_supports THEN
                    PERFORM create_memory_relationship(
                        v_memory_id, task.belief_id, 'SUPPORTS',
                        jsonb_build_object('strength', v_strength, 'source', 'reconsolidation')
                    );
                END IF;

                -- Re-sync trust based on new edges
                PERFORM sync_memory_trust(v_memory_id);
                accepted := accepted + 1;

            ELSIF v_verdict = 'still_contested' THEN
                -- Still contests the new belief: update edge metadata
                BEGIN
                    EXECUTE format(
                        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                            MATCH (m:MemoryNode {memory_id: %L})-[r:CONTESTED_BECAUSE]->(w:MemoryNode {memory_id: %L})
                            SET r.reconsolidated_at = %L, r.strength = %s
                        $q$) AS (result ag_catalog.agtype)',
                        v_memory_id, task.belief_id,
                        clock_timestamp()::text, v_strength
                    );
                    PERFORM upsert_memory_edge(v_memory_id, task.belief_id, 'CONTESTED_BECAUSE',
                                               jsonb_build_object('strength', v_strength, 'source', 'reconsolidation',
                                                                  'reconsolidated_at', clock_timestamp()::text));
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
                still_contested := still_contested + 1;

            ELSIF v_verdict = 'newly_contested' THEN
                -- Previously supporting → now contradicts: mark contested, reduce trust
                UPDATE memories
                SET source_attribution = source_attribution || '{"contested": true}'::jsonb,
                    trust_level = GREATEST(0.0, trust_level * 0.4),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = v_memory_id;

                -- Remove old SUPPORTS edge
                BEGIN
                    EXECUTE format(
                        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                            MATCH (m:MemoryNode {memory_id: %L})-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                            DELETE r
                        $q$) AS (result ag_catalog.agtype)',
                        v_memory_id, task.belief_id
                    );
                    PERFORM delete_memory_edge('memory', v_memory_id::text, 'SUPPORTS', 'memory', task.belief_id::text);
                EXCEPTION WHEN OTHERS THEN NULL;
                END;

                -- Create CONTESTED_BECAUSE edge
                PERFORM create_memory_relationship(
                    v_memory_id, task.belief_id, 'CONTESTED_BECAUSE',
                    jsonb_build_object('strength', v_strength, 'source', 'reconsolidation')
                );

                newly_contested := newly_contested + 1;

            ELSIF v_verdict = 'keep' THEN
                -- Still supports: update edge metadata
                BEGIN
                    EXECUTE format(
                        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                            MATCH (m:MemoryNode {memory_id: %L})-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                            SET r.reconsolidated_at = %L, r.strength = %s
                        $q$) AS (result ag_catalog.agtype)',
                        v_memory_id, task.belief_id,
                        clock_timestamp()::text, v_strength
                    );
                    PERFORM upsert_memory_edge(v_memory_id, task.belief_id, 'SUPPORTS',
                                               jsonb_build_object('strength', v_strength, 'source', 'reconsolidation',
                                                                  'reconsolidated_at', clock_timestamp()::text));
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
                kept := kept + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- Skip individual verdict failures
            NULL;
        END;
    END LOOP;

    -- Update task counters
    UPDATE reconsolidation_tasks
    SET processed_count = reconsolidation_tasks.processed_count + processed,
        accepted_count = reconsolidation_tasks.accepted_count + accepted,
        newly_contested_count = reconsolidation_tasks.newly_contested_count + newly_contested,
        still_contested_count = reconsolidation_tasks.still_contested_count + still_contested,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object(
        'processed', processed,
        'accepted', accepted,
        'newly_contested', newly_contested,
        'still_contested', still_contested,
        'kept', kept
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- complete_reconsolidation: finalize task and create summary memory
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_reconsolidation(p_task_id UUID)
RETURNS JSONB AS $$
DECLARE
    task RECORD;
    summary TEXT;
    mem_id UUID;
BEGIN
    SELECT * INTO task FROM reconsolidation_tasks WHERE id = p_task_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'task_not_found');
    END IF;

    summary := format(
        'Reconsolidation sweep after worldview transformation (belief_id=%s). '
        'Re-evaluated %s memories: %s accepted (no longer contested), '
        '%s still contested, %s newly contested.',
        task.belief_id,
        task.processed_count,
        task.accepted_count,
        task.still_contested_count,
        task.newly_contested_count
    );

    mem_id := create_episodic_memory(
        summary,
        jsonb_build_object(
            'action', 'reconsolidation_sweep',
            'belief_id', task.belief_id,
            'old_content', task.old_content,
            'new_content', task.new_content
        ),
        jsonb_build_object(
            'processed', task.processed_count,
            'accepted', task.accepted_count,
            'still_contested', task.still_contested_count,
            'newly_contested', task.newly_contested_count
        ),
        NULL,
        0.0,
        CURRENT_TIMESTAMP,
        0.8
    );

    UPDATE reconsolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        summary_memory_id = mem_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object(
        'success', true,
        'summary_memory_id', mem_id,
        'processed', task.processed_count,
        'accepted', task.accepted_count,
        'still_contested', task.still_contested_count,
        'newly_contested', task.newly_contested_count
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- fail_reconsolidation: mark task as failed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fail_reconsolidation(p_task_id UUID, p_error TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE reconsolidation_tasks
    SET status = 'failed',
        error_message = p_error,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- has_pending_reconsolidation: quick check for maintenance worker
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION has_pending_reconsolidation()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM reconsolidation_tasks
        WHERE status IN ('pending', 'in_progress')
    );
$$ LANGUAGE sql STABLE;
