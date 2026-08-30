-- DB-native concrete delivery obligation ledger for channel/webhook targets.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION upsert_channel_delivery_obligation(
    p_obligation_key TEXT,
    p_source_outbox_message_id TEXT,
    p_channel_type TEXT,
    p_channel_id TEXT,
    p_sender_id TEXT,
    p_thread_id TEXT,
    p_content TEXT,
    p_message JSONB,
    p_delivery_mode TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out channel_delivery_obligations%ROWTYPE;
BEGIN
    IF NULLIF(TRIM(COALESCE(p_obligation_key, '')), '') IS NULL THEN
        RAISE EXCEPTION 'obligation_key is required';
    END IF;
    IF NULLIF(TRIM(COALESCE(p_channel_type, '')), '') IS NULL
       OR NULLIF(TRIM(COALESCE(p_channel_id, '')), '') IS NULL THEN
        RAISE EXCEPTION 'channel_type and channel_id are required';
    END IF;
    IF NULLIF(TRIM(COALESCE(p_content, '')), '') IS NULL THEN
        RAISE EXCEPTION 'delivery content is required';
    END IF;

    INSERT INTO channel_delivery_obligations (
        obligation_key,
        source_outbox_message_id,
        channel_type,
        channel_id,
        sender_id,
        thread_id,
        content,
        message,
        delivery_mode
    ) VALUES (
        p_obligation_key,
        NULLIF(p_source_outbox_message_id, ''),
        LOWER(TRIM(p_channel_type)),
        TRIM(p_channel_id),
        NULLIF(p_sender_id, ''),
        NULLIF(p_thread_id, ''),
        p_content,
        COALESCE(p_message, '{}'::jsonb),
        COALESCE(NULLIF(p_delivery_mode, ''), 'direct')
    )
    ON CONFLICT (obligation_key) DO UPDATE
    SET source_outbox_message_id = COALESCE(EXCLUDED.source_outbox_message_id, channel_delivery_obligations.source_outbox_message_id),
        channel_type = EXCLUDED.channel_type,
        channel_id = EXCLUDED.channel_id,
        sender_id = EXCLUDED.sender_id,
        thread_id = EXCLUDED.thread_id,
        content = EXCLUDED.content,
        message = EXCLUDED.message,
        delivery_mode = EXCLUDED.delivery_mode,
        state = CASE
            WHEN channel_delivery_obligations.state = 'delivered' THEN channel_delivery_obligations.state
            WHEN channel_delivery_obligations.state = 'abandoned' THEN 'pending'
            ELSE channel_delivery_obligations.state
        END,
        next_attempt_at = CASE
            WHEN channel_delivery_obligations.state IN ('delivered', 'attempting') THEN channel_delivery_obligations.next_attempt_at
            ELSE CURRENT_TIMESTAMP
        END,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_out;

    RETURN jsonb_build_object(
        'id', row_out.id,
        'state', row_out.state,
        'already_delivered', row_out.state = 'delivered',
        'attempts', row_out.attempts
    );
END;
$$;

CREATE OR REPLACE FUNCTION claim_channel_delivery_obligation(
    p_obligation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out channel_delivery_obligations%ROWTYPE;
BEGIN
    UPDATE channel_delivery_obligations
    SET state = 'attempting',
        attempts = attempts + 1,
        attempting_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP,
        last_error = NULL
    WHERE id = p_obligation_id
      AND state NOT IN ('delivered', 'abandoned')
    RETURNING * INTO row_out;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('claimed', false);
    END IF;

    RETURN jsonb_build_object(
        'claimed', true,
        'id', row_out.id,
        'attempts', row_out.attempts
    );
END;
$$;

CREATE OR REPLACE FUNCTION mark_channel_delivery_obligation_delivered(
    p_obligation_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    updated_count INTEGER := 0;
BEGIN
    UPDATE channel_delivery_obligations
    SET state = 'delivered',
        delivered_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP,
        next_attempt_at = CURRENT_TIMESTAMP,
        last_error = NULL
    WHERE id = p_obligation_id;

    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('updated', updated_count);
END;
$$;

CREATE OR REPLACE FUNCTION mark_channel_delivery_obligation_failed(
    p_obligation_id UUID,
    p_error TEXT,
    p_retry_seconds INTEGER DEFAULT 300
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    retry_seconds INTEGER := LEAST(GREATEST(COALESCE(p_retry_seconds, 300), 30), 86400);
    updated_count INTEGER := 0;
BEGIN
    UPDATE channel_delivery_obligations
    SET state = 'failed',
        updated_at = CURRENT_TIMESTAMP,
        next_attempt_at = CURRENT_TIMESTAMP + make_interval(secs => retry_seconds),
        last_error = LEFT(COALESCE(p_error, 'delivery failed'), 2000)
    WHERE id = p_obligation_id
      AND state <> 'delivered';

    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('updated', updated_count, 'retry_seconds', retry_seconds);
END;
$$;

CREATE OR REPLACE FUNCTION claim_recoverable_channel_deliveries(
    p_limit INTEGER DEFAULT 25,
    p_stale_after INTERVAL DEFAULT INTERVAL '2 minutes',
    p_max_attempts INTEGER DEFAULT 3,
    p_stale_age INTERVAL DEFAULT INTERVAL '7 days'
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    result JSONB;
BEGIN
    WITH abandoned AS (
        UPDATE channel_delivery_obligations
        SET state = 'abandoned',
            updated_at = CURRENT_TIMESTAMP,
            last_error = COALESCE(last_error, 'delivery obligation abandoned after retry budget')
        WHERE state IN ('pending', 'attempting', 'failed')
          AND (
              attempts >= GREATEST(COALESCE(p_max_attempts, 3), 1)
              OR created_at < CURRENT_TIMESTAMP - COALESCE(p_stale_age, INTERVAL '7 days')
        )
        RETURNING id
    ),
    candidate AS (
        SELECT id, state AS previous_state
        FROM channel_delivery_obligations
        WHERE (
            state IN ('pending', 'failed')
            AND next_attempt_at <= CURRENT_TIMESTAMP
        ) OR (
            state = 'attempting'
            AND updated_at < CURRENT_TIMESTAMP - COALESCE(p_stale_after, INTERVAL '2 minutes')
        )
        ORDER BY next_attempt_at, updated_at, id
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 25), 1)
    ),
    claimed AS (
        UPDATE channel_delivery_obligations o
        SET state = 'attempting',
            attempts = attempts + 1,
            attempting_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP,
            last_error = NULL
        FROM candidate
        WHERE o.id = candidate.id
        RETURNING
            o.id,
            o.obligation_key,
            o.source_outbox_message_id,
            o.channel_type,
            o.channel_id,
            o.sender_id,
            o.thread_id,
            o.content,
            o.message,
            o.delivery_mode,
            o.attempts,
            candidate.previous_state
    )
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', id,
                'obligation_key', obligation_key,
                'source_outbox_message_id', source_outbox_message_id,
                'channel_type', channel_type,
                'channel_id', channel_id,
                'sender_id', sender_id,
                'thread_id', thread_id,
                'content', content,
                'message', message,
                'delivery_mode', delivery_mode,
                'attempts', attempts,
                'needs_marker', previous_state <> 'pending'
            )
            ORDER BY attempts, id
        ),
        '[]'::jsonb
    )
    INTO result
    FROM claimed;

    RETURN result;
END;
$$;
