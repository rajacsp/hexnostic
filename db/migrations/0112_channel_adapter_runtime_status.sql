-- Channel adapter runtime status for setup UX and diagnostics.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS channel_adapter_runtime (
    channel_type TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'unknown'
        CHECK (status IN ('unknown', 'not_configured', 'configured', 'starting', 'running', 'stopped', 'error', 'missing_dependency')),
    configured BOOLEAN NOT NULL DEFAULT FALSE,
    running BOOLEAN NOT NULL DEFAULT FALSE,
    worker_id TEXT,
    pid INT,
    last_checked_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_started_at TIMESTAMPTZ,
    last_stopped_at TIMESTAMPTZ,
    last_error TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_channel_adapter_runtime_status
    ON channel_adapter_runtime (status, updated_at DESC);

CREATE OR REPLACE FUNCTION record_channel_adapter_status(
    p_channel_type TEXT,
    p_status TEXT,
    p_configured BOOLEAN DEFAULT NULL,
    p_running BOOLEAN DEFAULT NULL,
    p_error TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_channel TEXT := lower(NULLIF(btrim(COALESCE(p_channel_type, '')), ''));
    normalized_status TEXT := lower(NULLIF(btrim(COALESCE(p_status, '')), ''));
    row_status channel_adapter_runtime%ROWTYPE;
BEGIN
    IF normalized_channel IS NULL THEN
        RAISE EXCEPTION 'channel_type is required';
    END IF;
    IF normalized_status IS NULL THEN
        normalized_status := 'unknown';
    END IF;
    IF normalized_status NOT IN (
        'unknown', 'not_configured', 'configured', 'starting', 'running',
        'stopped', 'error', 'missing_dependency'
    ) THEN
        RAISE EXCEPTION 'invalid channel adapter status: %', p_status;
    END IF;

    INSERT INTO channel_adapter_runtime (
        channel_type,
        status,
        configured,
        running,
        worker_id,
        pid,
        last_checked_at,
        last_started_at,
        last_stopped_at,
        last_error,
        metadata
    )
    VALUES (
        normalized_channel,
        normalized_status,
        COALESCE(p_configured, normalized_status IN ('configured', 'starting', 'running', 'error', 'stopped')),
        COALESCE(p_running, normalized_status IN ('starting', 'running')),
        COALESCE(NULLIF(p_metadata->>'worker_id', ''), inet_client_addr()::text),
        pg_backend_pid(),
        CURRENT_TIMESTAMP,
        CASE WHEN normalized_status IN ('starting', 'running') THEN CURRENT_TIMESTAMP ELSE NULL END,
        CASE WHEN normalized_status = 'stopped' THEN CURRENT_TIMESTAMP ELSE NULL END,
        NULLIF(p_error, ''),
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (channel_type) DO UPDATE SET
        status = EXCLUDED.status,
        configured = EXCLUDED.configured,
        running = EXCLUDED.running,
        worker_id = COALESCE(EXCLUDED.worker_id, channel_adapter_runtime.worker_id),
        pid = EXCLUDED.pid,
        last_checked_at = CURRENT_TIMESTAMP,
        last_started_at = CASE
            WHEN EXCLUDED.status IN ('starting', 'running') THEN CURRENT_TIMESTAMP
            ELSE channel_adapter_runtime.last_started_at
        END,
        last_stopped_at = CASE
            WHEN EXCLUDED.status = 'stopped' THEN CURRENT_TIMESTAMP
            ELSE channel_adapter_runtime.last_stopped_at
        END,
        last_error = CASE
            WHEN EXCLUDED.status IN ('error', 'missing_dependency') THEN EXCLUDED.last_error
            WHEN EXCLUDED.status IN ('starting', 'running', 'configured') THEN NULL
            ELSE COALESCE(EXCLUDED.last_error, channel_adapter_runtime.last_error)
        END,
        metadata = channel_adapter_runtime.metadata || EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_status;

    RETURN jsonb_build_object(
        'channel_type', row_status.channel_type,
        'status', row_status.status,
        'configured', row_status.configured,
        'running', row_status.running,
        'worker_id', row_status.worker_id,
        'pid', row_status.pid,
        'last_checked_at', row_status.last_checked_at,
        'last_started_at', row_status.last_started_at,
        'last_stopped_at', row_status.last_stopped_at,
        'last_error', row_status.last_error,
        'metadata', row_status.metadata,
        'updated_at', row_status.updated_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION list_channel_adapter_status(
    p_channel_type TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'channel_type', channel_type,
            'status', status,
            'configured', configured,
            'running', running,
            'worker_id', worker_id,
            'pid', pid,
            'last_checked_at', last_checked_at,
            'last_started_at', last_started_at,
            'last_stopped_at', last_stopped_at,
            'last_error', last_error,
            'metadata', metadata,
            'updated_at', updated_at
        )
        ORDER BY channel_type
    ), '[]'::jsonb)
    FROM channel_adapter_runtime
    WHERE NULLIF(btrim(COALESCE(p_channel_type, '')), '') IS NULL
       OR channel_type = lower(btrim(p_channel_type));
$$;
