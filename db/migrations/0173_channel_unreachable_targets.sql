-- 0173: Channel unreachable-target quarantine.
--
-- Reference integration stacks avoid hammering platform targets that have
-- clearly gone away. Keep this in the DB so channel workers remain swappable:
-- delivery code asks the database whether a target is temporarily suppressed,
-- marks confirmed unreachable targets, and clears the marker on any later
-- successful delivery.

CREATE TABLE IF NOT EXISTS channel_unreachable_targets (
    channel_type TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT '',
    error_kind TEXT NOT NULL DEFAULT 'unreachable',
    failure_count INTEGER NOT NULL DEFAULT 1,
    marked_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    suppress_until TIMESTAMPTZ NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (channel_type, channel_id)
);

CREATE INDEX IF NOT EXISTS idx_channel_unreachable_targets_suppress_until
    ON channel_unreachable_targets(suppress_until);

CREATE OR REPLACE FUNCTION should_skip_channel_target(
    p_channel_type TEXT,
    p_channel_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    target_row channel_unreachable_targets%ROWTYPE;
BEGIN
    IF NULLIF(TRIM(COALESCE(p_channel_type, '')), '') IS NULL
       OR NULLIF(TRIM(COALESCE(p_channel_id, '')), '') IS NULL THEN
        RETURN jsonb_build_object('skip', false);
    END IF;

    SELECT *
    INTO target_row
    FROM channel_unreachable_targets
    WHERE channel_type = LOWER(TRIM(p_channel_type))
      AND channel_id = TRIM(p_channel_id);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('skip', false);
    END IF;

    IF target_row.suppress_until <= CURRENT_TIMESTAMP THEN
        RETURN jsonb_build_object(
            'skip', false,
            'expired', true,
            'reason', target_row.reason,
            'error_kind', target_row.error_kind
        );
    END IF;

    RETURN jsonb_build_object(
        'skip', true,
        'reason', target_row.reason,
        'error_kind', target_row.error_kind,
        'failure_count', target_row.failure_count,
        'suppress_until', target_row.suppress_until,
        'metadata', target_row.metadata
    );
END;
$$;

CREATE OR REPLACE FUNCTION mark_channel_target_unreachable(
    p_channel_type TEXT,
    p_channel_id TEXT,
    p_reason TEXT DEFAULT '',
    p_error_kind TEXT DEFAULT 'unreachable',
    p_suppress_seconds INTEGER DEFAULT 86400,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_type TEXT := LOWER(TRIM(COALESCE(p_channel_type, '')));
    normalized_id TEXT := TRIM(COALESCE(p_channel_id, ''));
    seconds INTEGER := LEAST(GREATEST(COALESCE(p_suppress_seconds, 86400), 60), 604800);
    result_row channel_unreachable_targets%ROWTYPE;
BEGIN
    IF NULLIF(normalized_type, '') IS NULL OR NULLIF(normalized_id, '') IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'channel_type and channel_id are required');
    END IF;

    INSERT INTO channel_unreachable_targets (
        channel_type,
        channel_id,
        reason,
        error_kind,
        failure_count,
        suppress_until,
        metadata
    )
    VALUES (
        normalized_type,
        normalized_id,
        LEFT(COALESCE(p_reason, ''), 500),
        LEFT(COALESCE(NULLIF(p_error_kind, ''), 'unreachable'), 80),
        1,
        CURRENT_TIMESTAMP + make_interval(secs => seconds),
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (channel_type, channel_id) DO UPDATE
    SET reason = EXCLUDED.reason,
        error_kind = EXCLUDED.error_kind,
        failure_count = channel_unreachable_targets.failure_count + 1,
        updated_at = CURRENT_TIMESTAMP,
        suppress_until = CURRENT_TIMESTAMP + make_interval(
            secs => LEAST(
                604800,
                seconds * LEAST(8, GREATEST(1, channel_unreachable_targets.failure_count + 1))
            )
        ),
        metadata = COALESCE(channel_unreachable_targets.metadata, '{}'::jsonb)
            || COALESCE(EXCLUDED.metadata, '{}'::jsonb)
    RETURNING * INTO result_row;

    RETURN jsonb_build_object(
        'success', true,
        'channel_type', result_row.channel_type,
        'channel_id', result_row.channel_id,
        'failure_count', result_row.failure_count,
        'suppress_until', result_row.suppress_until,
        'reason', result_row.reason,
        'error_kind', result_row.error_kind
    );
END;
$$;

CREATE OR REPLACE FUNCTION clear_channel_target_unreachable(
    p_channel_type TEXT,
    p_channel_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_type TEXT := LOWER(TRIM(COALESCE(p_channel_type, '')));
    normalized_id TEXT := TRIM(COALESCE(p_channel_id, ''));
    deleted_count INTEGER := 0;
BEGIN
    IF NULLIF(normalized_type, '') IS NULL OR NULLIF(normalized_id, '') IS NULL THEN
        RETURN false;
    END IF;

    DELETE FROM channel_unreachable_targets
    WHERE channel_type = normalized_type
      AND channel_id = normalized_id;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count > 0;
END;
$$;
