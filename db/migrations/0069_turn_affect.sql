-- Affect is stamped at turn time (#81): record_chat_turn_memory folds the
-- turn's appraisal (or a current-state snapshot) into the unit's metadata
-- as emotional_context, and apply_conscious_extraction copies that onto
-- created memories, overriding the creation trigger's sweep-time stamp.
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
    affect_ctx JSONB;
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

    -- Affect is stamped at turn time (#81): prefer this turn's appraisal
    -- (passed by the caller), else snapshot the current affective state —
    -- extraction later copies this onto created memories so they carry the
    -- moment's feeling, never the sweep-time mood.
    IF jsonb_typeof(p_context->'emotional_state') = 'object' THEN
        affect_ctx := jsonb_build_object(
            'valence', LEAST(1.0, GREATEST(-1.0, COALESCE(NULLIF(p_context#>>'{emotional_state,valence}', '')::float, 0.0))),
            'arousal', LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_context#>>'{emotional_state,arousal}', '')::float, 0.5))),
            'intensity', LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_context#>>'{emotional_state,intensity}', '')::float, 0.5))),
            'primary_emotion', COALESCE(NULLIF(p_context#>>'{emotional_state,primary_emotion}', ''), 'neutral'),
            'source', 'appraisal');
    ELSE
        affect_ctx := (SELECT jsonb_build_object(
            'valence', COALESCE(NULLIF(s->>'valence', '')::float, 0.0),
            'arousal', COALESCE(NULLIF(s->>'arousal', '')::float, 0.5),
            'intensity', COALESCE(NULLIF(s->>'intensity', '')::float, 0.5),
            'primary_emotion', COALESCE(NULLIF(s->>'primary_emotion', ''), 'neutral'),
            'source', 'state_snapshot')
            FROM get_current_affective_state() s(s));
    END IF;
    metadata := metadata || jsonb_build_object('emotional_context', affect_ctx);
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

CREATE OR REPLACE FUNCTION apply_conscious_extraction(
    p_unit_ids UUID[],
    p_extractions JSONB
) RETURNS JSONB AS $$
DECLARE
    min_conf FLOAT := COALESCE(get_config_float('extraction.min_confidence'), 0.55);
    max_facts INT := COALESCE(get_config_int('extraction.max_facts_per_batch'), 5);
    facts JSONB;
    plan JSONB;
    fact JSONB;
    routed JSONB;
    idx INT := 0;
    unit subconscious_units%ROWTYPE;
    unit_id UUID;
    fact_kind TEXT;
    fact_conf FLOAT;
    source JSONB;
    new_id UUID;
    created INT := 0;
    corroborated INT := 0;
    dropped INT := 0;
BEGIN
    facts := CASE WHEN jsonb_typeof(p_extractions) = 'array' THEN p_extractions ELSE '[]'::jsonb END;
    IF jsonb_array_length(facts) > max_facts THEN
        facts := (SELECT jsonb_agg(f) FROM (
            SELECT f FROM jsonb_array_elements(facts) f LIMIT max_facts
        ) capped(f));
    END IF;

    plan := ingest_route_extractions(
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'content', f->>'content',
                    'confidence', COALESCE(NULLIF(f->>'confidence', '')::float, 0.5))), '[]'::jsonb)
         FROM jsonb_array_elements(facts) f),
        min_conf
    );

    FOR fact IN SELECT f FROM jsonb_array_elements(facts) f LOOP
        routed := NULL;
        SELECT p INTO routed FROM jsonb_array_elements(plan) p
        WHERE (p->>'index')::int = idx;
        idx := idx + 1;

        unit_id := _db_brain_try_uuid(fact->>'unit_id');
        IF unit_id IS NULL OR NOT (unit_id = ANY(p_unit_ids)) THEN
            unit_id := p_unit_ids[1];
        END IF;
        SELECT * INTO unit FROM subconscious_units WHERE id = unit_id;

        IF routed IS NULL THEN
            dropped := dropped + 1;  -- below the router's confidence floor
            CONTINUE;
        END IF;

        fact_kind := COALESCE(NULLIF(fact->>'kind', ''), 'user_testimony');
        fact_conf := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(fact->>'confidence', '')::float, 0.5)));
        source := jsonb_build_object(
            'kind', fact_kind,
            'ref', 'subconscious_unit:' || unit_id::text,
            'label', CASE WHEN fact_kind = 'self_observation'
                          THEN 'heartbeat self-observation'
                          ELSE 'conversation with ' || COALESCE(unit.source_identity, 'user') END,
            'author', unit.source_identity,
            'observed_at', unit.turn_at,
            'trust', 0.75
        );

        IF routed->>'decision' = 'duplicate' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM revise_memory_confidence(
                (routed->>'matched_memory_id')::uuid, source, 'supports', 'conscious_extraction');
            PERFORM link_memory_to_source_unit(
                (routed->>'matched_memory_id')::uuid, unit_id, 'corroboration');
            corroborated := corroborated + 1;
            CONTINUE;
        END IF;

        IF fact_kind = 'episode' THEN
            new_id := create_episodic_memory(
                fact->>'content',
                NULL,
                jsonb_build_object('type', 'conscious_extraction'),
                NULL,
                0.0,
                unit.turn_at,
                COALESCE(unit.importance, 0.5),
                source,
                NULL
            );
        ELSE
            -- Testimony/self-observation never starts above its source trust.
            new_id := create_semantic_memory(
                fact->>'content',
                LEAST(fact_conf, 0.75),
                ARRAY['conscious_extraction', COALESCE(NULLIF(fact->>'category', ''), fact_kind)],
                NULL,
                jsonb_build_array(source),
                COALESCE(unit.importance, 0.5),
                NULL,
                NULL
            );
        END IF;
        -- The memory carries the TURN's feeling, not the sweep-time mood
        -- (#81): the unit's turn-stamped affect overrides the creation
        -- trigger's current-state snapshot.
        IF jsonb_typeof(unit.metadata->'emotional_context') = 'object' THEN
            UPDATE memories
            SET metadata = metadata || jsonb_build_object(
                    'emotional_context', unit.metadata->'emotional_context',
                    'emotional_valence', COALESCE(NULLIF(unit.metadata#>>'{emotional_context,valence}', '')::float, 0.0))
            WHERE id = new_id;
        END IF;
        PERFORM link_memory_to_source_unit(new_id, unit_id, 'extraction');
        IF routed->>'decision' = 'related' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM discover_relationship(
                new_id, (routed->>'matched_memory_id')::uuid,
                'ASSOCIATED'::graph_edge_type, 0.6, 'conscious_extraction');
        END IF;
        created := created + 1;
    END LOOP;

    UPDATE subconscious_units
    SET extraction_status = 'extracted',
        extracted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(p_unit_ids);

    RETURN jsonb_build_object(
        'units', COALESCE(array_length(p_unit_ids, 1), 0),
        'created', created,
        'corroborated', corroborated,
        'dropped', dropped
    );
END;
$$ LANGUAGE plpgsql;
