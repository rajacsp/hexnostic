-- 0175: Worker start-storm detection.
--
-- Runtime worker status already lives in Postgres; this adds the missing
-- append-only start ledger used to slow respawn storms without making any
-- worker depend on a local pid/status file.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS worker_start_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mode TEXT NOT NULL,
    instance_name TEXT,
    process_id INTEGER,
    host_name TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_worker_start_events_mode_started
    ON worker_start_events (mode, instance_name, started_at DESC);

CREATE OR REPLACE FUNCTION record_worker_start_and_check_storm(
    p_mode TEXT,
    p_instance_name TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_max_starts INTEGER DEFAULT 5,
    p_window_seconds INTEGER DEFAULT 120,
    p_backoff_cap_seconds INTEGER DEFAULT 300
) RETURNS JSONB AS $$
DECLARE
    v_mode TEXT := lower(btrim(COALESCE(p_mode, 'unknown')));
    v_metadata JSONB := COALESCE(p_metadata, '{}'::jsonb);
    v_process_id INT;
    v_host_name TEXT;
    v_max_starts INTEGER := GREATEST(COALESCE(p_max_starts, 5), 1);
    v_window_seconds INTEGER := GREATEST(COALESCE(p_window_seconds, 120), 10);
    v_backoff_cap_seconds INTEGER := GREATEST(COALESCE(p_backoff_cap_seconds, 300), 10);
    v_recent_count INTEGER := 0;
    v_excess INTEGER := 0;
    v_backoff INTEGER := 0;
BEGIN
    IF v_mode NOT IN ('heartbeat', 'maintenance', 'both', 'channel', 'unknown') THEN
        v_mode := 'unknown';
    END IF;

    IF jsonb_typeof(v_metadata->'process_id') = 'number' THEN
        v_process_id := (v_metadata->>'process_id')::int;
    END IF;
    v_host_name := NULLIF(v_metadata->>'host_name', '');

    INSERT INTO worker_start_events (
        mode,
        instance_name,
        process_id,
        host_name,
        metadata
    ) VALUES (
        v_mode,
        NULLIF(p_instance_name, ''),
        v_process_id,
        v_host_name,
        v_metadata
    );

    DELETE FROM worker_start_events
    WHERE started_at < CURRENT_TIMESTAMP - INTERVAL '1 day';

    SELECT COUNT(*) INTO v_recent_count
    FROM worker_start_events
    WHERE mode = v_mode
      AND instance_name IS NOT DISTINCT FROM NULLIF(p_instance_name, '')
      AND started_at >= CURRENT_TIMESTAMP - make_interval(secs => v_window_seconds);

    IF v_recent_count > v_max_starts THEN
        v_excess := LEAST(v_recent_count - v_max_starts, 6);
        v_backoff := LEAST(v_backoff_cap_seconds, (5 * (2 ^ v_excess))::int);
    END IF;

    RETURN jsonb_build_object(
        'storm', v_backoff > 0,
        'count', v_recent_count,
        'max_starts', v_max_starts,
        'window_seconds', v_window_seconds,
        'backoff_seconds', v_backoff
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW worker_start_storm_status AS
SELECT
    mode,
    instance_name,
    COUNT(*) FILTER (WHERE started_at >= CURRENT_TIMESTAMP - INTERVAL '2 minutes')::int AS starts_last_2m,
    COUNT(*) FILTER (WHERE started_at >= CURRENT_TIMESTAMP - INTERVAL '10 minutes')::int AS starts_last_10m,
    MAX(started_at) AS latest_start_at,
    (
        COUNT(*) FILTER (WHERE started_at >= CURRENT_TIMESTAMP - INTERVAL '2 minutes') > 5
    ) AS is_storming
FROM worker_start_events
GROUP BY mode, instance_name
ORDER BY latest_start_at DESC;
