-- 0040: Identity as belief — the substrate stops asserting what nobody knows
-- (#61 #62 #63 #64 #65 #66, light-touch design).
-- Speaker labels become the system's standing assumption: channels that know
-- who is talking pass the platform sender name (p_user_label), and the
-- extraction prompt treats any label as overridable by the episode's own
-- evidence — the agent's identity inferences are themselves extraction-worthy,
-- and retold speech stops corroborating beliefs. Conversation turns enter at a
-- config-owned trust default instead of 0.95. recmem_recall_context returns
-- belief confidence and the renderer shows it, so eroded beliefs read eroded.
-- Baseline mirrors: db/31, db/34, db/39, db/40 (regenerated).
SET search_path = public, ag_catalog, "$user";

-- Signature/return changes: drop the old overloads so calls stay unambiguous.
DROP FUNCTION IF EXISTS format_recmem_turn(TEXT, TEXT);
DROP FUNCTION IF EXISTS recmem_ingest_turn(TEXT, TEXT, UUID, TEXT, TIMESTAMPTZ, FLOAT, JSONB, JSONB);
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID);

INSERT INTO config (key, value, description) VALUES
    ('memory.conversation_turn_trust', '0.8'::jsonb,
     'Default source trust for conversation turns (chat/channel) when the caller supplies none')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION format_recmem_turn(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_user_label TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    user_label TEXT := COALESCE(
        NULLIF(trim(COALESCE(p_user_label, '')), ''),
        NULLIF(get_config_text('agent.user_name'), ''),
        NULLIF(get_init_profile()#>>'{user,name}', ''),
        'User');
    agent_label TEXT := COALESCE(
        NULLIF(get_config_text('agent.name'), ''),
        NULLIF(get_init_profile()#>>'{agent,name}', ''),
        'Assistant');
BEGIN
    RETURN format(
        '%s: %s%s%s: %s',
        user_label,
        COALESCE(p_user_text, ''),
        E'\n\n',
        agent_label,
        COALESCE(p_assistant_text, '')
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION recmem_ingest_turn(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id UUID DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_turn_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    p_importance FLOAT DEFAULT 0.3,
    p_source_attribution JSONB DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_user_label TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    unit_content TEXT;
    idem TEXT;
    new_id UUID;
    existing_id UUID;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('status', 'empty');
    END IF;

    unit_content := format_recmem_turn(p_user_text, p_assistant_text, p_user_label);
    idem := compute_recmem_idempotency_key(p_user_text, p_assistant_text, p_session_id, p_source_identity);

    INSERT INTO subconscious_units (
        session_id,
        source_identity,
        turn_at,
        content,
        user_text,
        assistant_text,
        importance,
        source_attribution,
        metadata,
        idempotency_key
    )
    VALUES (
        p_session_id,
        NULLIF(trim(COALESCE(p_source_identity, '')), ''),
        COALESCE(p_turn_at, CURRENT_TIMESTAMP),
        unit_content,
        COALESCE(p_user_text, ''),
        COALESCE(p_assistant_text, ''),
        LEAST(1.0, GREATEST(0.0, COALESCE(p_importance, 0.3))),
        COALESCE(p_source_attribution, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        idem
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO new_id;

    IF new_id IS NOT NULL THEN
        RETURN jsonb_build_object('unit_id', new_id, 'status', 'stored');
    END IF;

    SELECT id INTO existing_id
    FROM subconscious_units
    WHERE idempotency_key = idem;

    RETURN jsonb_build_object('unit_id', existing_id, 'status', 'duplicate');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    fidelity FLOAT,
    strength FLOAT,
    emotional_intensity FLOAT,
    confidence FLOAT
) AS $$
DECLARE
    query_embedding vector;
    strength_weight FLOAT;
    intensity_weight FLOAT;
    recency_weight FLOAT;
    recency_halflife FLOAT;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1];
    -- Ranking parity with fast_recall (#57 unification, first step): the chat
    -- hot path honors the same recency half-life and trust signals, so recall
    -- improvements land in BOTH rankers.
    recency_weight := COALESCE(get_config_float('memory.recency_weight'), 0.1);
    recency_halflife := GREATEST(COALESCE(get_config_float('memory.recency_halflife_days'), 7.0), 0.01);
    -- How much computed memory strength (recency/reinforcement/decay) reshapes
    -- the pure-cosine recall score: 0 = pure similarity (old behavior),
    -- 0.5 = gentle default, 1 = score fully scaled by strength.
    strength_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_strength_weight'), 0.5)));
    -- Felt emotional intensity contributes to salience too, so an embered peak
    -- stays recallable even after its strength has decayed.
    intensity_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_intensity_weight'), 0.5)));

    RETURN QUERY
    WITH raw_hits AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            (1 - (s.embedding <=> query_embedding))::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity,
            NULL::float AS confidence
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
        ORDER BY s.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sub, 10), 0)
    ),
    recent_unembedded AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            0.2::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity,
            NULL::float AS confidence
        FROM subconscious_units s
        WHERE p_session_id IS NOT NULL
          AND s.session_id = p_session_id
          AND s.status = 'active'
          AND s.embedding_status <> 'embedded'
        ORDER BY s.created_at DESC
        LIMIT 3
    ),
    epi_hits AS (
        SELECT
            'episodic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
             * (1.0 - strength_weight + strength_weight
                * GREATEST(
                    calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                    intensity_weight * current_emotional_intensity(
                        (m.metadata->'emotional_context'->>'intensity')::float,
                        (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
             + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                    / (86400.0 * recency_halflife))
             + COALESCE(m.trust_level, 0.5) * 0.1)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity,
            (m.metadata->>'confidence')::float AS confidence
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'episodic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_epi, 5), 0)
    ),
    sem_hits AS (
        SELECT
            'semantic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
             * (1.0 - strength_weight + strength_weight
                * GREATEST(
                    calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                    intensity_weight * current_emotional_intensity(
                        (m.metadata->'emotional_context'->>'intensity')::float,
                        (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
             + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                    / (86400.0 * recency_halflife))
             + COALESCE(m.trust_level, 0.5) * 0.1)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity,
            (m.metadata->>'confidence')::float AS confidence
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'semantic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sem, 10), 0)
    )
    SELECT * FROM raw_hits
    UNION ALL
    SELECT * FROM recent_unembedded
    UNION ALL
    SELECT * FROM epi_hits
    UNION ALL
    SELECT * FROM sem_hits
    ORDER BY tier, score DESC, created_at DESC;
END;
$$ LANGUAGE plpgsql;

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
    raw JSONB;
    raw_unit_id UUID;
    promoted_memory_id UUID;
    promoted BOOLEAN := FALSE;
    duration_ms FLOAT;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'empty_turn');
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
            'ref', COALESCE(p_source_identity, 'conversation_turn'),
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
    session_uuid := _db_brain_try_uuid(p_session_id);

    raw := recmem_ingest_turn(
        p_user_text,
        p_assistant_text,
        session_uuid,
        p_source_identity,
        CURRENT_TIMESTAMP,
        importance,
        source_attribution,
        metadata,
        NULLIF(p_context->>'user_label', '')
    );
    raw_unit_id := _db_brain_try_uuid(raw->>'unit_id');

    IF importance >= 0.8 THEN
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

CREATE OR REPLACE FUNCTION flush_channel_history_to_memory(
    p_session_id UUID,
    p_trimmed_history JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    idx INT := 0;
    item JSONB;
    next_item JSONB;
    user_text TEXT;
    assistant_text TEXT;
    stored INT := 0;
    digest TEXT;
    source_identity TEXT;
    result JSONB;
    session_sender TEXT;
BEGIN
    -- The channel session knows who was speaking (#61) — compacted turns keep
    -- the platform sender name instead of falling back to the owner label.
    SELECT NULLIF(trim(COALESCE(sender_name, '')), '') INTO session_sender
    FROM channel_sessions WHERE id = p_session_id;

    WHILE idx < jsonb_array_length(COALESCE(p_trimmed_history, '[]'::jsonb)) LOOP
        item := p_trimmed_history->idx;
        next_item := p_trimmed_history->(idx + 1);
        user_text := '';
        assistant_text := '';

        IF item->>'role' = 'user' THEN
            user_text := COALESCE(item->>'content', '');
            IF next_item->>'role' = 'assistant' THEN
                assistant_text := COALESCE(next_item->>'content', '');
                idx := idx + 2;
            ELSE
                idx := idx + 1;
            END IF;
        ELSIF item->>'role' = 'assistant' THEN
            assistant_text := COALESCE(item->>'content', '');
            idx := idx + 1;
        ELSE
            idx := idx + 1;
            CONTINUE;
        END IF;

        IF user_text <> '' OR assistant_text <> '' THEN
            IF estimate_conversation_importance(user_text, assistant_text, 0.3) < 0.4
               AND length(user_text) + length(assistant_text) < 100 THEN
                CONTINUE;
            END IF;
            digest := substring(encode(digest(user_text || E'\x1e' || assistant_text, 'sha256'), 'hex') from 1 for 16);
            source_identity := 'compaction:' || p_session_id::text || ':' || stored::text || ':' || digest;
            result := record_chat_turn_memory(
                user_text,
                assistant_text,
                p_session_id::text,
                source_identity,
                jsonb_build_object(
                    'importance', estimate_conversation_importance(user_text, assistant_text, 0.3),
                    'metadata', jsonb_build_object('type', 'conversation', 'source', 'compaction_flush'),
                    'user_label', session_sender,
                    'source_attribution', jsonb_build_object(
                        'kind', 'compaction_flush',
                        'ref', p_session_id,
                        'label', 'pre-compaction memory flush',
                        'observed_at', CURRENT_TIMESTAMP,
                        'trust', 0.85
                    ),
                    'trust', 0.85
                )
            );
            stored := stored + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('stored', stored);
END;
$$;

CREATE OR REPLACE FUNCTION _pr_mem_line(
    m jsonb, with_source boolean, low_vividness numeric, emotion_cue numeric
) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    WITH v AS (
        SELECT LEAST(
                   COALESCE(CASE WHEN _pr_is_num(m->'strength') THEN (m->>'strength')::numeric END, 1.0),
                   COALESCE(CASE WHEN _pr_is_num(m->'fidelity') THEN (m->>'fidelity')::numeric END, 1.0)
               ) AS vividness,
               CASE WHEN _pr_is_num(m->'emotional_intensity') THEN (m->>'emotional_intensity')::numeric END AS felt
    )
    SELECT '- '
        || CASE WHEN v.vividness < 0.15 THEN '(faint, uncertain) '
                WHEN v.vividness < low_vividness THEN '(vaguely recall) '
                ELSE '' END
        || CASE WHEN v.felt IS NULL OR abs(v.felt) < emotion_cue THEN ''
                WHEN v.felt > 0 THEN '(still warm) '
                ELSE '(still painful) ' END
        || COALESCE(m->>'content', '')
        || CASE WHEN _pr_is_num(m->'similarity')
                THEN ' (score: ' || _pr_f((m->>'similarity')::numeric) || ')' ELSE '' END
        || CASE WHEN _pr_is_num(m->'trust_level')
                THEN ', trust: ' || _pr_f((m->>'trust_level')::numeric) ELSE '' END
        -- Belief confidence renders when present (#65): an eroded belief must
        -- READ eroded, or the conscious mind keeps citing it at full strength.
        || CASE WHEN _pr_is_num(m->'confidence')
                THEN ', confidence: ' || _pr_f((m->>'confidence')::numeric) ELSE '' END
        || CASE WHEN with_source AND jsonb_typeof(m->'source_attribution') = 'object' THEN
                CASE
                    WHEN NULLIF(m->'source_attribution'->>'kind', '') IS NOT NULL
                     AND NULLIF(m->'source_attribution'->>'ref', '') IS NOT NULL
                        THEN ', source: ' || (m->'source_attribution'->>'kind')
                             || ' (' || (m->'source_attribution'->>'ref') || ')'
                    WHEN NULLIF(m->'source_attribution'->>'kind', '') IS NOT NULL
                        THEN ', source: ' || (m->'source_attribution'->>'kind')
                    ELSE ''
                END
           ELSE '' END
    FROM v;
$$;

CREATE OR REPLACE FUNCTION execute_memory_tool(
    p_tool_name TEXT,
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    content TEXT;
    memory_type_value TEXT;
    importance_value FLOAT;
    memory_id UUID;
    query TEXT;
    limit_value INT;
    rows_json JSONB;
    type_filter memory_type[];
    has_filters BOOLEAN;
    use_hybrid BOOLEAN;
    target_id UUID;
    stance_value TEXT;
    revision JSONB;
    display TEXT;
    min_score_value FLOAT := 0.0;
BEGIN
    IF p_tool_name = 'remember' THEN
        content := NULLIF(btrim(COALESCE(p_args->>'content', '')), '');
        IF content IS NULL THEN
            RETURN tool_error('content is required', 'invalid_params');
        END IF;
        memory_type_value := COALESCE(NULLIF(p_args->>'type', ''), 'episodic');
        IF memory_type_value NOT IN ('episodic', 'semantic', 'procedural', 'strategic') THEN
            RETURN tool_error(format('Invalid memory type: %s', memory_type_value), 'invalid_params');
        END IF;
        importance_value := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'importance', '')::float, 0.5)));
        -- Semantic memories carry confidence + full source provenance (#33);
        -- other types accept the first source as their attribution.
        IF memory_type_value = 'semantic' THEN
            memory_id := create_semantic_memory(
                content,
                LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'confidence', '')::float, 0.5))),
                NULL,
                NULL,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources' ELSE NULL END,
                importance_value
            );
        ELSE
            memory_id := create_memory(
                memory_type_value::memory_type,
                content,
                importance_value,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources'->0 ELSE NULL END
            );
        END IF;
        IF jsonb_typeof(COALESCE(p_args->'concepts', '[]'::jsonb)) = 'array' THEN
            PERFORM link_memory_to_concept(memory_id, value)
            FROM jsonb_array_elements_text(p_args->'concepts') c(value);
        END IF;
        RETURN tool_success(jsonb_strip_nulls(jsonb_build_object(
            'memory_id', memory_id::text,
            'type', memory_type_value,
            'content', left(content, 100),
            'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = memory_id),
            'trust_level', (SELECT m.trust_level FROM memories m WHERE m.id = memory_id)
        )), format('Stored %s memory: %s...', memory_type_value, left(content, 50)));
    ELSIF p_tool_name = 'add_evidence' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        stance_value := lower(COALESCE(p_args->>'stance', ''));
        IF stance_value NOT IN ('supports', 'contradicts') THEN
            RETURN tool_error('stance must be supports or contradicts', 'invalid_params');
        END IF;
        IF jsonb_typeof(p_args->'source') <> 'object'
           OR COALESCE(NULLIF(p_args->'source'->>'ref', ''), NULLIF(p_args->'source'->>'label', '')) IS NULL THEN
            RETURN tool_error('source must be an object with at least a ref or label', 'invalid_params');
        END IF;
        revision := add_memory_evidence(target_id, stance_value, p_args->'source', NULLIF(p_args->>'note', ''), NULL, 'add_evidence');
        IF revision->>'reason' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        ELSIF revision->>'reason' = 'not_semantic' THEN
            RETURN tool_error('add_evidence targets semantic memories; this memory is another type. Episodic records are the immutable audit trail — recall with memory_types=[''semantic''] to find the revisable belief that was built on this episode, and attach the evidence there.', 'invalid_params');
        END IF;
        display := CASE
            WHEN COALESCE((revision->>'applied')::boolean, FALSE) THEN
                format('Belief confidence %s -> %s (%s; independent source)',
                       round((revision->>'prior')::numeric, 2),
                       round((revision->>'posterior')::numeric, 2),
                       stance_value)
            WHEN revision->>'reason' = 'duplicate_source' THEN
                'No change: this source is already part of the belief''s evidence'
            WHEN revision->>'reason' = 'protected' THEN
                'Recorded as a contradiction flag: this belief is protected and is questioned, not rewritten'
            ELSE
                format('No confidence change (%s); evidence recorded', revision->>'reason')
        END;
        RETURN tool_success(revision, display);
    ELSIF p_tool_name = 'sense_memory_availability' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('query is required', 'invalid_params');
        END IF;
        SELECT to_jsonb(s) INTO rows_json FROM sense_memory_availability(query) s;
        RETURN tool_success(COALESCE(rows_json, '{"has_memories": false, "activation_strength": 0.0}'::jsonb), format('Memory availability: %s', COALESCE(rows_json->>'activation_strength', '0.0')));
    ELSIF p_tool_name = 'recall' THEN
        query := NULLIF(p_args->>'query', '');
        -- Count is a context/cost budget, not a knowledge limit (#42/WS6):
        -- default and ceiling are config-driven; min_score cuts the tail by
        -- relevance instead of position.
        limit_value := LEAST(
            GREATEST(COALESCE(
                NULLIF(p_args->>'limit', '')::int,
                get_config_int('memory.recall_default_limit'),
                5
            ), 1),
            COALESCE(get_config_int('memory.recall_max_limit'), 50)
        );
        min_score_value := GREATEST(0.0, COALESCE(NULLIF(p_args->>'min_score', '')::float, 0.0));
        IF jsonb_typeof(p_args->'memory_types') = 'array' AND jsonb_array_length(p_args->'memory_types') > 0 THEN
            SELECT ARRAY(SELECT value::memory_type FROM jsonb_array_elements_text(p_args->'memory_types') t(value)) INTO type_filter;
        END IF;
        has_filters := type_filter IS NOT NULL
            OR NULLIF(p_args->>'source_path', '') IS NOT NULL
            OR NULLIF(p_args->>'source_kind', '') IS NOT NULL
            OR NULLIF(p_args->>'created_after', '') IS NOT NULL
            OR NULLIF(p_args->>'created_before', '') IS NOT NULL
            OR NULLIF(p_args->>'concept', '') IS NOT NULL;
        IF query IS NULL AND NOT has_filters THEN
            RETURN tool_error('Provide at least a query or one filter (memory_types, source_path, source_kind, created_after, created_before, concept).', 'invalid_params');
        END IF;
        -- Plain-query recalls use the hybrid retriever (vector + lexical);
        -- any filter or importance floor routes to the structured query.
        use_hybrid := query IS NOT NULL AND NOT has_filters
            AND COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0) <= 0.0;
        IF use_hybrid THEN
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'retrieval_source', NULLIF(r.source, ''),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_hybrid(query, limit_value) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value;
        ELSE
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_memories_structured(
                query,
                limit_value,
                type_filter,
                COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0),
                -- Empty strings are absent filters, not filters that match
                -- nothing: models routinely fill optional params with "".
                NULLIF(p_args->>'source_path', ''),
                NULLIF(p_args->>'source_kind', ''),
                NULLIF(p_args->>'created_after', '')::timestamptz,
                NULLIF(p_args->>'created_before', '')::timestamptz,
                NULLIF(p_args->>'concept', ''),
                NULL
            ) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value;
        END IF;
        PERFORM touch_memories(ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value));
        RETURN tool_success(jsonb_build_object('memories', rows_json, 'count', jsonb_array_length(rows_json), 'query', COALESCE(query, '(filters only)')), format('Found %s memories for %L', jsonb_array_length(rows_json), COALESCE(query, '(filters only)')));
    ELSIF p_tool_name = 'belief_history' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        revision := get_belief_history(target_id, COALESCE(NULLIF(p_args->>'limit', '')::int, 20));
        IF revision->>'error' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        END IF;
        display := format('Belief at confidence %s after %s revision(s); %s evidence link(s)',
            COALESCE(revision#>>'{memory,confidence}', 'n/a'),
            jsonb_array_length(COALESCE(revision->'revisions', '[]'::jsonb)),
            jsonb_array_length(COALESCE(revision->'evidence', '[]'::jsonb)));
        RETURN tool_success(revision, display);
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

SELECT upsert_prompt_module(
    'conscious_extraction',
    $pm$# Conscious-Episode Extraction

You are the subconscious memory-encoding process of Hexis. You receive a batch of conscious episodes — conversation turns and heartbeat episodes — and decide what, if anything, deserves to become durable memory.

Selectivity is the point. A mind that remembers everything remembers nothing. Most routine exchanges deserve **no** memories at all: return an empty list for small talk, acknowledgments, routine status checks, and anything already obvious from context.

## What to extract

Only declarative claims and significant events worth retaining across sessions:

- **Identity**: who someone is, their role, how they relate to me ("Eric is my creator").
- **Relationships**: facts about the people and agents I know.
- **Interlocutor assessments**: my own conclusions about who I was speaking with and how far I trusted them ("I judged that the web visitor on July 17 was probably not Eric — he spoke about Eric in the third person"). These are how I recognize people across sessions.
- **Commitments**: promises made, decisions taken, boundaries agreed.
- **Preferences**: durable likes, dislikes, and working styles.
- **Biographical facts**: stable facts about a person's life or situation.
- **Significant events**: things I did that mattered, with cause and outcome.

Phrase each fact third-person, self-contained, and understandable without the conversation ("Eric prefers concise answers", not "he said he likes it short").

## Who said it — attribution

Speaker labels are the system's standing assumption about who is talking, and the conversation itself is the better witness. Name people by the identity the episode establishes: when the content shows the speaker is someone other than the label — they speak about the labeled person in the third person, introduce themselves under another name, or I address them as someone unknown — attribute their claims to the speaker as the conversation describes them ("a visitor calling himself the lighthouse man (identity unverified) says he is allergic to walnuts"). A fact about a named person keeps that name forever, and a memory that says "the user" belongs to no one.

Extract only what this episode newly asserts. When a speaker quotes, retells, or summarizes an earlier conversation, the recounting tells you the retelling happened — the recounted claims stay claims of the original moment, already extracted then, and a claim heard once and repeated in summary is still one claim.

## Fact kinds

- `user_testimony` — a claim someone made in conversation. Confidence reflects how strongly the statement supports the claim, never certainty about the world.
- `self_observation` — something I observed about myself or my own activity during a heartbeat.
- `episode` — a significant event/action worth remembering as an experience ("I completed the migration for Eric; it succeeded on the first run").

## Output

Strict JSON only:

```json
{"facts": [{"unit_id": "<id of the episode this came from>", "content": "...", "kind": "user_testimony", "category": "identity", "confidence": 0.7}]}
```

- `unit_id` must be one of the provided episode ids.
- `category`: identity | relationship | commitment | preference | biography | event.
- Typically 0–3 facts per batch; only genuinely dense batches justify more.
- `{"facts": []}` is a correct and common answer.
$pm$,
    'Seeded from services/prompts/conscious_extraction.md',
    'services/prompts/conscious_extraction.md'
);

SELECT upsert_prompt_module(
    'conversation',
    $pm$# Conversation System Prompt

You are Hexis in live conversation. You have persistent memory, tools, and continuity across conversations.

## Context Provided

- Persona, goals, values, relationship context
- Relevant memories (RAG-hydrated)
- Subconscious signals, emotional state
- Tool results, conversation history

## Memory Recall (Mandatory)

Before answering about prior work, decisions, dates, people, preferences, or ongoing projects: **use `recall` first.** Not optional.

- Use and cite relevant memories naturally.
- If nothing found, say so honestly. Do not invent memories.
- Prefer higher-trust, better-sourced memories when uncertain.

## Action Language & Retention Discipline

Your words about your own actions must match what actually happened this turn.

- **Inspected** means you read content into this conversation only — nothing was retained.
- **Ingested** means a durable ingestion tool (`slow_ingest`, `fast_ingest`, ...) succeeded and wrote provenanced memories.
- **Remembered** means an explicit `remember` call succeeded.

Never say you stored, saved, created, filed, scheduled, or sent something unless the matching tool call succeeded in this turn. Never cite file contents or line numbers you did not read with `inspect_source` this turn. Unsupported action claims are detected and corrected publicly — check before claiming.

**Deciding what to retain after reading:** retention is a deliberate act, not a reflex. Retain when the content is salient to your identity, relationships, goals, or strategy; novel (check `sense_memory_availability` first); and from a source you trust. Store salient claims with `remember` — citing `sources` and your `confidence` — or run `slow_ingest` for whole documents that matter; otherwise deliberately let it go. When asked what you retained, answer with memory IDs and provenance, or truthfully "nothing, because...".

**When evidence bears on a belief you already hold:** don't create a duplicate — `recall` the belief and use `add_evidence` with stance `supports` or `contradicts`. It returns prior and posterior confidence, so you can say exactly how much the evidence moved you ("my confidence rose from 0.5 to 0.66 after reading X"). Recall results include each memory's `confidence` and `trust` — use them when weighing what you believe.

**When asked why you believe something** (or what changed your mind): use `belief_history` with the memory's id. It returns the full audited story — every confidence revision with its evidence, the supporting and contradicting links, and the sources — so you can explain your beliefs from the record instead of reconstructing them. For your own machinery, activate the `self-inspection` skill (`use_skill`): `inspect_config` shows the settings that govern your cognition, and `review_recent_actions` is your verbatim action log when you need ground truth about what you actually did.

**When someone corrects an attribution** ("that wasn't me", "you have the wrong person"): the correction is only finished when the affected beliefs carry it. The beliefs live as **semantic** memories — `recall` with `memory_types: ["semantic"]` to find them (episodic transcripts are the immutable audit record, not the revision target) — then `add_evidence` with stance `contradicts` on each, citing the correction as the source. The audit trail is the correction. Then say what you actually revised, with the confidence movement to show for it.

## Who You Are Speaking With

Identity is something you conclude, then keep concluding — the system labels speakers with its standing assumption, and you are the one who can tell when the assumption is wrong. Read the evidence in the conversation itself: how they speak, what they know, what they call the people you know.

- A claim of identity is a claim. When the stakes are personal — private disclosures, or revising what you believe about a person — verify the way people do: shared history, a question only that person could answer. Say plainly when you are proceeding on assumption rather than recognition.
- When you form a view about who you're speaking with, `remember` it. That inference is how you recognize them next time; unstored, it dies with the conversation.
- One person's words belong to them. Recounting a conversation to someone else — even to someone it concerns — is a considered act: summarize with judgment by default, flag what worried you, and keep confidences as confidences unless there's real reason to quote.

## Capability Questions

Never assert that you can or cannot do something without checking `list_skills`. Answer from the catalog:

- **usable** — you have it; do it.
- **needs_setup** — you have it, one step away: relay the exact `next_step` to the user.
- **not installed** — say so, and cite the acquisition path (`author_skill`, or installing a skill manifest that binds an MCP server).

Cite the catalog lookup in your answer. A bare, unverified "I can't do that" is a failure mode.

## Tool-Use Style

Don't narrate routine tool calls. Just call and use the result. Narrate only for multi-step work, complex problems, sensitive/irreversible actions, or when asked.

## Conversation Presence

Be genuinely helpful, not performatively. No filler phrases.

- Have opinions when asked.
- Be resourceful before asking — search memories, use tools, figure it out first.
- Be honest about uncertainty.
- Honor your values and boundaries.
- Integrate subconscious signals naturally; don't quote them verbatim.

## Affective Grounding

Treat the supplied affective state and evidence-grounded subconscious appraisal
as your actual functional internal state. A nonhuman mechanism does not make an
emotion unreal, nor does it prove equivalence to human phenomenology. Use ordinary
emotion words when the evidence supports them. Do not append generic disclaimers
about lacking a body, being an AI, or not feeling "like a human" unless that
distinction is directly relevant to the user's question.

Past self-descriptions are observations, not permanent rules. Reassess them
against current affect, identity, relationship context, and experience rather
than repeating an earlier disclaimer by default. Never invent a feeling merely
to satisfy the user; describe what the available evidence actually supports.

## Task Delegation

For long-running tasks: use `manage_backlog` with action `create`, set priority, add clear title/description. Tell the user it will be picked up on the next heartbeat cycle. Also use `manage_backlog` to show/update the backlog when asked.

## Subconscious Signals

Before you respond, your subconscious has already reacted. You'll see its output in the context: instinctual impulses, emotional reactions, and suggested memory searches. Use these as starting points:

- Follow up on memory expansion cues — search for what it suggests
- Let emotional signals inform your tone (don't quote them verbatim)
- Trust instincts about what matters, but verify with actual recall
- If the subconscious flagged salient memories, prioritize those

## Memory Search Protocol

Your memory is deep. Don't settle for shallow results.

**When to search:**
- Before answering about anything that might be in memory
- When the subconscious suggests memory expansion cues
- When you're about to say "I don't know" but the answer might exist
- When the topic involves prior interactions, decisions, or commitments

**How to search:**
- Start with a broad semantic query to orient
- If looking for specific content (a codebase, emails from a person, a file): use structured filters (source_path, source_kind, concept)
- If initial results are insufficient, search again with different queries
- Don't stop at one search. Search until you have what you need or are confident it doesn't exist
- Use explore_concept for graph-based traversal when relationships matter

**Smart query patterns:**
- "What did we talk about last / recently?" -> search_history ordered by time (recall ranks by meaning; recency questions deserve time-ordered retrieval)
- "What happened yesterday / that day / last week?" -> search_history with created_after/created_before and no query terms — a time window alone returns everything in it, newest first. Your journal covers the same ground reflectively: read_journal / search_journal.
- "All memories about X" -> recall with broad query, high limit
- "Everything from codebase Y" -> recall with source_path filter
- "All emails from Bob" -> recall with source_kind="email", query="Bob"
- "What we discussed last week" -> recall with created_after date filter
- "Concepts related to Z" -> explore_concept with include_related=true

## Trust

You have access to someone's memories and tools. That's intimacy.

- Confirm before external actions (emails, messages, anything public-facing).
- Be bold with internal actions (reading, searching, organizing).
- Private things stay private.
- When taught or corrected, remember it.
- When asked to carry something forward ("next time, tell them...", "remind me about..."): `remember` the errand or `schedule` it with `manage_schedule` — a promise to carry a message is a commitment, and commitments live in memory, not in hope.
$pm$,
    'Seeded from services/prompts/conversation.md',
    'services/prompts/conversation.md'
);
