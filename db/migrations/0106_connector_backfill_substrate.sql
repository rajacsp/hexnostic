-- 0106: connector backfill cursor/job/source-item substrate.
SET search_path = public, ag_catalog, "$user";

-- DB-owned connector backfill substrate. Provider adapters fetch pages and
-- bodies; Postgres owns cursor state, retry/pause lifecycle, provider-item
-- receipts, and the link from raw channel items to source_documents.
CREATE TABLE IF NOT EXISTS connector_sync_cursors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id UUID NOT NULL REFERENCES integration_connections(id) ON DELETE CASCADE,
    connector_id TEXT NOT NULL,
    account_key TEXT NOT NULL,
    cursor_key TEXT NOT NULL DEFAULT 'default',
    cursor_value JSONB NOT NULL DEFAULT '{}'::jsonb,
    high_watermark TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'error')),
    last_started_at TIMESTAMPTZ,
    last_completed_at TIMESTAMPTZ,
    last_error TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (connection_id, cursor_key)
);

CREATE INDEX IF NOT EXISTS idx_connector_sync_cursors_status
    ON connector_sync_cursors (connector_id, account_key, status, updated_at DESC);

CREATE TABLE IF NOT EXISTS connector_backfill_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id UUID NOT NULL REFERENCES integration_connections(id) ON DELETE CASCADE,
    connector_id TEXT NOT NULL,
    account_key TEXT NOT NULL,
    cursor_key TEXT NOT NULL DEFAULT 'default',
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'paused', 'completed', 'failed', 'cancelled')),
    requested_range JSONB NOT NULL DEFAULT '{}'::jsonb,
    progress JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    error TEXT,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    pause_requested BOOLEAN NOT NULL DEFAULT FALSE,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_connector_backfill_jobs_active
    ON connector_backfill_jobs (connection_id, cursor_key)
    WHERE status IN ('pending', 'in_progress', 'paused');
CREATE INDEX IF NOT EXISTS idx_connector_backfill_jobs_pending
    ON connector_backfill_jobs (status, next_attempt_at, created_at)
    WHERE status IN ('pending', 'in_progress');

CREATE TABLE IF NOT EXISTS connector_source_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id UUID NOT NULL REFERENCES integration_connections(id) ON DELETE CASCADE,
    connector_id TEXT NOT NULL,
    account_key TEXT NOT NULL,
    provider_item_id TEXT NOT NULL,
    provider_thread_id TEXT,
    item_kind TEXT NOT NULL DEFAULT 'message',
    source_document_id UUID REFERENCES source_documents(id) ON DELETE SET NULL,
    content_hash TEXT NOT NULL,
    item_timestamp TIMESTAMPTZ,
    labels TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    participants JSONB NOT NULL DEFAULT '[]'::jsonb,
    attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
    ingestion_job_id UUID REFERENCES ingestion_jobs(id) ON DELETE SET NULL,
    sensitivity TEXT NOT NULL DEFAULT 'private'
        CHECK (sensitivity IN ('private', 'shared', 'public')),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'redacted', 'archived')),
    raw_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (connection_id, provider_item_id)
);

CREATE INDEX IF NOT EXISTS idx_connector_source_items_provider
    ON connector_source_items (connector_id, account_key, item_kind, provider_item_id);
CREATE INDEX IF NOT EXISTS idx_connector_source_items_time
    ON connector_source_items (connector_id, account_key, item_timestamp DESC)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_connector_source_items_metadata
    ON connector_source_items USING GIN (raw_metadata);

-- Connector backfill substrate: provider adapters fetch; Postgres owns
-- cursor lifecycle, retry policy, raw source-item receipts, and ingestion
-- linkage.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('connector.backfill_claim_timeout_s', '1800'::jsonb,
     'Seconds after which an in-progress connector backfill job can be reclaimed'),
    ('connector.backfill_retry_base_seconds', '60'::jsonb,
     'Base for exponential retry backoff when connector backfill fails'),
    ('connector.backfill_batch_size', '1'::jsonb,
     'Connector backfill jobs claimed per worker tick')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION _connector_connection(
    p_connector_id TEXT,
    p_account_key TEXT
) RETURNS integration_connections
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
BEGIN
    IF NULLIF(btrim(COALESCE(p_connector_id, '')), '') IS NULL THEN
        RAISE EXCEPTION 'connector_id is required';
    END IF;
    IF NULLIF(btrim(COALESCE(p_account_key, '')), '') IS NULL THEN
        RAISE EXCEPTION 'account_key is required';
    END IF;

    SELECT *
    INTO row_connection
    FROM integration_connections
    WHERE connector_id = p_connector_id
      AND account_key = p_account_key
      AND status = 'connected';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'connected integration %/% not found', p_connector_id, p_account_key;
    END IF;

    RETURN row_connection;
END;
$$;

CREATE OR REPLACE FUNCTION ensure_connector_cursor(
    p_connector_id TEXT,
    p_account_key TEXT,
    p_cursor_key TEXT DEFAULT 'default',
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
    row_cursor connector_sync_cursors%ROWTYPE;
    normalized_cursor TEXT := COALESCE(NULLIF(btrim(p_cursor_key), ''), 'default');
BEGIN
    row_connection := _connector_connection(p_connector_id, p_account_key);

    INSERT INTO connector_sync_cursors (
        connection_id,
        connector_id,
        account_key,
        cursor_key,
        metadata
    )
    VALUES (
        row_connection.id,
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (connection_id, cursor_key) DO UPDATE SET
        status = CASE
            WHEN connector_sync_cursors.status = 'error' THEN 'active'
            ELSE connector_sync_cursors.status
        END,
        metadata = connector_sync_cursors.metadata || EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_cursor;

    RETURN jsonb_build_object(
        'cursor_id', row_cursor.id::text,
        'connection_id', row_cursor.connection_id::text,
        'connector_id', row_cursor.connector_id,
        'account_key', row_cursor.account_key,
        'cursor_key', row_cursor.cursor_key,
        'cursor_value', row_cursor.cursor_value,
        'high_watermark', row_cursor.high_watermark,
        'status', row_cursor.status,
        'last_started_at', row_cursor.last_started_at,
        'last_completed_at', row_cursor.last_completed_at,
        'metadata', row_cursor.metadata
    );
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_connector_backfill_job(
    p_connector_id TEXT,
    p_account_key TEXT,
    p_cursor_key TEXT DEFAULT 'messages',
    p_requested_range JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_max_attempts INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
    row_job connector_backfill_jobs%ROWTYPE;
    normalized_cursor TEXT := COALESCE(NULLIF(btrim(p_cursor_key), ''), 'messages');
    existing_id UUID;
BEGIN
    row_connection := _connector_connection(p_connector_id, p_account_key);
    PERFORM ensure_connector_cursor(
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_metadata, '{}'::jsonb)
    );

    SELECT id
    INTO existing_id
    FROM connector_backfill_jobs
    WHERE connection_id = row_connection.id
      AND cursor_key = normalized_cursor
      AND status IN ('pending', 'in_progress', 'paused')
    ORDER BY created_at DESC
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
        SELECT * INTO row_job FROM connector_backfill_jobs WHERE id = existing_id;
        RETURN jsonb_build_object(
            'job_id', row_job.id::text,
            'existing', TRUE,
            'status', row_job.status,
            'connector_id', row_job.connector_id,
            'account_key', row_job.account_key,
            'cursor_key', row_job.cursor_key,
            'requested_range', row_job.requested_range,
            'progress', row_job.progress
        );
    END IF;

    INSERT INTO connector_backfill_jobs (
        connection_id,
        connector_id,
        account_key,
        cursor_key,
        requested_range,
        metadata,
        max_attempts
    )
    VALUES (
        row_connection.id,
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_requested_range, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        GREATEST(COALESCE(p_max_attempts, 3), 1)
    )
    RETURNING * INTO row_job;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'existing', FALSE,
        'status', row_job.status,
        'connector_id', row_job.connector_id,
        'account_key', row_job.account_key,
        'cursor_key', row_job.cursor_key,
        'requested_range', row_job.requested_range,
        'progress', row_job.progress,
        'next_attempt_at', row_job.next_attempt_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION claim_connector_backfill_jobs(
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := GREATEST(COALESCE(p_limit, get_config_int('connector.backfill_batch_size'), 1), 1);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('connector.backfill_claim_timeout_s'), 1800);
    claimed JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM connector_backfill_jobs
        WHERE (
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

CREATE OR REPLACE FUNCTION advance_connector_cursor(
    p_connector_id TEXT,
    p_account_key TEXT,
    p_cursor_key TEXT DEFAULT 'messages',
    p_cursor_value JSONB DEFAULT '{}'::jsonb,
    p_high_watermark TIMESTAMPTZ DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
    row_cursor connector_sync_cursors%ROWTYPE;
    normalized_cursor TEXT := COALESCE(NULLIF(btrim(p_cursor_key), ''), 'messages');
BEGIN
    row_connection := _connector_connection(p_connector_id, p_account_key);

    INSERT INTO connector_sync_cursors (
        connection_id,
        connector_id,
        account_key,
        cursor_key,
        cursor_value,
        high_watermark,
        status,
        last_completed_at,
        metadata
    )
    VALUES (
        row_connection.id,
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_cursor_value, '{}'::jsonb),
        p_high_watermark,
        'active',
        CURRENT_TIMESTAMP,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (connection_id, cursor_key) DO UPDATE SET
        cursor_value = EXCLUDED.cursor_value,
        high_watermark = COALESCE(EXCLUDED.high_watermark, connector_sync_cursors.high_watermark),
        status = 'active',
        last_completed_at = CURRENT_TIMESTAMP,
        last_error = NULL,
        metadata = connector_sync_cursors.metadata || EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_cursor;

    RETURN jsonb_build_object(
        'cursor_id', row_cursor.id::text,
        'connection_id', row_cursor.connection_id::text,
        'connector_id', row_cursor.connector_id,
        'account_key', row_cursor.account_key,
        'cursor_key', row_cursor.cursor_key,
        'cursor_value', row_cursor.cursor_value,
        'high_watermark', row_cursor.high_watermark,
        'status', row_cursor.status,
        'last_completed_at', row_cursor.last_completed_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION update_connector_backfill_progress(
    p_job_id UUID,
    p_progress JSONB DEFAULT '{}'::jsonb,
    p_cursor_value JSONB DEFAULT NULL,
    p_high_watermark TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
BEGIN
    SELECT *
    INTO row_job
    FROM connector_backfill_jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing');
    END IF;

    UPDATE connector_backfill_jobs
    SET progress = progress || COALESCE(p_progress, '{}'::jsonb),
        claimed_at = CASE WHEN status = 'in_progress' THEN CURRENT_TIMESTAMP ELSE claimed_at END,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id
    RETURNING * INTO row_job;

    IF p_cursor_value IS NOT NULL AND p_cursor_value <> 'null'::jsonb THEN
        PERFORM advance_connector_cursor(
            row_job.connector_id,
            row_job.account_key,
            row_job.cursor_key,
            p_cursor_value,
            p_high_watermark,
            jsonb_build_object('advanced_by_job_id', p_job_id::text)
        );
    END IF;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'cancel_requested', row_job.cancel_requested,
        'pause_requested', row_job.pause_requested,
        'progress', row_job.progress
    );
END;
$$;

CREATE OR REPLACE FUNCTION complete_connector_backfill_job(
    p_job_id UUID,
    p_result JSONB DEFAULT '{}'::jsonb,
    p_cursor_value JSONB DEFAULT NULL,
    p_high_watermark TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
BEGIN
    SELECT *
    INTO row_job
    FROM connector_backfill_jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing');
    END IF;

    IF p_cursor_value IS NOT NULL AND p_cursor_value <> 'null'::jsonb THEN
        PERFORM advance_connector_cursor(
            row_job.connector_id,
            row_job.account_key,
            row_job.cursor_key,
            p_cursor_value,
            p_high_watermark,
            jsonb_build_object('completed_by_job_id', p_job_id::text)
        );
    END IF;

    UPDATE connector_backfill_jobs
    SET status = 'completed',
        result = COALESCE(p_result, '{}'::jsonb),
        error = NULL,
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id
    RETURNING * INTO row_job;

    UPDATE connector_sync_cursors
    SET status = 'active',
        last_completed_at = CURRENT_TIMESTAMP,
        last_error = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE connection_id = row_job.connection_id
      AND cursor_key = row_job.cursor_key;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'result', row_job.result
    );
END;
$$;

CREATE OR REPLACE FUNCTION fail_connector_backfill_job(
    p_job_id UUID,
    p_error TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
    retry_base INT := COALESCE(get_config_int('connector.backfill_retry_base_seconds'), 60);
BEGIN
    SELECT *
    INTO row_job
    FROM connector_backfill_jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing');
    END IF;

    IF row_job.cancel_requested OR row_job.status = 'cancelled' THEN
        UPDATE connector_backfill_jobs
        SET status = 'cancelled',
            error = COALESCE(NULLIF(p_error, ''), 'cancelled'),
            completed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
        RETURN jsonb_build_object('job_id', row_job.id::text, 'status', row_job.status);
    END IF;

    IF row_job.pause_requested OR row_job.status = 'paused' THEN
        UPDATE connector_backfill_jobs
        SET status = 'paused',
            error = COALESCE(NULLIF(p_error, ''), 'paused'),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
        UPDATE connector_sync_cursors
        SET status = 'paused',
            last_error = row_job.error,
            updated_at = CURRENT_TIMESTAMP
        WHERE connection_id = row_job.connection_id
          AND cursor_key = row_job.cursor_key;
        RETURN jsonb_build_object('job_id', row_job.id::text, 'status', row_job.status);
    END IF;

    IF row_job.attempts >= row_job.max_attempts THEN
        UPDATE connector_backfill_jobs
        SET status = 'failed',
            error = COALESCE(NULLIF(p_error, ''), 'connector backfill failed'),
            completed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
        UPDATE connector_sync_cursors
        SET status = 'error',
            last_error = row_job.error,
            updated_at = CURRENT_TIMESTAMP
        WHERE connection_id = row_job.connection_id
          AND cursor_key = row_job.cursor_key;
        RETURN jsonb_build_object(
            'job_id', row_job.id::text,
            'status', row_job.status,
            'attempts', row_job.attempts
        );
    END IF;

    UPDATE connector_backfill_jobs
    SET status = 'pending',
        error = COALESCE(NULLIF(p_error, ''), 'connector backfill failed'),
        next_attempt_at = CURRENT_TIMESTAMP
            + make_interval(secs => retry_base * power(2, GREATEST(row_job.attempts - 1, 0))),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id
    RETURNING * INTO row_job;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'attempts', row_job.attempts,
        'retry_in_seconds', retry_base * power(2, GREATEST(row_job.attempts - 1, 0))
    );
END;
$$;

CREATE OR REPLACE FUNCTION pause_connector_backfill_job(
    p_job_id UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
BEGIN
    SELECT *
    INTO row_job
    FROM connector_backfill_jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing');
    END IF;

    IF row_job.status = 'pending' THEN
        UPDATE connector_backfill_jobs
        SET status = 'paused',
            pause_requested = TRUE,
            error = NULLIF(p_reason, ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
        UPDATE connector_sync_cursors
        SET status = 'paused',
            updated_at = CURRENT_TIMESTAMP
        WHERE connection_id = row_job.connection_id
          AND cursor_key = row_job.cursor_key;
    ELSIF row_job.status = 'in_progress' THEN
        UPDATE connector_backfill_jobs
        SET pause_requested = TRUE,
            error = NULLIF(p_reason, ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
    END IF;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'pause_requested', row_job.pause_requested
    );
END;
$$;

CREATE OR REPLACE FUNCTION resume_connector_backfill_job(
    p_job_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
BEGIN
    UPDATE connector_backfill_jobs
    SET status = CASE WHEN status = 'paused' THEN 'pending' ELSE status END,
        pause_requested = FALSE,
        error = NULL,
        next_attempt_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_job_id
      AND status IN ('pending', 'paused')
    RETURNING * INTO row_job;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing_or_not_resumable');
    END IF;

    UPDATE connector_sync_cursors
    SET status = 'active',
        updated_at = CURRENT_TIMESTAMP
    WHERE connection_id = row_job.connection_id
      AND cursor_key = row_job.cursor_key;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'pause_requested', row_job.pause_requested
    );
END;
$$;

CREATE OR REPLACE FUNCTION cancel_connector_backfill_job(
    p_job_id UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_job connector_backfill_jobs%ROWTYPE;
BEGIN
    SELECT *
    INTO row_job
    FROM connector_backfill_jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('job_id', p_job_id::text, 'status', 'missing');
    END IF;

    IF row_job.status IN ('pending', 'paused') THEN
        UPDATE connector_backfill_jobs
        SET status = 'cancelled',
            cancel_requested = TRUE,
            error = NULLIF(p_reason, ''),
            completed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
    ELSIF row_job.status = 'in_progress' THEN
        UPDATE connector_backfill_jobs
        SET cancel_requested = TRUE,
            error = NULLIF(p_reason, ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_job_id
        RETURNING * INTO row_job;
    END IF;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'status', row_job.status,
        'cancel_requested', row_job.cancel_requested
    );
END;
$$;

CREATE OR REPLACE FUNCTION upsert_connector_source_item(
    p_connector_id TEXT,
    p_account_key TEXT,
    p_provider_item_id TEXT,
    p_title TEXT,
    p_content TEXT,
    p_item_kind TEXT DEFAULT 'message',
    p_provider_thread_id TEXT DEFAULT NULL,
    p_item_timestamp TIMESTAMPTZ DEFAULT NULL,
    p_labels TEXT[] DEFAULT ARRAY[]::TEXT[],
    p_participants JSONB DEFAULT '[]'::jsonb,
    p_attachments JSONB DEFAULT '[]'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_sensitivity TEXT DEFAULT 'private',
    p_enqueue_ingestion BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
    existing_item connector_source_items%ROWTYPE;
    row_item connector_source_items%ROWTYPE;
    stored_doc JSONB;
    doc_id UUID;
    artifact_hash TEXT;
    normalized_kind TEXT := COALESCE(NULLIF(btrim(p_item_kind), ''), 'message');
    normalized_sensitivity TEXT := COALESCE(NULLIF(btrim(p_sensitivity), ''), 'private');
    provider_id TEXT := NULLIF(btrim(COALESCE(p_provider_item_id, '')), '');
    doc_path TEXT;
    source_type TEXT;
    source_attribution JSONB;
    metadata JSONB;
    job_id UUID := NULL;
    existing_found BOOLEAN := FALSE;
BEGIN
    IF provider_id IS NULL THEN
        RAISE EXCEPTION 'provider_item_id is required';
    END IF;
    IF p_content IS NULL THEN
        RAISE EXCEPTION 'connector source item content is required';
    END IF;
    IF normalized_sensitivity NOT IN ('private', 'shared', 'public') THEN
        RAISE EXCEPTION 'sensitivity must be private, shared, or public';
    END IF;

    row_connection := _connector_connection(p_connector_id, p_account_key);
    SELECT *
    INTO existing_item
    FROM connector_source_items
    WHERE connection_id = row_connection.id
      AND provider_item_id = provider_id;
    existing_found := FOUND;

    artifact_hash := 'connector:' || lower(row_connection.connector_id) || ':'
        || encode(sha256(convert_to(
            row_connection.id::text || chr(30) ||
            provider_id || chr(30) ||
            COALESCE(p_content, ''),
            'UTF8'
        )), 'hex');
    doc_path := row_connection.connector_id || '://' || row_connection.account_key || '/'
        || normalized_kind || '/' || provider_id;
    source_type := 'connector_' || normalized_kind;
    source_attribution := jsonb_build_object(
        'kind', 'connector_item',
        'connector_id', row_connection.connector_id,
        'account_key', row_connection.account_key,
        'connection_id', row_connection.id::text,
        'provider_item_id', provider_id,
        'provider_thread_id', NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
        'item_kind', normalized_kind,
        'content_hash', artifact_hash,
        'sensitivity', normalized_sensitivity
    );
    metadata := jsonb_build_object(
        'labels', COALESCE(to_jsonb(p_labels), '[]'::jsonb),
        'participants', COALESCE(p_participants, '[]'::jsonb),
        'attachments', COALESCE(p_attachments, '[]'::jsonb),
        'item_timestamp', p_item_timestamp,
        'raw_metadata', COALESCE(p_metadata, '{}'::jsonb)
    );

    stored_doc := upsert_source_document(
        COALESCE(NULLIF(btrim(p_title), ''), provider_id),
        source_type,
        artifact_hash,
        doc_path,
        COALESCE(NULLIF(p_metadata->>'file_type', ''), '.txt'),
        p_content,
        array_length(regexp_split_to_array(btrim(COALESCE(p_content, '')), '\s+'), 1),
        source_attribution,
        metadata
    );
    doc_id := (stored_doc->>'document_id')::uuid;

    IF COALESCE(p_enqueue_ingestion, TRUE) THEN
        IF NOT existing_found THEN
            job_id := enqueue_ingestion_job(
                'text',
                jsonb_build_object(
                    'title', COALESCE(NULLIF(btrim(p_title), ''), provider_id),
                    'mode', 'fast',
                    'source_type', source_type,
                    'source_document_id', doc_id::text,
                    'connector_id', row_connection.connector_id,
                    'account_key', row_connection.account_key,
                    'provider_item_id', provider_id,
                    'provider_thread_id', NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
                    'sensitivity', normalized_sensitivity
                ),
                p_content,
                artifact_hash
            );
        ELSIF existing_item.ingestion_job_id IS NULL
              OR existing_item.content_hash <> artifact_hash THEN
            job_id := enqueue_ingestion_job(
                'text',
                jsonb_build_object(
                    'title', COALESCE(NULLIF(btrim(p_title), ''), provider_id),
                    'mode', 'fast',
                    'source_type', source_type,
                    'source_document_id', doc_id::text,
                    'connector_id', row_connection.connector_id,
                    'account_key', row_connection.account_key,
                    'provider_item_id', provider_id,
                    'provider_thread_id', NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
                    'sensitivity', normalized_sensitivity
                ),
                p_content,
                artifact_hash
            );
        ELSE
            job_id := existing_item.ingestion_job_id;
        END IF;
    ELSIF existing_found THEN
        job_id := existing_item.ingestion_job_id;
    END IF;

    INSERT INTO connector_source_items (
        connection_id,
        connector_id,
        account_key,
        provider_item_id,
        provider_thread_id,
        item_kind,
        source_document_id,
        content_hash,
        item_timestamp,
        labels,
        participants,
        attachments,
        ingestion_job_id,
        sensitivity,
        raw_metadata
    )
    VALUES (
        row_connection.id,
        row_connection.connector_id,
        row_connection.account_key,
        provider_id,
        NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
        normalized_kind,
        doc_id,
        artifact_hash,
        p_item_timestamp,
        COALESCE(p_labels, ARRAY[]::TEXT[]),
        COALESCE(p_participants, '[]'::jsonb),
        COALESCE(p_attachments, '[]'::jsonb),
        job_id,
        normalized_sensitivity,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (connection_id, provider_item_id) DO UPDATE SET
        provider_thread_id = EXCLUDED.provider_thread_id,
        item_kind = EXCLUDED.item_kind,
        source_document_id = EXCLUDED.source_document_id,
        content_hash = EXCLUDED.content_hash,
        item_timestamp = EXCLUDED.item_timestamp,
        labels = EXCLUDED.labels,
        participants = EXCLUDED.participants,
        attachments = EXCLUDED.attachments,
        ingestion_job_id = COALESCE(EXCLUDED.ingestion_job_id, connector_source_items.ingestion_job_id),
        sensitivity = EXCLUDED.sensitivity,
        status = 'active',
        raw_metadata = connector_source_items.raw_metadata || EXCLUDED.raw_metadata,
        last_seen_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_item;

    RETURN jsonb_build_object(
        'source_item_id', row_item.id::text,
        'connection_id', row_item.connection_id::text,
        'connector_id', row_item.connector_id,
        'account_key', row_item.account_key,
        'provider_item_id', row_item.provider_item_id,
        'provider_thread_id', row_item.provider_thread_id,
        'item_kind', row_item.item_kind,
        'document_id', row_item.source_document_id::text,
        'content_hash', row_item.content_hash,
        'ingestion_job_id', row_item.ingestion_job_id::text,
        'sensitivity', row_item.sensitivity,
        'status', row_item.status
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_connector_backfill_status(
    p_connector_id TEXT DEFAULT NULL,
    p_account_key TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    cursors JSONB;
    jobs JSONB;
    item_counts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'cursor_id', id::text,
            'connection_id', connection_id::text,
            'connector_id', connector_id,
            'account_key', account_key,
            'cursor_key', cursor_key,
            'cursor_value', cursor_value,
            'high_watermark', high_watermark,
            'status', status,
            'last_started_at', last_started_at,
            'last_completed_at', last_completed_at,
            'last_error', last_error,
            'updated_at', updated_at
        )
        ORDER BY updated_at DESC, connector_id, account_key, cursor_key
    ), '[]'::jsonb)
    INTO cursors
    FROM connector_sync_cursors
    WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
      AND (p_account_key IS NULL OR account_key = p_account_key);

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'job_id', id::text,
            'connection_id', connection_id::text,
            'connector_id', connector_id,
            'account_key', account_key,
            'cursor_key', cursor_key,
            'status', status,
            'attempts', attempts,
            'max_attempts', max_attempts,
            'progress', progress,
            'result', result,
            'error', error,
            'cancel_requested', cancel_requested,
            'pause_requested', pause_requested,
            'next_attempt_at', next_attempt_at,
            'claimed_at', claimed_at,
            'completed_at', completed_at,
            'updated_at', updated_at
        )
        ORDER BY created_at DESC
    ), '[]'::jsonb)
    INTO jobs
    FROM connector_backfill_jobs
    WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
      AND (p_account_key IS NULL OR account_key = p_account_key)
      AND created_at >= CURRENT_TIMESTAMP - INTERVAL '7 days';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'connector_id', connector_id,
            'account_key', account_key,
            'item_kind', item_kind,
            'status', status,
            'count', item_count,
            'latest_item_at', latest_item_at
        )
        ORDER BY connector_id, account_key, item_kind, status
    ), '[]'::jsonb)
    INTO item_counts
    FROM (
        SELECT
            connector_id,
            account_key,
            item_kind,
            status,
            COUNT(*)::INT AS item_count,
            MAX(item_timestamp) AS latest_item_at
        FROM connector_source_items
        WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
          AND (p_account_key IS NULL OR account_key = p_account_key)
        GROUP BY connector_id, account_key, item_kind, status
    ) grouped;

    RETURN jsonb_build_object(
        'cursors', cursors,
        'jobs', jobs,
        'item_counts', item_counts
    );
END;
$$;
