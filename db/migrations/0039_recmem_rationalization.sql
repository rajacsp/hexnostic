-- 0039: RecMem rationalization (#57).
-- 1. semantic_refine is retired: conscious extraction (db/61) is the sole
--    semantic-fact minter — it carries confidence/provenance and routes
--    through belief revision; recmem's refinement minted unattributed
--    near-duplicates. Episode create/merge no longer queue it; the dispatch
--    handler remains to drain legacy queued tasks.
-- 2. recmem_recall_context (the chat hydration ranker) gains the same
--    recency half-life + trust terms fast_recall got in #47, so recall
--    improvements land in BOTH rankers.
-- 3. The never-used rollout/eval apparatus (6 tables + stub modules) is
--    dropped — RecMem is fully rolled out; the A/B harness never ran.
-- Baseline mirrors: db/31, db/00, db/01.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION apply_recmem_episode_merge(
    p_task_id UUID,
    p_merged_content TEXT DEFAULT NULL,
    p_should_merge BOOLEAN DEFAULT TRUE
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    old_content TEXT;
    new_embedding vector;
    unit_id UUID;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    IF NOT COALESCE(p_should_merge, TRUE) THEN
        UPDATE subconscious_units
        SET route_status = 'routing',
            route_result = route_result || jsonb_build_object(
                'merge_rejected', true,
                'merge_rejected_target_memory_id', task.target_memory_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM recmem_route_unit(unit_id);
        END LOOP;

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('merged', false),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'merged', false);
    END IF;

    SELECT content INTO old_content
    FROM memories
    WHERE id = task.target_memory_id;

    IF task.target_memory_id IS NULL OR old_content IS NULL THEN
        PERFORM fail_recmem_consolidation_task(p_task_id, 'target memory missing');
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'failed', 'reason', 'target_missing');
    END IF;

    new_embedding := (get_embedding(ARRAY[COALESCE(NULLIF(p_merged_content, ''), old_content)]))[1];

    UPDATE memories
    SET content = COALESCE(NULLIF(p_merged_content, ''), old_content),
        embedding = new_embedding,
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'recmem',
                COALESCE(metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object(
                        'merge_history',
                        COALESCE(metadata#>'{recmem,merge_history}', '[]'::jsonb)
                            || jsonb_build_array(jsonb_build_object('content', old_content, 'merged_at', CURRENT_TIMESTAMP))
                    )
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = task.target_memory_id;

    FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
        PERFORM link_memory_to_source_unit(task.target_memory_id, unit_id, 'merge_addition');
    END LOOP;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'merged',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    -- semantic_refine retired (#57): conscious extraction (db/61) is the sole
    -- semantic-fact minter — it carries provenance and routes through the
    -- belief-revision policy; recmem's refinement minted unattributed
    -- near-duplicates. The handler remains only to drain legacy queued tasks.

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('merged', true, 'target_memory_id', task.target_memory_id),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'merged', true, 'target_memory_id', task.target_memory_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_episode_create(
    p_task_id UUID,
    p_episodes JSONB
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    item JSONB;
    episode_content TEXT;
    new_embedding vector;
    memory_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    unit_id UUID;
    source_attr JSONB;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    source_attr := jsonb_build_object(
        'kind', 'recmem',
        'ref', task.id::text,
        'label', 'RecMem episodic consolidation',
        'observed_at', CURRENT_TIMESTAMP,
        'trust', 0.9
    );

    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_episodes, '[]'::jsonb))
    LOOP
        episode_content := COALESCE(item->>'content', item->>'episode', item#>>'{}');
        IF NULLIF(trim(COALESCE(episode_content, '')), '') IS NULL THEN
            CONTINUE;
        END IF;

        new_embedding := (get_embedding(ARRAY[episode_content]))[1];
        memory_id := create_memory_with_embedding(
            'episodic',
            episode_content,
            new_embedding,
            COALESCE(NULLIF(item->>'importance', '')::float, 0.6),
            source_attr,
            0.9,
            jsonb_build_object('recmem', jsonb_build_object('task_id', task.id, 'source_unit_ids', task.source_unit_ids))
        );
        created_ids := created_ids || memory_id;

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM link_memory_to_source_unit(memory_id, unit_id, 'source');
        END LOOP;

        -- semantic_refine retired (#57): see apply_recmem_episode_merge.
    END LOOP;

    IF cardinality(created_ids) = 0 THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'episode_create_empty', true,
                'task_id', p_task_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('memory_ids', created_ids, 'empty', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids, 'empty', true);
    END IF;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'episode_created',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('memory_ids', created_ids),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids);
END;
$$ LANGUAGE plpgsql;

-- DROP-first: later baselines change this function's OUT row (0040 adds
-- confidence), and CREATE OR REPLACE cannot change a return type when this
-- migration replays onto a fresh database built from that newer baseline.
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID);

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    fidelity FLOAT,
    strength FLOAT,
    emotional_intensity FLOAT
) AS $$
DECLARE
    query_embedding vector;
    strength_weight FLOAT;
    intensity_weight FLOAT;
    recency_weight FLOAT;
    recency_halflife FLOAT;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1];
    -- Ranking parity with fast_recall (#57 unification, first step): the chat
    -- hot path honors the same recency half-life and trust signals, so recall
    -- improvements land in BOTH rankers.
    recency_weight := COALESCE(get_config_float('memory.recency_weight'), 0.1);
    recency_halflife := GREATEST(COALESCE(get_config_float('memory.recency_halflife_days'), 7.0), 0.01);
    -- How much computed memory strength (recency/reinforcement/decay) reshapes
    -- the pure-cosine recall score: 0 = pure similarity (old behavior),
    -- 0.5 = gentle default, 1 = score fully scaled by strength.
    strength_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_strength_weight'), 0.5)));
    -- Felt emotional intensity contributes to salience too, so an embered peak
    -- stays recallable even after its strength has decayed.
    intensity_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_intensity_weight'), 0.5)));

    RETURN QUERY
    WITH raw_hits AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            (1 - (s.embedding <=> query_embedding))::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
        ORDER BY s.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sub, 10), 0)
    ),
    recent_unembedded AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            0.2::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity
        FROM subconscious_units s
        WHERE p_session_id IS NOT NULL
          AND s.session_id = p_session_id
          AND s.status = 'active'
          AND s.embedding_status <> 'embedded'
        ORDER BY s.created_at DESC
        LIMIT 3
    ),
    epi_hits AS (
        SELECT
            'episodic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
             * (1.0 - strength_weight + strength_weight
                * GREATEST(
                    calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                    intensity_weight * current_emotional_intensity(
                        (m.metadata->'emotional_context'->>'intensity')::float,
                        (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
             + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                    / (86400.0 * recency_halflife))
             + COALESCE(m.trust_level, 0.5) * 0.1)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'episodic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_epi, 5), 0)
    ),
    sem_hits AS (
        SELECT
            'semantic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
             * (1.0 - strength_weight + strength_weight
                * GREATEST(
                    calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                    intensity_weight * current_emotional_intensity(
                        (m.metadata->'emotional_context'->>'intensity')::float,
                        (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
             + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                    / (86400.0 * recency_halflife))
             + COALESCE(m.trust_level, 0.5) * 0.1)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'semantic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sem, 10), 0)
    )
    SELECT * FROM raw_hits
    UNION ALL
    SELECT * FROM recent_unembedded
    UNION ALL
    SELECT * FROM epi_hits
    UNION ALL
    SELECT * FROM sem_hits
    ORDER BY tier, score DESC, created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- Legacy semantic_refine tasks still pending are dropped, not drained:
-- their output would bypass belief revision (the reason for retirement).
UPDATE recmem_consolidation_tasks
SET status = 'dropped',
    completed_at = CURRENT_TIMESTAMP,
    dropped_reason = 'semantic_refine_retired_0039'
WHERE task_type = 'semantic_refine'
  AND status IN ('pending', 'in_progress');

DROP TABLE IF EXISTS recmem_eval_results CASCADE;
DROP TABLE IF EXISTS recmem_eval_runs CASCADE;
DROP TABLE IF EXISTS recmem_eval_items CASCADE;
DROP TABLE IF EXISTS recmem_eval_sets CASCADE;
DROP TABLE IF EXISTS recmem_retrieval_comparisons CASCADE;
DROP TABLE IF EXISTS recmem_rollout_events CASCADE;
