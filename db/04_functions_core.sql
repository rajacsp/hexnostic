-- Hexis schema: core memory functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

-- Recency in recall ranking (#47): temporal questions must not lose to raw
-- similarity. Half-life decay; weight 0 disables.
INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.recency_weight', '0.1'::jsonb,
     'Weight of the recency term in fast_recall scoring (0 disables)'),
    ('memory.recency_halflife_days', '7'::jsonb,
     'Half-life in days for the recency decay in fast_recall')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION update_memory_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION update_memory_importance()
RETURNS TRIGGER AS $$
BEGIN
    NEW.importance = LEAST(
        1.0,
        GREATEST(0.0, NEW.importance * (1.0 + (LN(NEW.access_count + 1) * 0.1)))
    );
    NEW.last_accessed = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION mark_neighborhoods_stale()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE memory_neighborhoods 
    SET is_stale = TRUE 
    WHERE memory_id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
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
CREATE OR REPLACE FUNCTION fast_recall(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    fidelity FLOAT,
    emotional_intensity FLOAT
) AS $$
    -- One mind, one retrieval mechanism (#96/#78): fast_recall is now a
    -- flattening wrapper over the unified ranker in recmem_recall_context —
    -- every caller (the db/05 recall wrapper family, context gathering,
    -- observation sweeps) gets the same scoring the chat hot path uses:
    -- associations, episode binding, recency, strength, mood congruence,
    -- trust floor, activation boost, and sensitivity enforcement.
    SELECT
        r.item_id AS memory_id,
        r.content,
        r.memory_type::memory_type,
        r.score,
        r.retrieval_source AS source,
        r.fidelity,
        r.emotional_intensity
    FROM recmem_recall_context(
        p_query_text,
        0,                    -- no unit tiers: fast_recall's contract is memories
        GREATEST(p_limit, 5),
        GREATEST(p_limit, 5),
        NULL,
        p_exclude_sensitive,
        GREATEST(p_limit, 5)
    ) r
    WHERE r.tier IN ('episodic', 'semantic', 'knowledge')
    ORDER BY r.score DESC, r.created_at DESC
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;

SET check_function_bodies = on;
