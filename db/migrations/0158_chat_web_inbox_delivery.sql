-- Chat-originated notes to the user should appear in the dashboard inbox
-- immediately. The durable outbox row remains the audit/envelope source, but
-- explicit web_inbox delivery does not depend on RabbitMQ/channel-worker relay.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION queue_web_inbox_message(
    p_message TEXT,
    p_intent TEXT DEFAULT NULL,
    p_source TEXT DEFAULT 'tool'
) RETURNS JSONB AS $$
DECLARE
    outbox_id UUID;
    envelope JSONB;
    web_inbox_id UUID;
BEGIN
    outbox_id := queue_outbox_message(
        p_message,
        p_intent,
        p_source,
        '{"mode":"web_inbox"}'::jsonb
    );

    SELECT o.envelope
    INTO envelope
    FROM outbox_messages o
    WHERE o.id = outbox_id;

    web_inbox_id := web_inbox_deliver(jsonb_build_object(
        'id', envelope->>'message_id',
        'kind', envelope->>'kind',
        'payload', envelope->'payload'
    ));

    UPDATE outbox_messages
    SET status = 'published',
        claimed_at = COALESCE(claimed_at, CURRENT_TIMESTAMP),
        published_at = CURRENT_TIMESTAMP
    WHERE id = outbox_id;

    RETURN jsonb_build_object(
        'queued', true,
        'delivered', web_inbox_id IS NOT NULL,
        'outbox_id', outbox_id::text,
        'web_inbox_id', CASE WHEN web_inbox_id IS NULL THEN NULL ELSE web_inbox_id::text END,
        'delivery', jsonb_build_object('mode', 'web_inbox'),
        'envelope', envelope
    );
END;
$$ LANGUAGE plpgsql;
