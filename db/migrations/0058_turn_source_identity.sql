-- Source-identity pushdown: a chat turn's identity string
-- (chat:<session>:<ordinal>:<digest>) is derived inside
-- record_chat_turn_memory from the DB's own unit count and content
-- digest; callers stop hand-assembling it in Python.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_chat_turn_memory(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id TEXT DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    started_at TIMESTAMPTZ := clock_timestamp();
    content TEXT;
    importance FLOAT;
    source_attribution JSONB;
    metadata JSONB;
    session_uuid UUID;
    v_source_identity TEXT;
    raw JSONB;
    raw_unit_id UUID;
    promoted_memory_id UUID;
    promoted BOOLEAN := FALSE;
    duration_ms FLOAT;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'empty_turn');
    END IF;

    session_uuid := _db_brain_try_uuid(p_session_id);
    -- Conversation turns in a session self-identify: chat:<session>:<turn
    -- ordinal>:<content digest>. The ordinal comes from the units already
    -- stored for the session — the DB's own count, not a caller-supplied
    -- history length.
    v_source_identity := NULLIF(trim(COALESCE(p_source_identity, '')), '');
    IF v_source_identity IS NULL AND NULLIF(p_session_id, '') IS NOT NULL THEN
        v_source_identity := 'chat:' || p_session_id || ':'
            || COALESCE((SELECT COUNT(*) FROM subconscious_units u WHERE u.session_id = session_uuid), 0)::text
            || ':'
            || left(encode(sha256(convert_to(
                   COALESCE(p_user_text, '') || chr(30) || COALESCE(p_assistant_text, ''), 'UTF8')), 'hex'), 16);
    END IF;

    content := format_recmem_turn(
        COALESCE(p_user_text, ''),
        COALESCE(p_assistant_text, ''),
        NULLIF(p_context->>'user_label', '')
    );
    importance := COALESCE(
        NULLIF(p_context->>'importance', '')::FLOAT,
        estimate_conversation_importance(p_user_text, p_assistant_text)
    );
    metadata := COALESCE(p_context->'metadata', '{"type":"conversation"}'::jsonb);
    source_attribution := COALESCE(
        p_context->'source_attribution',
        jsonb_build_object(
            'kind', COALESCE(p_context #>> '{source_attribution_kind}', 'conversation'),
            'ref', COALESCE(v_source_identity, 'conversation_turn'),
            'label', COALESCE(p_context #>> '{source_attribution_label}', 'conversation turn'),
            'observed_at', CURRENT_TIMESTAMP,
            -- Conversational testimony enters at a config-owned default (#61):
            -- 0.95 belongs to verified provenance, not to whoever dialed in.
            'trust', COALESCE(
                NULLIF(p_context #>> '{trust}', '')::FLOAT,
                get_config_float('memory.conversation_turn_trust'),
                0.8)
        )
    );
    raw := recmem_ingest_turn(
        p_user_text,
        p_assistant_text,
        session_uuid,
        v_source_identity,
        CURRENT_TIMESTAMP,
        importance,
        source_attribution,
        metadata,
        NULLIF(p_context->>'user_label', '')
    );
    raw_unit_id := _db_brain_try_uuid(raw->>'unit_id');

    -- Direct promotion is a safety valve for truly exceptional single turns
    -- (#73): scene consolidation at session boundaries is the normal path to
    -- episodic memory, so the bar sits above the signal-phrase bump (0.8).
    IF importance >= COALESCE(get_config_float('memory.direct_promotion_min_importance'), 0.95) THEN
        promoted_memory_id := create_episodic_memory(
            content,
            NULL,
            jsonb_build_object('type', 'conversation', 'recmem', jsonb_build_object('direct_promoted', true)),
            NULL,
            0.0,
            CURRENT_TIMESTAMP,
            importance,
            source_attribution,
            0.95
        );
        promoted := TRUE;
        IF raw_unit_id IS NOT NULL THEN
            PERFORM link_memory_to_source_unit(promoted_memory_id, raw_unit_id, 'direct_promotion');
        END IF;
    END IF;

    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000.0;

    RETURN jsonb_build_object(
        'raw', COALESCE(raw, '{}'::jsonb),
        'raw_unit_id', raw_unit_id,
        'direct_promoted', promoted,
        'promoted_memory_id', promoted_memory_id,
        'importance', importance,
        'duration_ms', duration_ms
    );
END;
$$;
