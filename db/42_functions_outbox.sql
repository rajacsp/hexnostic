-- DB-native transactional outbox for agent-initiated user messages.
--
-- Previously the queue_user_message tool INSERTed into a non-existent
-- `external_calls` table (it always threw), and the agentic heartbeat loop had
-- no delivery path for tool-produced messages at all. This gives tools a real
-- place to durably queue a message; the maintenance worker drains it to the
-- RabbitMQ outbox using the same envelope shape as heartbeat outbox messages.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS outbox_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    envelope JSONB NOT NULL,   -- build_user_message() shape: {message_id, kind, payload}
    source TEXT NOT NULL DEFAULT 'tool',
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'publishing', 'published', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_at TIMESTAMPTZ,
    published_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_outbox_messages_pending
    ON outbox_messages (created_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_outbox_messages_publishing
    ON outbox_messages (claimed_at)
    WHERE status = 'publishing';

-- Durably enqueue a user-facing message. Returns the row id.
CREATE OR REPLACE FUNCTION queue_outbox_message(
    p_message TEXT,
    p_intent TEXT DEFAULT NULL,
    p_source TEXT DEFAULT 'tool',
    -- Optional explicit delivery doc (#98): e.g. {"mode": "web_inbox"} pins
    -- a message to the dashboard inbox instead of last-active routing.
    p_delivery JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    new_id UUID;
    envelope JSONB;
BEGIN
    IF NULLIF(btrim(p_message), '') IS NULL THEN
        RAISE EXCEPTION 'outbox message is required';
    END IF;
    envelope := build_user_message(p_message, p_intent);
    IF p_delivery IS NOT NULL THEN
        envelope := jsonb_set(envelope, '{payload,delivery}', p_delivery);
    END IF;
    INSERT INTO outbox_messages (envelope, source)
    VALUES (envelope, COALESCE(NULLIF(p_source, ''), 'tool'))
    RETURNING id INTO new_id;
    RETURN new_id;
END;
$$;

-- Claim pending messages (and reclaim stale 'publishing' rows whose publisher
-- died) for delivery. Marks them 'publishing' and returns [{id, envelope}].
CREATE OR REPLACE FUNCTION claim_pending_outbox(
    p_limit INT DEFAULT 50,
    p_claim_timeout_s INT DEFAULT 120
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    result JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM outbox_messages
        WHERE status = 'pending'
           OR (status = 'publishing'
               AND claimed_at < CURRENT_TIMESTAMP - make_interval(secs => GREATEST(COALESCE(p_claim_timeout_s, 120), 1)))
        ORDER BY created_at
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 50), 1)
    ),
    claimed AS (
        UPDATE outbox_messages o
        SET status = 'publishing', claimed_at = CURRENT_TIMESTAMP
        FROM candidate
        WHERE o.id = candidate.id
        RETURNING o.id, o.envelope, o.created_at
    )
    SELECT COALESCE(
        jsonb_agg(jsonb_build_object('id', id::text, 'envelope', envelope) ORDER BY created_at),
        '[]'::jsonb)
    INTO result
    FROM claimed;
    RETURN result;
END;
$$;

-- Mark successfully-published messages done.
CREATE OR REPLACE FUNCTION mark_outbox_published(p_ids UUID[])
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    n INT;
BEGIN
    UPDATE outbox_messages
    SET status = 'published', published_at = CURRENT_TIMESTAMP
    WHERE id = ANY(COALESCE(p_ids, ARRAY[]::UUID[]))
      AND status = 'publishing';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Return claimed-but-unpublished messages to 'pending' so they retry promptly
-- (rather than waiting for the reclaim timeout).
CREATE OR REPLACE FUNCTION requeue_outbox(p_ids UUID[])
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    n INT;
BEGIN
    UPDATE outbox_messages
    SET status = 'pending', claimed_at = NULL
    WHERE id = ANY(COALESCE(p_ids, ARRAY[]::UUID[]))
      AND status = 'publishing';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;
