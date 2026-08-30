-- =============================================================
-- Gateway Events Table
-- =============================================================
SET search_path = public, ag_catalog, "$user";
-- Centralized event bus for all system events.
-- Two modes:
--   record-and-dispatch: chat events (status='recorded', processed inline)
--   queue-and-consume: heartbeat/cron/maintenance (status='pending' -> dequeued)

-- -------------------------------------------------------------
-- Enums
-- -------------------------------------------------------------

CREATE TYPE event_source AS ENUM (
    'chat', 'heartbeat', 'cron', 'maintenance',
    'webhook', 'channel', 'internal', 'sub_agent'
);

CREATE TYPE event_status AS ENUM (
    'pending', 'processing', 'completed', 'failed', 'recorded'
);

-- -------------------------------------------------------------
-- Table
-- -------------------------------------------------------------

CREATE TABLE gateway_events (
    id              BIGSERIAL PRIMARY KEY,
    source          event_source NOT NULL,
    status          event_status NOT NULL DEFAULT 'pending',
    session_key     TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}',
    result          JSONB,
    error           TEXT,
    correlation_id  UUID DEFAULT gen_random_uuid(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    CONSTRAINT valid_completed CHECK (
        completed_at IS NULL OR started_at IS NOT NULL
    )
);

-- -------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------

CREATE INDEX idx_gateway_pending
    ON gateway_events (source, created_at)
    WHERE status = 'pending';

CREATE INDEX idx_gateway_session
    ON gateway_events (session_key, created_at DESC);

CREATE INDEX idx_gateway_correlation
    ON gateway_events (correlation_id);

-- -------------------------------------------------------------
-- Functions
-- -------------------------------------------------------------

-- Submit: insert a new event
CREATE FUNCTION gateway_submit(
    p_source event_source,
    p_session_key TEXT,
    p_payload JSONB DEFAULT '{}',
    p_status event_status DEFAULT 'pending'
) RETURNS BIGINT AS $$
    INSERT INTO gateway_events (source, status, session_key, payload)
    VALUES (p_source, p_status, p_session_key, p_payload)
    RETURNING id;
$$ LANGUAGE sql;

-- Dequeue: atomically claim the next pending event for given sources
CREATE FUNCTION gateway_dequeue(p_sources event_source[])
RETURNS gateway_events AS $$
    UPDATE gateway_events
    SET status = 'processing', started_at = now()
    WHERE id = (
        SELECT id FROM gateway_events
        WHERE source = ANY(p_sources)
          AND status = 'pending'
        ORDER BY created_at, id
        FOR UPDATE SKIP LOCKED
        LIMIT 1
    )
    RETURNING *;
$$ LANGUAGE sql;

-- Complete: mark event as done with optional result, notify listeners
CREATE FUNCTION gateway_complete(p_id BIGINT, p_result JSONB DEFAULT NULL)
RETURNS VOID AS $$
BEGIN
    UPDATE gateway_events
    SET status = 'completed', completed_at = now(), result = p_result
    WHERE id = p_id;
    PERFORM pg_notify('gateway_events', p_id::text);
END;
$$ LANGUAGE plpgsql;

-- Fail: mark event as failed with error message, notify listeners
CREATE FUNCTION gateway_fail(p_id BIGINT, p_error TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE gateway_events
    SET status = 'failed', completed_at = now(), error = p_error
    WHERE id = p_id;
    PERFORM pg_notify('gateway_events', p_id::text);
END;
$$ LANGUAGE plpgsql;

-- Reclaim: reset stale processing events back to pending after worker crash
CREATE FUNCTION gateway_reclaim(p_stale_after INTERVAL DEFAULT '10 minutes')
RETURNS INTEGER AS $$
    WITH reclaimed AS (
        UPDATE gateway_events
        SET status = 'pending', started_at = NULL
        WHERE status = 'processing'
          AND started_at < now() - p_stale_after
        RETURNING 1
    )
    SELECT count(*)::integer FROM reclaimed;
$$ LANGUAGE sql;

-- Cleanup: remove old completed/failed/recorded events
CREATE FUNCTION gateway_cleanup(p_older_than INTERVAL DEFAULT '7 days')
RETURNS INTEGER AS $$
    WITH deleted AS (
        DELETE FROM gateway_events
        WHERE status IN ('completed', 'failed', 'recorded')
          AND created_at < now() - p_older_than
        RETURNING 1
    )
    SELECT count(*)::integer FROM deleted;
$$ LANGUAGE sql;
