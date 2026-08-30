-- Provider-scoped connector backfill claims.
--
-- Adapter workers should only claim jobs for providers they can process. The
-- generic claim remains for diagnostics/admin use; provider workers use this
-- wrapper so a Gmail worker will not take a future Slack/Signal job.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION claim_connector_backfill_jobs_for(
    p_connector_id TEXT,
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := GREATEST(COALESCE(p_limit, get_config_int('connector.backfill_batch_size'), 1), 1);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('connector.backfill_claim_timeout_s'), 1800);
    normalized_connector TEXT := NULLIF(btrim(COALESCE(p_connector_id, '')), '');
    claimed JSONB;
BEGIN
    IF normalized_connector IS NULL THEN
        RAISE EXCEPTION 'connector_id is required';
    END IF;

    WITH candidate AS (
        SELECT id
        FROM connector_backfill_jobs
        WHERE connector_id = normalized_connector
          AND (
                (
                    status = 'pending'
                    AND next_attempt_at <= CURRENT_TIMESTAMP
                    AND NOT cancel_requested
                    AND NOT pause_requested
                )
             OR (
                    status = 'in_progress'
                    AND claimed_at < CURRENT_TIMESTAMP - make_interval(secs => timeout_s)
                    AND NOT cancel_requested
                    AND NOT pause_requested
                )
          )
        ORDER BY next_attempt_at, created_at
        LIMIT lim
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE connector_backfill_jobs j
        SET status = 'in_progress',
            attempts = j.attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE j.id = c.id
        RETURNING j.*
    ),
    cursor_touch AS (
        UPDATE connector_sync_cursors c
        SET status = 'active',
            last_started_at = CURRENT_TIMESTAMP,
            last_error = NULL,
            updated_at = CURRENT_TIMESTAMP
        FROM updated u
        WHERE c.connection_id = u.connection_id
          AND c.cursor_key = u.cursor_key
        RETURNING c.id
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY u.claimed_at, u.id), '[]'::jsonb)
    INTO claimed
    FROM updated u;

    RETURN claimed;
END;
$$;
