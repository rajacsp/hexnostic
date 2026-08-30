-- Durable ingestion jobs (#87 stage 2): background ingestion survives
-- restarts. Modeled on external_driver_calls plus what that template lacks —
-- exponential retry backoff, cancellation, a progress heartbeat that extends
-- the stale-claim window, and idempotent enqueue by active content hash.
-- The payload text lives in the DB: api and worker share no data volume.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('ingest.job_max_content_chars', '2000000'::jsonb,
     'Maximum pasted/extracted text an ingestion job may carry; larger content uses the synchronous CLI path'),
    ('ingest.job_claim_timeout_s', '1800'::jsonb,
     'Seconds after which an in-progress ingestion job with no progress heartbeat is reclaimed'),
    ('ingest.job_retry_base_seconds', '60'::jsonb,
     'Base for exponential retry backoff when an ingestion job fails'),
    ('ingest.job_batch_size', '1'::jsonb,
     'Ingestion jobs claimed per maintenance tick')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS ingestion_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL CHECK (kind IN ('text', 'url')),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'cancelled')),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    content TEXT,
    content_hash TEXT,
    progress JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    error TEXT,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ingestion_jobs_pending
    ON ingestion_jobs (next_attempt_at, created_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_ingestion_jobs_in_progress
    ON ingestion_jobs (claimed_at) WHERE status = 'in_progress';
CREATE UNIQUE INDEX IF NOT EXISTS idx_ingestion_jobs_active_hash
    ON ingestion_jobs (content_hash) WHERE status IN ('pending', 'in_progress');

CREATE OR REPLACE FUNCTION enqueue_ingestion_job(
    p_kind TEXT,
    p_payload JSONB,
    p_content TEXT DEFAULT NULL,
    p_content_hash TEXT DEFAULT NULL,
    p_max_attempts INT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    cap INT := COALESCE(get_config_int('ingest.job_max_content_chars'), 2000000);
    existing UUID;
    job_id UUID;
BEGIN
    IF p_kind NOT IN ('text', 'url') THEN
        RAISE EXCEPTION 'ingestion job kind must be text or url, not %', p_kind;
    END IF;
    IF p_kind = 'text' AND NULLIF(p_content, '') IS NULL THEN
        RAISE EXCEPTION 'text ingestion jobs require content';
    END IF;
    IF p_content IS NOT NULL AND length(p_content) > cap THEN
        RAISE EXCEPTION 'content is % chars; the job cap is % — use the synchronous CLI path (hexis ingest) for oversized documents',
            length(p_content), cap;
    END IF;

    -- Idempotent enqueue: an active job for the same content is THE job.
    IF p_content_hash IS NOT NULL THEN
        SELECT id INTO existing FROM ingestion_jobs
        WHERE content_hash = p_content_hash AND status IN ('pending', 'in_progress')
        LIMIT 1;
        IF existing IS NOT NULL THEN
            RETURN existing;
        END IF;
    END IF;

    INSERT INTO ingestion_jobs (kind, payload, content, content_hash, max_attempts)
    VALUES (p_kind, COALESCE(p_payload, '{}'::jsonb), p_content, p_content_hash,
            GREATEST(COALESCE(p_max_attempts, 3), 1))
    RETURNING id INTO job_id;
    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claim_ingestion_jobs(
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(COALESCE(p_limit, get_config_int('ingest.job_batch_size'), 1), 1);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('ingest.job_claim_timeout_s'), 1800);
    claimed JSONB;
BEGIN
    WITH candidate AS (
        SELECT id FROM ingestion_jobs
        WHERE (status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP)
           OR (status = 'in_progress'
               AND claimed_at < CURRENT_TIMESTAMP - make_interval(secs => timeout_s))
        ORDER BY next_attempt_at, created_at
        LIMIT lim
        FOR UPDATE SKIP LOCKED
    ), updated AS (
        UPDATE ingestion_jobs j
        SET status = 'in_progress',
            attempts = j.attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE j.id = c.id
        RETURNING j.*
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(u)), '[]'::jsonb) INTO claimed FROM updated u;
    RETURN claimed;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION complete_ingestion_job(
    p_job_id UUID,
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
    UPDATE ingestion_jobs
    SET status = 'completed',
        result = COALESCE(p_result, '{}'::jsonb),
        error = NULL,
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id
    RETURNING jsonb_build_object('id', id, 'status', status);
$$ LANGUAGE sql;

-- Failure either reschedules with exponential backoff or goes terminal.
CREATE OR REPLACE FUNCTION fail_ingestion_job(
    p_job_id UUID,
    p_error TEXT
) RETURNS JSONB AS $$
DECLARE
    job ingestion_jobs%ROWTYPE;
    retry_base INT := COALESCE(get_config_int('ingest.job_retry_base_seconds'), 60);
BEGIN
    SELECT * INTO job FROM ingestion_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('id', p_job_id, 'status', 'missing');
    END IF;

    IF job.cancel_requested OR job.status = 'cancelled' THEN
        UPDATE ingestion_jobs
        SET status = 'cancelled', error = p_error,
            completed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id;
        RETURN jsonb_build_object('id', p_job_id, 'status', 'cancelled');
    END IF;

    IF job.attempts >= job.max_attempts THEN
        UPDATE ingestion_jobs
        SET status = 'failed', error = p_error,
            completed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id;
        RETURN jsonb_build_object('id', p_job_id, 'status', 'failed', 'attempts', job.attempts);
    END IF;

    UPDATE ingestion_jobs
    SET status = 'pending',
        error = p_error,
        next_attempt_at = CURRENT_TIMESTAMP
            + make_interval(secs => retry_base * power(2, job.attempts - 1)),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id;
    RETURN jsonb_build_object(
        'id', p_job_id, 'status', 'pending', 'attempts', job.attempts,
        'retry_in_seconds', retry_base * power(2, job.attempts - 1));
END;
$$ LANGUAGE plpgsql;

-- Progress heartbeat: merges progress, extends the stale window, and hands
-- back cancel_requested so the worker's per-section cancel check is one
-- round trip.
CREATE OR REPLACE FUNCTION update_ingestion_job_progress(
    p_job_id UUID,
    p_progress JSONB
) RETURNS BOOLEAN AS $$
    UPDATE ingestion_jobs
    SET progress = progress || COALESCE(p_progress, '{}'::jsonb),
        claimed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id AND status = 'in_progress'
    RETURNING cancel_requested;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION cancel_ingestion_job(
    p_job_id UUID
) RETURNS JSONB AS $$
DECLARE
    job ingestion_jobs%ROWTYPE;
BEGIN
    SELECT * INTO job FROM ingestion_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('id', p_job_id, 'status', 'missing');
    END IF;
    IF job.status = 'pending' THEN
        UPDATE ingestion_jobs
        SET status = 'cancelled', completed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id;
        RETURN jsonb_build_object('id', p_job_id, 'status', 'cancelled');
    END IF;
    IF job.status = 'in_progress' THEN
        UPDATE ingestion_jobs
        SET cancel_requested = TRUE, updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id;
        RETURN jsonb_build_object('id', p_job_id, 'status', 'cancel_requested');
    END IF;
    RETURN jsonb_build_object('id', p_job_id, 'status', job.status);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_ingestion_job(
    p_job_id UUID
) RETURNS JSONB AS $$
    SELECT to_jsonb(j) - 'content' FROM ingestion_jobs j WHERE j.id = p_job_id;
$$ LANGUAGE sql STABLE;
