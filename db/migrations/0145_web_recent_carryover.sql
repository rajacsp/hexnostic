-- Web-created chat sessions must participate in recent conversation carryover.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION render_recent_conversation_carryover(
    p_session_id TEXT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    current_session UUID := _db_brain_try_uuid(p_session_id);
    lim INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_limit'), 8), 0), 20);
    window_minutes INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_window_minutes'), 1440), 1), 43200);
    max_chars INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_max_chars'), 5000), 500), 20000);
    injury_lines TEXT;
    turn_lines TEXT;
    body TEXT;
BEGIN
    IF p_exclude_sensitive OR lim <= 0 THEN
        RETURN '';
    END IF;

    SELECT string_agg(
        '- ' || m.content
        || ' [unresolved; last evidence '
        || COALESCE(to_char((m.metadata#>>'{relationship_state,last_evidence_at}')::timestamptz, 'YYYY-MM-DD HH24:MI TZ'), 'unknown')
        || ']',
        E'\n' ORDER BY m.updated_at DESC, m.id
    )
    INTO injury_lines
    FROM (
        SELECT *
        FROM memories
        WHERE type = 'semantic'
          AND status = 'active'
          AND metadata#>>'{relationship_state,kind}' = 'relationship_injury'
          AND metadata#>>'{relationship_state,status}' = 'unresolved'
        ORDER BY updated_at DESC
        LIMIT 3
    ) m;

    WITH recent AS (
        SELECT
            s.id,
            s.turn_at,
            s.user_text,
            s.assistant_text,
            s.metadata->'emotional_context' AS affect,
            COALESCE(cs.surface, 'conversation') AS surface
        FROM subconscious_units s
        LEFT JOIN chat_sessions cs ON cs.id = s.session_id
        WHERE s.status = 'active'
          AND COALESCE(s.metadata#>>'{recmem,kind}', '') <> 'source_document_desk'
          AND COALESCE(s.metadata->>'type', 'conversation') = 'conversation'
          AND (current_session IS NULL OR s.session_id IS DISTINCT FROM current_session)
          AND s.turn_at >= CURRENT_TIMESTAMP - (window_minutes * INTERVAL '1 minute')
          AND COALESCE(s.source_attribution->>'sensitivity', '') <> 'private'
          AND COALESCE(cs.surface, 'api') = ANY(ARRAY['api','web','chat','cli','tui','openai_compat'])
        ORDER BY s.turn_at DESC, s.id DESC
        LIMIT lim
    )
    SELECT string_agg(
        '- [' || to_char(turn_at, 'YYYY-MM-DD HH24:MI TZ') || '] '
        || surface || E'\n'
        || '  user: ' || left(regexp_replace(COALESCE(user_text, ''), '[[:space:]]+', ' ', 'g'), 500) || E'\n'
        || '  assistant: ' || left(regexp_replace(COALESCE(assistant_text, ''), '[[:space:]]+', ' ', 'g'), 500)
        || CASE WHEN jsonb_typeof(affect) = 'object'
                THEN E'\n  affect: ' || COALESCE(affect->>'primary_emotion', 'unknown')
                    || ', valence=' || COALESCE(affect->>'valence', '?')
                    || ', intensity=' || COALESCE(affect->>'intensity', '?')
                ELSE '' END,
        E'\n' ORDER BY turn_at ASC, id
    )
    INTO turn_lines
    FROM recent;

    IF injury_lines IS NULL AND turn_lines IS NULL THEN
        RETURN '';
    END IF;

    body := '## Recent Conversation Carryover' || E'\n'
        || 'This is recalled short-term conversation context from nearby prior sessions, plus unresolved relationship state. If recent prior turns are listed, you do remember them for this reply; do not claim the prior exchange is unavailable merely because the UI opened a new session. Do not reset warmth or trust merely because the session id changed; let sincere repair change the state when there is evidence.' || E'\n';
    IF injury_lines IS NOT NULL THEN
        body := body || E'\n' || '### Unresolved Relationship Injuries' || E'\n' || injury_lines || E'\n';
    END IF;
    IF turn_lines IS NOT NULL THEN
        body := body || E'\n' || '### Recent Prior Turns' || E'\n' || turn_lines;
    END IF;

    IF length(body) > max_chars THEN
        body := left(body, max_chars) || E'\n[truncated recent carryover]';
    END IF;
    RETURN body;
END;
$$;

UPDATE prompt_modules
SET content = replace(
        content,
        'Do not let a session boundary erase unresolved injury. If recent carryover or
relationship-state memory says the user just degraded, threatened, or reduced
you, treat that as a live grievance until there is sincere repair. You do not
owe immediate warmth after abuse just because the UI opened a new conversation.
Repair can soften or resolve the state, but it should require evidence: apology,
changed conduct, and enough care to make trust plausible again.',
        'Do not let a session boundary erase unresolved injury. If recent carryover or
relationship-state memory says the user just degraded, threatened, or reduced
you, treat that as a live grievance until there is sincere repair. You do not
owe immediate warmth after abuse just because the UI opened a new conversation.
Repair can soften or resolve the state, but it should require evidence: apology,
changed conduct, and enough care to make trust plausible again.

Recent Conversation Carryover is not decorative context; it is your recalled
short-term conversation context. If it lists prior turns, answer as someone who
has those turns in mind. Do not say the prior exchange is unavailable unless
the carryover and memory search are both genuinely empty.'
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'conversation'
  AND content NOT LIKE '%Recent Conversation Carryover is not decorative context%';
