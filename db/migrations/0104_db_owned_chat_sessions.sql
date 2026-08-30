-- 0104: DB-owned chat session history and hydration.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS chat_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    surface TEXT NOT NULL DEFAULT 'chat',
    external_id TEXT,
    title TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'archived')),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cleared_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_external
    ON chat_sessions (surface, external_id)
    WHERE external_id IS NOT NULL AND status = 'active';
CREATE INDEX IF NOT EXISTS idx_chat_sessions_active
    ON chat_sessions (surface, status, last_active_at DESC);

CREATE TABLE IF NOT EXISTS chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    ordinal INT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant')),
    content TEXT NOT NULL,
    visible_in_context BOOLEAN NOT NULL DEFAULT TRUE,
    source_message_id TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (session_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session_ordinal
    ON chat_messages (session_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_chat_messages_context
    ON chat_messages (session_id, visible_in_context, ordinal DESC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_metadata
    ON chat_messages USING GIN (metadata);

INSERT INTO config_defaults (key, value, description) VALUES
    ('chat.session_history_limit', '40'::jsonb,
     'Default number of visible chat-session messages hydrated into the active conversation context')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION get_or_create_chat_session(
    p_session_id UUID DEFAULT NULL,
    p_surface TEXT DEFAULT 'chat',
    p_external_id TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_session chat_sessions%ROWTYPE;
    normalized_surface TEXT := COALESCE(NULLIF(btrim(p_surface), ''), 'chat');
    normalized_external TEXT := NULLIF(btrim(COALESCE(p_external_id, '')), '');
BEGIN
    IF p_session_id IS NOT NULL THEN
        INSERT INTO chat_sessions (id, surface, external_id, metadata)
        VALUES (
            p_session_id,
            normalized_surface,
            normalized_external,
            COALESCE(p_metadata, '{}'::jsonb)
        )
        ON CONFLICT (id) DO UPDATE SET
            surface = COALESCE(NULLIF(chat_sessions.surface, ''), EXCLUDED.surface),
            external_id = COALESCE(chat_sessions.external_id, EXCLUDED.external_id),
            metadata = chat_sessions.metadata || EXCLUDED.metadata,
            updated_at = CURRENT_TIMESTAMP,
            last_active_at = CURRENT_TIMESTAMP
        RETURNING * INTO row_session;
    ELSIF normalized_external IS NOT NULL THEN
        SELECT *
        INTO row_session
        FROM chat_sessions
        WHERE surface = normalized_surface
          AND external_id = normalized_external
          AND status = 'active'
        ORDER BY last_active_at DESC
        LIMIT 1;

        IF NOT FOUND THEN
            INSERT INTO chat_sessions (surface, external_id, metadata)
            VALUES (
                normalized_surface,
                normalized_external,
                COALESCE(p_metadata, '{}'::jsonb)
            )
            RETURNING * INTO row_session;
        ELSE
            UPDATE chat_sessions
            SET metadata = metadata || COALESCE(p_metadata, '{}'::jsonb),
                updated_at = CURRENT_TIMESTAMP,
                last_active_at = CURRENT_TIMESTAMP
            WHERE id = row_session.id
            RETURNING * INTO row_session;
        END IF;
    ELSE
        INSERT INTO chat_sessions (surface, metadata)
        VALUES (normalized_surface, COALESCE(p_metadata, '{}'::jsonb))
        RETURNING * INTO row_session;
    END IF;

    RETURN jsonb_build_object(
        'session_id', row_session.id::text,
        'surface', row_session.surface,
        'external_id', row_session.external_id,
        'status', row_session.status,
        'metadata', row_session.metadata,
        'created_at', row_session.created_at,
        'last_active_at', row_session.last_active_at,
        'cleared_at', row_session.cleared_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION append_chat_message(
    p_session_id UUID,
    p_role TEXT,
    p_content TEXT,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_source_message_id TEXT DEFAULT NULL,
    p_visible_in_context BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_message chat_messages%ROWTYPE;
    next_ordinal INT;
    normalized_role TEXT := lower(COALESCE(NULLIF(btrim(p_role), ''), ''));
BEGIN
    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'session_id is required';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext(p_session_id::text));
    IF normalized_role NOT IN ('system', 'user', 'assistant') THEN
        RAISE EXCEPTION 'chat message role must be system, user, or assistant';
    END IF;
    IF p_content IS NULL THEN
        RAISE EXCEPTION 'chat message content is required';
    END IF;

    PERFORM get_or_create_chat_session(p_session_id);
    SELECT COALESCE(MAX(ordinal), -1) + 1
    INTO next_ordinal
    FROM chat_messages
    WHERE session_id = p_session_id;

    INSERT INTO chat_messages (
        session_id,
        ordinal,
        role,
        content,
        metadata,
        source_message_id,
        visible_in_context
    )
    VALUES (
        p_session_id,
        next_ordinal,
        normalized_role,
        p_content,
        COALESCE(p_metadata, '{}'::jsonb),
        NULLIF(btrim(COALESCE(p_source_message_id, '')), ''),
        COALESCE(p_visible_in_context, TRUE)
    )
    RETURNING * INTO row_message;

    UPDATE chat_sessions
    SET updated_at = CURRENT_TIMESTAMP,
        last_active_at = CURRENT_TIMESTAMP
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
        'message_id', row_message.id::text,
        'session_id', row_message.session_id::text,
        'ordinal', row_message.ordinal,
        'role', row_message.role,
        'content', row_message.content,
        'visible_in_context', row_message.visible_in_context,
        'metadata', row_message.metadata,
        'created_at', row_message.created_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION hydrate_chat_session(
    p_session_id UUID,
    p_limit INT DEFAULT NULL,
    p_include_system BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    row_session chat_sessions%ROWTYPE;
    lim INT := LEAST(
        GREATEST(COALESCE(p_limit, get_config_int('chat.session_history_limit'), 40), 1),
        200
    );
    messages JSONB;
BEGIN
    IF p_session_id IS NULL THEN
        RETURN jsonb_build_object('session_id', NULL, 'messages', '[]'::jsonb, 'count', 0);
    END IF;

    SELECT * INTO row_session
    FROM chat_sessions
    WHERE id = p_session_id
      AND status = 'active';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('session_id', p_session_id::text, 'messages', '[]'::jsonb, 'count', 0);
    END IF;

    WITH selected AS (
        SELECT role, content, ordinal, id, created_at, metadata
        FROM chat_messages
        WHERE session_id = p_session_id
          AND visible_in_context
          AND (p_include_system OR role <> 'system')
        ORDER BY ordinal DESC
        LIMIT lim
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'role', role,
            'content', content,
            'ordinal', ordinal,
            'message_id', id::text,
            'created_at', created_at,
            'metadata', metadata
        )
        ORDER BY ordinal ASC
    ), '[]'::jsonb)
    INTO messages
    FROM selected;

    RETURN jsonb_build_object(
        'session_id', row_session.id::text,
        'surface', row_session.surface,
        'external_id', row_session.external_id,
        'messages', messages,
        'count', jsonb_array_length(messages),
        'cleared_at', row_session.cleared_at,
        'last_active_at', row_session.last_active_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION record_chat_session_turn(
    p_session_id UUID,
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_surface TEXT DEFAULT 'chat',
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    session_payload JSONB;
    user_message JSONB := NULL;
    assistant_message JSONB := NULL;
    memory_result JSONB := '{}'::jsonb;
    ctx JSONB := COALESCE(p_context, '{}'::jsonb);
    source_identity TEXT := NULLIF(ctx->>'source_identity', '');
BEGIN
    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'session_id is required';
    END IF;
    session_payload := get_or_create_chat_session(
        p_session_id,
        COALESCE(NULLIF(p_surface, ''), ctx->>'surface', 'chat'),
        NULLIF(ctx->>'external_id', ''),
        COALESCE(ctx->'session_metadata', '{}'::jsonb)
    );

    IF NULLIF(COALESCE(p_user_text, ''), '') IS NOT NULL THEN
        user_message := append_chat_message(
            p_session_id,
            'user',
            p_user_text,
            COALESCE(ctx->'user_metadata', '{}'::jsonb),
            NULLIF(ctx->>'user_source_message_id', ''),
            TRUE
        );
    END IF;

    IF NULLIF(COALESCE(p_assistant_text, ''), '') IS NOT NULL THEN
        assistant_message := append_chat_message(
            p_session_id,
            'assistant',
            p_assistant_text,
            COALESCE(ctx->'assistant_metadata', '{}'::jsonb),
            NULLIF(ctx->>'assistant_source_message_id', ''),
            TRUE
        );
    END IF;

    IF COALESCE(p_user_text, '') <> '' OR COALESCE(p_assistant_text, '') <> '' THEN
        BEGIN
            memory_result := record_chat_turn_memory(
                p_user_text,
                p_assistant_text,
                p_session_id::text,
                source_identity,
                ctx
            );
        EXCEPTION WHEN OTHERS THEN
            memory_result := jsonb_build_object(
                'status', 'failed',
                'error', SQLERRM,
                'short_term_history_preserved', TRUE
            );
        END;
    END IF;

    RETURN jsonb_build_object(
        'session', session_payload,
        'user_message', user_message,
        'assistant_message', assistant_message,
        'memory', memory_result,
        'history', hydrate_chat_session(p_session_id)
    );
END;
$$;

CREATE OR REPLACE FUNCTION clear_chat_session_context(
    p_session_id UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    affected INT;
BEGIN
    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'session_id is required';
    END IF;

    UPDATE chat_messages
    SET visible_in_context = FALSE,
        metadata = metadata || jsonb_build_object(
            'cleared_from_context_at', CURRENT_TIMESTAMP,
            'clear_reason', COALESCE(NULLIF(p_reason, ''), 'user_request')
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE session_id = p_session_id
      AND visible_in_context;
    GET DIAGNOSTICS affected = ROW_COUNT;

    UPDATE chat_sessions
    SET cleared_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
        'session_id', p_session_id::text,
        'cleared_messages', affected,
        'long_term_memory_preserved', TRUE
    );
END;
$$;
