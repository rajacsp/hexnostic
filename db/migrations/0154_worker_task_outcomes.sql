-- Record completed/failed observed worker tasks without writing rows for idle polling.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_worker_task_outcome(
    p_worker_id UUID,
    p_task_type TEXT,
    p_status TEXT,
    p_started_at TIMESTAMPTZ,
    p_finished_at TIMESTAMPTZ,
    p_result JSONB DEFAULT NULL,
    p_error TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    v_id UUID;
    v_status TEXT := lower(btrim(COALESCE(p_status, 'completed')));
    v_task_type TEXT := lower(btrim(COALESCE(p_task_type, 'unknown')));
BEGIN
    IF v_status NOT IN ('completed', 'failed', 'unknown') THEN
        RAISE EXCEPTION 'record_worker_task_outcome status must be completed, failed, or unknown';
    END IF;
    IF v_task_type = '' THEN
        v_task_type := 'unknown';
    END IF;

    INSERT INTO worker_task_runs (
        worker_id,
        task_type,
        status,
        started_at,
        finished_at,
        result,
        error,
        metadata
    ) VALUES (
        p_worker_id,
        v_task_type,
        v_status,
        COALESCE(p_started_at, CURRENT_TIMESTAMP),
        COALESCE(p_finished_at, CURRENT_TIMESTAMP),
        p_result,
        CASE WHEN v_status = 'failed' THEN LEFT(COALESCE(p_error, 'worker task failed'), 4000) ELSE p_error END,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO v_id;

    IF p_worker_id IS NOT NULL THEN
        UPDATE worker_instances
        SET last_seen_at = CURRENT_TIMESTAMP,
            last_success_at = CASE WHEN v_status = 'completed' THEN CURRENT_TIMESTAMP ELSE last_success_at END,
            last_error_at = CASE WHEN v_status = 'failed' THEN CURRENT_TIMESTAMP ELSE last_error_at END,
            current_task_type = NULL,
            current_task_run_id = NULL
        WHERE id = p_worker_id;
    END IF;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;
