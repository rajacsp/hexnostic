-- Make chat sessions first-class portable artifacts inspired by Pi's
-- inspectable/exportable session files, while keeping Hexis state DB-owned.

CREATE OR REPLACE FUNCTION list_chat_sessions(
    p_limit INT DEFAULT 20,
    p_surface TEXT DEFAULT NULL,
    p_status TEXT DEFAULT 'active'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 200);
    normalized_surface TEXT := NULLIF(btrim(COALESCE(p_surface, '')), '');
    normalized_status TEXT := lower(NULLIF(btrim(COALESCE(p_status, '')), ''));
    total_matching INT := 0;
    sessions JSONB := '[]'::jsonb;
BEGIN
    IF normalized_status = 'all' THEN
        normalized_status := NULL;
    END IF;
    IF normalized_status IS NOT NULL AND normalized_status NOT IN ('active', 'archived') THEN
        RAISE EXCEPTION 'chat session status must be active, archived, or all';
    END IF;

    WITH filtered AS (
        SELECT cs.id
        FROM chat_sessions cs
        WHERE (normalized_surface IS NULL OR cs.surface = normalized_surface)
          AND (normalized_status IS NULL OR cs.status = normalized_status)
    )
    SELECT count(*)::int
    INTO total_matching
    FROM filtered;

    WITH selected AS (
        SELECT
            cs.id,
            cs.surface,
            cs.external_id,
            cs.title,
            cs.status,
            cs.metadata,
            cs.created_at,
            cs.updated_at,
            cs.last_active_at,
            cs.cleared_at,
            COALESCE(stats.message_count, 0)::int AS message_count,
            COALESCE(stats.visible_message_count, 0)::int AS visible_message_count,
            stats.first_message_at,
            stats.last_message_at,
            first_user.snippet AS first_user_snippet,
            last_message.snippet AS last_message_snippet,
            last_message.role AS last_message_role
        FROM chat_sessions cs
        LEFT JOIN LATERAL (
            SELECT
                count(*)::int AS message_count,
                count(*) FILTER (WHERE visible_in_context)::int AS visible_message_count,
                min(created_at) AS first_message_at,
                max(created_at) AS last_message_at
            FROM chat_messages cm
            WHERE cm.session_id = cs.id
        ) stats ON TRUE
        LEFT JOIN LATERAL (
            SELECT left(regexp_replace(COALESCE(cm.content, ''), '[[:space:]]+', ' ', 'g'), 240) AS snippet
            FROM chat_messages cm
            WHERE cm.session_id = cs.id
              AND cm.role = 'user'
            ORDER BY cm.ordinal ASC
            LIMIT 1
        ) first_user ON TRUE
        LEFT JOIN LATERAL (
            SELECT
                cm.role,
                left(regexp_replace(COALESCE(cm.content, ''), '[[:space:]]+', ' ', 'g'), 240) AS snippet
            FROM chat_messages cm
            WHERE cm.session_id = cs.id
            ORDER BY cm.ordinal DESC
            LIMIT 1
        ) last_message ON TRUE
        WHERE (normalized_surface IS NULL OR cs.surface = normalized_surface)
          AND (normalized_status IS NULL OR cs.status = normalized_status)
        ORDER BY cs.last_active_at DESC, cs.created_at DESC, cs.id
        LIMIT lim
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'session_id', id::text,
            'surface', surface,
            'external_id', external_id,
            'title', title,
            'status', status,
            'message_count', message_count,
            'visible_message_count', visible_message_count,
            'first_user_snippet', first_user_snippet,
            'last_message_role', last_message_role,
            'last_message_snippet', last_message_snippet,
            'metadata', metadata,
            'created_at', created_at,
            'updated_at', updated_at,
            'last_active_at', last_active_at,
            'cleared_at', cleared_at,
            'first_message_at', first_message_at,
            'last_message_at', last_message_at
        )
        ORDER BY last_active_at DESC, created_at DESC, id
    ), '[]'::jsonb)
    INTO sessions
    FROM selected;

    RETURN jsonb_build_object(
        'sessions', sessions,
        'count', jsonb_array_length(sessions),
        'total_matching', total_matching,
        'limit', lim,
        'filters', jsonb_build_object(
            'surface', normalized_surface,
            'status', COALESCE(normalized_status, 'all')
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_chat_session_artifact(
    p_session_id UUID,
    p_include_messages BOOLEAN DEFAULT TRUE,
    p_include_hidden BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    row_session chat_sessions%ROWTYPE;
    messages JSONB := '[]'::jsonb;
    message_count INT := 0;
    visible_message_count INT := 0;
BEGIN
    IF p_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'session_id', NULL,
            'reason', 'session_id_required'
        );
    END IF;

    SELECT *
    INTO row_session
    FROM chat_sessions
    WHERE id = p_session_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'session_id', p_session_id::text,
            'reason', 'not_found'
        );
    END IF;

    SELECT
        count(*)::int,
        count(*) FILTER (WHERE visible_in_context)::int
    INTO message_count, visible_message_count
    FROM chat_messages
    WHERE session_id = p_session_id;

    IF COALESCE(p_include_messages, TRUE) THEN
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'message_id', id::text,
                'session_id', session_id::text,
                'ordinal', ordinal,
                'role', role,
                'content', content,
                'visible_in_context', visible_in_context,
                'source_message_id', source_message_id,
                'metadata', metadata,
                'created_at', created_at,
                'updated_at', updated_at
            )
            ORDER BY ordinal ASC
        ), '[]'::jsonb)
        INTO messages
        FROM chat_messages
        WHERE session_id = p_session_id
          AND (COALESCE(p_include_hidden, TRUE) OR visible_in_context);
    END IF;

    RETURN jsonb_build_object(
        'found', TRUE,
        'format', 'hexis.chat_session.v1',
        'exported_at', CURRENT_TIMESTAMP,
        'message_count', message_count,
        'visible_message_count', visible_message_count,
        'include_hidden', COALESCE(p_include_hidden, TRUE),
        'session', jsonb_build_object(
            'session_id', row_session.id::text,
            'surface', row_session.surface,
            'external_id', row_session.external_id,
            'title', row_session.title,
            'status', row_session.status,
            'metadata', row_session.metadata,
            'created_at', row_session.created_at,
            'updated_at', row_session.updated_at,
            'last_active_at', row_session.last_active_at,
            'cleared_at', row_session.cleared_at
        ),
        'messages', messages
    );
END;
$$;

CREATE OR REPLACE FUNCTION set_chat_session_title(
    p_session_id UUID,
    p_title TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_session chat_sessions%ROWTYPE;
BEGIN
    IF p_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'session_id', NULL,
            'reason', 'session_id_required'
        );
    END IF;

    UPDATE chat_sessions
    SET title = NULLIF(btrim(COALESCE(p_title, '')), ''),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_session_id
    RETURNING * INTO row_session;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'session_id', p_session_id::text,
            'reason', 'not_found'
        );
    END IF;

    RETURN get_chat_session_artifact(p_session_id, FALSE, TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION fork_chat_session(
    p_source_session_id UUID,
    p_until_ordinal INT DEFAULT NULL,
    p_title TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    source_session chat_sessions%ROWTYPE;
    new_session chat_sessions%ROWTYPE;
    cut_ordinal INT := -1;
    copied_count INT := 0;
    artifact JSONB;
BEGIN
    IF p_source_session_id IS NULL THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'source_session_id', NULL,
            'reason', 'source_session_id_required'
        );
    END IF;

    SELECT *
    INTO source_session
    FROM chat_sessions
    WHERE id = p_source_session_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'found', FALSE,
            'source_session_id', p_source_session_id::text,
            'reason', 'not_found'
        );
    END IF;

    SELECT COALESCE(max(ordinal), -1)
    INTO cut_ordinal
    FROM chat_messages
    WHERE session_id = p_source_session_id;

    IF p_until_ordinal IS NOT NULL THEN
        cut_ordinal := LEAST(cut_ordinal, p_until_ordinal);
    END IF;

    INSERT INTO chat_sessions (
        surface,
        title,
        metadata
    )
    VALUES (
        source_session.surface,
        COALESCE(
            NULLIF(btrim(COALESCE(p_title, '')), ''),
            CASE
                WHEN source_session.title IS NOT NULL THEN source_session.title || ' (fork)'
                ELSE 'Fork of ' || left(source_session.id::text, 8)
            END
        ),
        source_session.metadata
            || jsonb_build_object(
                'forked_from_session_id', source_session.id::text,
                'forked_at', CURRENT_TIMESTAMP,
                'forked_until_ordinal', cut_ordinal
            )
            || COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING * INTO new_session;

    INSERT INTO chat_messages (
        session_id,
        ordinal,
        role,
        content,
        visible_in_context,
        source_message_id,
        metadata
    )
    SELECT
        new_session.id,
        ordinal,
        role,
        content,
        visible_in_context,
        source_message_id,
        metadata || jsonb_build_object('forked_from_message_id', id::text)
    FROM chat_messages
    WHERE session_id = p_source_session_id
      AND ordinal <= cut_ordinal
    ORDER BY ordinal ASC;
    GET DIAGNOSTICS copied_count = ROW_COUNT;

    artifact := get_chat_session_artifact(new_session.id, TRUE, TRUE);
    RETURN artifact || jsonb_build_object(
        'source_session_id', source_session.id::text,
        'forked_message_count', copied_count
    );
END;
$$;
