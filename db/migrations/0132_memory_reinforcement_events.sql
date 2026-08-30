-- Durable reinforcement events make spaced practice observable instead of
-- collapsing all recall into last_reinforced + a counter.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS memory_reinforcement_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'recall',
    source TEXT NOT NULL DEFAULT 'system',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_memory_reinforcement_events_memory_created
    ON memory_reinforcement_events (memory_id, created_at DESC);

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.spaced_reinforcement_interval_hours', '12'::jsonb,
     'Minimum spacing between reinforcements before they count as distinct durable practice'),
    ('memory.spaced_reinforcement_scale', '4'::jsonb,
     'Effective spaced reinforcement count that approaches a full score')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION record_memory_reinforcement(
    p_memory_id UUID,
    p_kind TEXT DEFAULT 'recall',
    p_source TEXT DEFAULT 'system',
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
) RETURNS UUID AS $$
DECLARE
    event_id UUID;
BEGIN
    IF p_memory_id IS NULL THEN
        RAISE EXCEPTION 'memory_id is required';
    END IF;

    INSERT INTO memory_reinforcement_events (memory_id, kind, source, metadata, created_at)
    VALUES (
        p_memory_id,
        COALESCE(NULLIF(trim(p_kind), ''), 'recall'),
        COALESCE(NULLIF(trim(p_source), ''), 'system'),
        COALESCE(p_metadata, '{}'::jsonb),
        COALESCE(p_created_at, CURRENT_TIMESTAMP)
    )
    RETURNING id INTO event_id;

    RETURN event_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION memory_spaced_reinforcement_score(
    p_memory_id UUID,
    p_window INTERVAL DEFAULT INTERVAL '180 days',
    p_min_interval INTERVAL DEFAULT NULL
) RETURNS FLOAT AS $$
DECLARE
    rec RECORD;
    total_count INT := 0;
    spaced_count INT := 0;
    last_counted_at TIMESTAMPTZ := NULL;
    effective_min_interval INTERVAL;
    scale FLOAT;
BEGIN
    IF p_memory_id IS NULL THEN
        RETURN 0.0;
    END IF;

    effective_min_interval := COALESCE(
        p_min_interval,
        (GREATEST(COALESCE(get_config_float('memory.spaced_reinforcement_interval_hours'), 12.0), 0.01) || ' hours')::interval
    );
    scale := GREATEST(COALESCE(get_config_float('memory.spaced_reinforcement_scale'), 4.0), 1.0);

    FOR rec IN
        SELECT created_at
        FROM memory_reinforcement_events
        WHERE memory_id = p_memory_id
          AND created_at >= CURRENT_TIMESTAMP - COALESCE(p_window, INTERVAL '180 days')
        ORDER BY created_at ASC
    LOOP
        total_count := total_count + 1;
        IF last_counted_at IS NULL OR rec.created_at - last_counted_at >= effective_min_interval THEN
            spaced_count := spaced_count + 1;
            last_counted_at := rec.created_at;
        END IF;
    END LOOP;

    IF total_count = 0 THEN
        RETURN 0.0;
    END IF;

    RETURN LEAST(1.0, GREATEST(0.0, 1.0 - exp(-spaced_count::float / scale)));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION touch_memories(p_ids UUID[])
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    WITH updated AS (
        UPDATE memories
        SET access_count = access_count + 1,
            last_accessed = CURRENT_TIMESTAMP,
            last_reinforced = CURRENT_TIMESTAMP,
            reinforcement_count = reinforcement_count + 1
        WHERE id = ANY(p_ids)
        RETURNING id
    ),
    logged AS (
        INSERT INTO memory_reinforcement_events (memory_id, kind, source, metadata)
        SELECT id, 'recall', 'touch_memories', '{}'::jsonb
        FROM updated
        RETURNING 1
    )
    SELECT COUNT(*)::int INTO updated_count FROM logged;

    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;
