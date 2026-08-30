-- Add DB-owned worker liveness and per-task execution history.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS worker_instances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mode TEXT NOT NULL CHECK (mode IN ('heartbeat', 'maintenance', 'both', 'channel', 'unknown')),
    instance_name TEXT,
    process_id INT,
    host_name TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_success_at TIMESTAMPTZ,
    last_error_at TIMESTAMPTZ,
    stopped_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('starting', 'running', 'stopping', 'stopped', 'stale', 'terminated')),
    current_task_type TEXT,
    current_task_run_id UUID,
    build_id TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS worker_task_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID REFERENCES worker_instances(id) ON DELETE SET NULL,
    task_type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running', 'completed', 'failed', 'unknown')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMPTZ,
    result JSONB,
    error TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_worker_instances_status_seen
    ON worker_instances (status, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_worker_instances_mode_seen
    ON worker_instances (mode, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_worker_task_runs_task_started
    ON worker_task_runs (task_type, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_worker_task_runs_status_started
    ON worker_task_runs (status, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_worker_task_runs_worker_started
    ON worker_task_runs (worker_id, started_at DESC);

CREATE OR REPLACE FUNCTION register_worker_instance(
    p_mode TEXT,
    p_instance_name TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    v_id UUID;
    v_mode TEXT := lower(btrim(COALESCE(p_mode, 'unknown')));
    v_metadata JSONB := COALESCE(p_metadata, '{}'::jsonb);
    v_process_id INT;
    v_host_name TEXT;
    v_build_id TEXT;
BEGIN
    IF v_mode NOT IN ('heartbeat', 'maintenance', 'both', 'channel', 'unknown') THEN
        v_mode := 'unknown';
    END IF;

    IF jsonb_typeof(v_metadata->'process_id') = 'number' THEN
        v_process_id := (v_metadata->>'process_id')::int;
    END IF;
    v_host_name := NULLIF(v_metadata->>'host_name', '');
    v_build_id := NULLIF(v_metadata->>'build_id', '');

    INSERT INTO worker_instances (
        mode,
        instance_name,
        process_id,
        host_name,
        status,
        build_id,
        metadata
    ) VALUES (
        v_mode,
        NULLIF(p_instance_name, ''),
        v_process_id,
        v_host_name,
        'running',
        v_build_id,
        v_metadata
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_worker_instance_seen(
    p_worker_id UUID,
    p_status TEXT DEFAULT 'running',
    p_current_task_type TEXT DEFAULT NULL,
    p_current_task_run_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_status TEXT := lower(btrim(COALESCE(p_status, 'running')));
    v_updated INT := 0;
BEGIN
    IF v_status NOT IN ('starting', 'running', 'stopping', 'stopped', 'stale', 'terminated') THEN
        v_status := 'running';
    END IF;

    UPDATE worker_instances
    SET last_seen_at = CURRENT_TIMESTAMP,
        status = v_status,
        current_task_type = CASE
            WHEN p_current_task_type IS NULL AND p_current_task_run_id IS NULL THEN current_task_type
            ELSE p_current_task_type
        END,
        current_task_run_id = CASE
            WHEN p_current_task_type IS NULL AND p_current_task_run_id IS NULL THEN current_task_run_id
            ELSE p_current_task_run_id
        END,
        metadata = CASE
            WHEN p_metadata IS NULL THEN metadata
            ELSE metadata || p_metadata
        END
    WHERE id = p_worker_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN jsonb_build_object('updated', v_updated);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_worker_instance_stopped(
    p_worker_id UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_updated INT := 0;
    v_metadata JSONB := CASE
        WHEN p_reason IS NULL OR btrim(p_reason) = '' THEN '{}'::jsonb
        ELSE jsonb_build_object('stop_reason', p_reason)
    END;
BEGIN
    UPDATE worker_instances
    SET status = 'stopped',
        stopped_at = CURRENT_TIMESTAMP,
        last_seen_at = CURRENT_TIMESTAMP,
        current_task_type = NULL,
        current_task_run_id = NULL,
        metadata = metadata || v_metadata
    WHERE id = p_worker_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN jsonb_build_object('updated', v_updated);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION start_worker_task_run(
    p_worker_id UUID,
    p_task_type TEXT,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    v_id UUID;
    v_task_type TEXT := lower(btrim(COALESCE(p_task_type, 'unknown')));
BEGIN
    IF v_task_type = '' THEN
        v_task_type := 'unknown';
    END IF;

    INSERT INTO worker_task_runs (worker_id, task_type, status, metadata)
    VALUES (p_worker_id, v_task_type, 'running', COALESCE(p_metadata, '{}'::jsonb))
    RETURNING id INTO v_id;

    UPDATE worker_instances
    SET last_seen_at = CURRENT_TIMESTAMP,
        status = 'running',
        current_task_type = v_task_type,
        current_task_run_id = v_id
    WHERE id = p_worker_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION complete_worker_task_run(
    p_run_id UUID,
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    v_worker_id UUID;
    v_updated INT := 0;
BEGIN
    UPDATE worker_task_runs
    SET status = 'completed',
        finished_at = CURRENT_TIMESTAMP,
        result = COALESCE(p_result, '{}'::jsonb),
        error = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_run_id
      AND status = 'running'
    RETURNING worker_id INTO v_worker_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_worker_id IS NOT NULL THEN
        UPDATE worker_instances
        SET last_seen_at = CURRENT_TIMESTAMP,
            last_success_at = CURRENT_TIMESTAMP,
            current_task_type = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_type END,
            current_task_run_id = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_run_id END
        WHERE id = v_worker_id;
    END IF;

    RETURN jsonb_build_object('updated', v_updated);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_worker_task_run(
    p_run_id UUID,
    p_error TEXT,
    p_result JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_worker_id UUID;
    v_updated INT := 0;
BEGIN
    UPDATE worker_task_runs
    SET status = 'failed',
        finished_at = CURRENT_TIMESTAMP,
        result = p_result,
        error = LEFT(COALESCE(p_error, 'worker task failed'), 4000),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_run_id
      AND status = 'running'
    RETURNING worker_id INTO v_worker_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_worker_id IS NOT NULL THEN
        UPDATE worker_instances
        SET last_seen_at = CURRENT_TIMESTAMP,
            last_error_at = CURRENT_TIMESTAMP,
            current_task_type = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_type END,
            current_task_run_id = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_run_id END
        WHERE id = v_worker_id;
    END IF;

    RETURN jsonb_build_object('updated', v_updated);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION discard_worker_task_run(
    p_run_id UUID,
    p_result JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_worker_id UUID;
    v_deleted INT := 0;
BEGIN
    SELECT worker_id INTO v_worker_id
    FROM worker_task_runs
    WHERE id = p_run_id;

    DELETE FROM worker_task_runs
    WHERE id = p_run_id
      AND status = 'running';

    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    IF v_worker_id IS NOT NULL THEN
        UPDATE worker_instances
        SET last_seen_at = CURRENT_TIMESTAMP,
            current_task_type = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_type END,
            current_task_run_id = CASE WHEN current_task_run_id = p_run_id THEN NULL ELSE current_task_run_id END,
            metadata = CASE
                WHEN p_result IS NULL THEN metadata
                ELSE metadata || jsonb_build_object('last_idle_result', p_result)
            END
        WHERE id = v_worker_id;
    END IF;

    RETURN jsonb_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recover_interrupted_worker_runs(
    p_stale_after INTERVAL DEFAULT INTERVAL '10 minutes'
) RETURNS JSONB AS $$
DECLARE
    v_stale_workers INT := 0;
    v_unknown_runs INT := 0;
BEGIN
    WITH stale AS (
        UPDATE worker_instances
        SET status = 'stale',
            current_task_type = NULL,
            current_task_run_id = NULL,
            metadata = metadata || jsonb_build_object('stale_marked_at', CURRENT_TIMESTAMP)
        WHERE status IN ('starting', 'running', 'stopping')
          AND last_seen_at < CURRENT_TIMESTAMP - p_stale_after
        RETURNING id
    )
    SELECT COUNT(*) INTO v_stale_workers FROM stale;

    WITH interrupted AS (
        UPDATE worker_task_runs r
        SET status = 'unknown',
            finished_at = CURRENT_TIMESTAMP,
            error = COALESCE(error, 'worker stopped before reporting task outcome'),
            updated_at = CURRENT_TIMESTAMP
        WHERE r.status = 'running'
          AND (
              r.started_at < CURRENT_TIMESTAMP - p_stale_after
              OR EXISTS (
                  SELECT 1
                  FROM worker_instances wi
                  WHERE wi.id = r.worker_id
                    AND wi.status = 'stale'
              )
          )
        RETURNING id
    )
    SELECT COUNT(*) INTO v_unknown_runs FROM interrupted;

    RETURN jsonb_build_object(
        'stale_workers', v_stale_workers,
        'unknown_runs', v_unknown_runs
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW worker_runtime_status AS
SELECT
    id,
    mode,
    instance_name,
    process_id,
    host_name,
    started_at,
    last_seen_at,
    last_success_at,
    last_error_at,
    stopped_at,
    status,
    current_task_type,
    current_task_run_id,
    build_id,
    metadata,
    EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_seen_at))::int AS last_seen_age_s,
    (
        status IN ('starting', 'running', 'stopping')
        AND last_seen_at < CURRENT_TIMESTAMP - INTERVAL '3 minutes'
    ) AS is_stale
FROM worker_instances
ORDER BY last_seen_at DESC;

CREATE OR REPLACE VIEW worker_task_status AS
WITH task_catalog AS (
    SELECT task_type, max(description) AS description
    FROM (
        SELECT task_type, description FROM worker_tasks
        UNION ALL
        SELECT DISTINCT task_type, NULL::text AS description FROM worker_task_runs
    ) catalog
    GROUP BY task_type
)
SELECT
    tc.task_type,
    COALESCE(wt.pending_count, 0)::int AS pending_count,
    tc.description,
    latest.status AS latest_status,
    latest.started_at AS latest_started_at,
    latest.finished_at AS latest_finished_at,
    latest.result AS latest_result,
    latest.error AS latest_error,
    success.finished_at AS last_success_at,
    COALESCE(failures.failures_since_success, 0)::int AS failures_since_success,
    COALESCE(running.running_count, 0)::int AS running_count
FROM task_catalog tc
LEFT JOIN worker_tasks wt ON wt.task_type = tc.task_type
LEFT JOIN LATERAL (
    SELECT status, started_at, finished_at, result, error
    FROM worker_task_runs wr
    WHERE wr.task_type = tc.task_type
    ORDER BY wr.started_at DESC
    LIMIT 1
) latest ON true
LEFT JOIN LATERAL (
    SELECT finished_at
    FROM worker_task_runs wr
    WHERE wr.task_type = tc.task_type
      AND wr.status = 'completed'
    ORDER BY wr.finished_at DESC NULLS LAST
    LIMIT 1
) success ON true
LEFT JOIN LATERAL (
    SELECT COUNT(*)::int AS failures_since_success
    FROM worker_task_runs wr
    WHERE wr.task_type = tc.task_type
      AND wr.status = 'failed'
      AND (success.finished_at IS NULL OR wr.started_at > success.finished_at)
) failures ON true
LEFT JOIN LATERAL (
    SELECT COUNT(*)::int AS running_count
    FROM worker_task_runs wr
    WHERE wr.task_type = tc.task_type
      AND wr.status = 'running'
) running ON true
ORDER BY tc.task_type;
