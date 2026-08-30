-- Durable, short-lived channel presence events for typing and adapter beacons.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS channel_presence_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_type TEXT NOT NULL,
    channel_id TEXT,
    presence_kind TEXT NOT NULL
        CHECK (presence_kind IN ('online', 'offline', 'typing', 'processing', 'idle')),
    direction TEXT NOT NULL DEFAULT 'system'
        CHECK (direction IN ('system', 'inbound', 'outbound')),
    sender_id TEXT,
    session_key TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_channel_presence_events_recent
    ON channel_presence_events (channel_type, channel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_channel_presence_events_live
    ON channel_presence_events (expires_at)
    WHERE expires_at IS NOT NULL;

CREATE OR REPLACE FUNCTION record_channel_presence(
    p_channel_type TEXT,
    p_channel_id TEXT DEFAULT NULL,
    p_presence_kind TEXT DEFAULT 'processing',
    p_direction TEXT DEFAULT 'system',
    p_sender_id TEXT DEFAULT NULL,
    p_session_key TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_ttl_seconds INT DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_channel TEXT := lower(NULLIF(btrim(COALESCE(p_channel_type, '')), ''));
    normalized_kind TEXT := lower(NULLIF(btrim(COALESCE(p_presence_kind, '')), ''));
    normalized_direction TEXT := lower(NULLIF(btrim(COALESCE(p_direction, '')), ''));
    row_event channel_presence_events%ROWTYPE;
BEGIN
    IF normalized_channel IS NULL THEN
        RAISE EXCEPTION 'channel_type is required';
    END IF;
    IF normalized_kind NOT IN ('online', 'offline', 'typing', 'processing', 'idle') THEN
        RAISE EXCEPTION 'invalid presence kind: %', p_presence_kind;
    END IF;
    IF normalized_direction NOT IN ('system', 'inbound', 'outbound') THEN
        normalized_direction := 'system';
    END IF;

    INSERT INTO channel_presence_events (
        channel_type,
        channel_id,
        presence_kind,
        direction,
        sender_id,
        session_key,
        metadata,
        expires_at
    )
    VALUES (
        normalized_channel,
        NULLIF(btrim(COALESCE(p_channel_id, '')), ''),
        normalized_kind,
        normalized_direction,
        NULLIF(btrim(COALESCE(p_sender_id, '')), ''),
        NULLIF(btrim(COALESCE(p_session_key, '')), ''),
        COALESCE(p_metadata, '{}'::jsonb),
        CASE
            WHEN normalized_kind IN ('offline', 'idle') THEN NULL
            ELSE CURRENT_TIMESTAMP + (GREATEST(COALESCE(p_ttl_seconds, 20), 1) * INTERVAL '1 second')
        END
    )
    RETURNING * INTO row_event;

    RETURN jsonb_build_object(
        'id', row_event.id,
        'channel_type', row_event.channel_type,
        'channel_id', row_event.channel_id,
        'presence_kind', row_event.presence_kind,
        'direction', row_event.direction,
        'sender_id', row_event.sender_id,
        'session_key', row_event.session_key,
        'metadata', row_event.metadata,
        'expires_at', row_event.expires_at,
        'created_at', row_event.created_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION channel_presence_summary(
    p_channel_type TEXT DEFAULT NULL,
    p_include_expired BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    WITH ranked AS (
        SELECT *,
               row_number() OVER (
                   PARTITION BY channel_type, COALESCE(channel_id, ''), presence_kind
                   ORDER BY created_at DESC
               ) AS rn
        FROM channel_presence_events
        WHERE (NULLIF(btrim(COALESCE(p_channel_type, '')), '') IS NULL
               OR channel_type = lower(btrim(p_channel_type)))
          AND (p_include_expired OR expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'channel_type', channel_type,
            'channel_id', channel_id,
            'presence_kind', presence_kind,
            'direction', direction,
            'sender_id', sender_id,
            'session_key', session_key,
            'metadata', metadata,
            'expires_at', expires_at,
            'created_at', created_at
        )
        ORDER BY created_at DESC
    ), '[]'::jsonb)
    FROM ranked
    WHERE rn = 1;
$$;
