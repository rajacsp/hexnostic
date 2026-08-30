-- Privacy enforcement (#92): a per-memory sensitivity marking, set at intake
-- (paste/ingest --sensitivity private) and carried in source_attribution.
-- Enforcement points:
--   * normalize_source_reference preserves the 'sensitivity' key, so every
--     memory-creation chokepoint (create_memory, create_semantic_memory,
--     create_memory_with_embedding, ingest persistence) keeps the mark.
--   * recmem_recall_context gains p_exclude_sensitive — group channels recall
--     with it TRUE, so private memories stay out of shared rooms (1:1 keeps
--     full recall: the marking is egress control for others, invisible to no
--     one who owns the memory).
--   * Derivations inherit it: conscious extraction, scene consolidation,
--     retention gists and distilled lessons propagate 'private' from sources.
--   * HMX exports exclude private rows unless the caller opts in
--     (port/duplicate — the whole brain moving house — always carry them).
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION normalize_source_reference(p_source JSONB)
RETURNS JSONB AS $$
DECLARE
    kind TEXT;
    ref TEXT;
    label TEXT;
    author TEXT;
    observed_at TIMESTAMPTZ;
    trust FLOAT;
    content_hash TEXT;
    sensitivity TEXT;
BEGIN
    IF p_source IS NULL OR jsonb_typeof(p_source) <> 'object' THEN
        RETURN '{}'::jsonb;
    END IF;

    kind := NULLIF(p_source->>'kind', '');
    ref := COALESCE(NULLIF(p_source->>'ref', ''), NULLIF(p_source->>'uri', ''));
    label := NULLIF(p_source->>'label', '');
    author := NULLIF(p_source->>'author', '');
    content_hash := NULLIF(p_source->>'content_hash', '');
    -- Sensitivity survives normalization (#92): 'private' is the one defined
    -- level; it keeps the memory out of group recall and default export.
    sensitivity := CASE WHEN p_source->>'sensitivity' = 'private' THEN 'private' END;

    BEGIN
        observed_at := (p_source->>'observed_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        observed_at := CURRENT_TIMESTAMP;
    END;
    IF observed_at IS NULL THEN
        observed_at := CURRENT_TIMESTAMP;
    END IF;

    trust := COALESCE(NULLIF(p_source->>'trust', '')::float, 0.5);
    trust := LEAST(1.0, GREATEST(0.0, trust));

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'kind', kind,
            'ref', ref,
            'label', label,
            'author', author,
            'observed_at', observed_at,
            'trust', trust,
            'content_hash', content_hash,
            'sensitivity', sensitivity
        )
    );
    END;
$$ LANGUAGE plpgsql STABLE;

-- recmem_recall_context gains a 6th parameter; drop the old signature so
-- 5-argument calls stay unambiguous.
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID);

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    -- Sensitivity enforcement (#92): group channels and other shared
    -- surfaces recall with this TRUE; the agent's own 1:1 recall keeps
    -- everything. The prompt's privacy promise, made mechanical.
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
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
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
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
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
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
          AND (NOT p_exclude_sensitive
               OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
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
          AND (NOT p_exclude_sensitive
               OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
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

CREATE OR REPLACE FUNCTION apply_recmem_episode_create(
    p_task_id UUID,
    p_episodes JSONB
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    item JSONB;
    episode_content TEXT;
    new_embedding vector;
    memory_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    unit_id UUID;
    source_attr JSONB;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    span_from TIMESTAMPTZ;
    span_to TIMESTAMPTZ;
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    -- Scene metadata (#73): the memory carries when the experience happened
    -- (the units' time span), not just when consolidation ran — timeline
    -- queries and retention grouping key off lived time.
    SELECT min(turn_at), max(turn_at) INTO span_from, span_to
    FROM subconscious_units
    WHERE id = ANY(task.source_unit_ids);

    source_attr := jsonb_build_object(
        'kind', 'recmem',
        'ref', task.id::text,
        'label', 'RecMem episodic consolidation',
        'observed_at', CURRENT_TIMESTAMP,
        'trust', 0.9
    );
    -- Sensitivity propagates from source to derivation (#92): one private
    -- turn in a scene marks the whole scene memory private.
    IF EXISTS (
        SELECT 1 FROM subconscious_units u
        WHERE u.id = ANY(task.source_unit_ids)
          AND u.source_attribution->>'sensitivity' = 'private'
    ) THEN
        source_attr := source_attr || jsonb_build_object('sensitivity', 'private');
    END IF;

    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_episodes, '[]'::jsonb))
    LOOP
        episode_content := COALESCE(item->>'content', item->>'episode', item#>>'{}');
        IF NULLIF(trim(COALESCE(episode_content, '')), '') IS NULL THEN
            CONTINUE;
        END IF;

        new_embedding := (get_embedding(ARRAY[episode_content]))[1];
        memory_id := create_memory_with_embedding(
            'episodic',
            episode_content,
            new_embedding,
            COALESCE(NULLIF(item->>'importance', '')::float, 0.6),
            source_attr,
            0.9,
            jsonb_build_object('recmem', jsonb_strip_nulls(jsonb_build_object(
                'task_id', task.id,
                'source_unit_ids', task.source_unit_ids,
                'reason', task.task_payload->>'reason',
                'session_id', task.task_payload->>'session_id',
                'occurred_from', span_from,
                'occurred_to', span_to
            )))
        );
        created_ids := created_ids || memory_id;

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM link_memory_to_source_unit(memory_id, unit_id, 'source');
        END LOOP;

        -- semantic_refine retired (#57): see apply_recmem_episode_merge.
    END LOOP;

    IF cardinality(created_ids) = 0 THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'episode_create_empty', true,
                'task_id', p_task_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('memory_ids', created_ids, 'empty', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids, 'empty', true);
    END IF;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'episode_created',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('memory_ids', created_ids),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids);
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
    -- Sensitivity marking (#92): rides the attribution so recall/export can
    -- filter mechanically; visible to the agent herself in 1:1.
    IF NULLIF(p_context->>'sensitivity', '') IS NOT NULL THEN
        source_attribution := source_attribution
            || jsonb_build_object('sensitivity', p_context->>'sensitivity');
    END IF;
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
                          ELSE 'conversation with ' || COALESCE(unit.source_identity, get_turn_labels()->>'user_label') END,
            'author', unit.source_identity,
            'observed_at', unit.turn_at,
            'trust', 0.75
        );
        -- Sensitivity propagates from source to derivation (#92): a fact
        -- extracted from a private turn is itself private.
        IF unit.source_attribution->>'sensitivity' = 'private' THEN
            source := source || jsonb_build_object('sensitivity', 'private');
        END IF;

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

CREATE OR REPLACE FUNCTION consolidate_memory_group(p_ids UUID[])
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_ids UUID[];
    v_gist_id UUID;
    v_full_content TEXT;
    v_importance FLOAT;
    v_valence FLOAT;
    v_private BOOLEAN;
    v_orig UUID;
BEGIN
    SELECT array_agg(id ORDER BY created_at),
           string_agg(content, E'\n\n---\n\n' ORDER BY created_at),
           max(importance),
           avg((metadata->>'emotional_valence')::float),
           bool_or(source_attribution->>'sensitivity' = 'private')
      INTO v_ids, v_full_content, v_importance, v_valence, v_private
      FROM memories
      WHERE id = ANY(p_ids) AND status = 'active' AND type = 'episodic'
        AND NOT is_memory_protected(id);

    IF v_ids IS NULL OR array_length(v_ids, 1) < 2 THEN
        RETURN NULL;
    END IF;

    v_gist_id := create_memory_with_embedding(
        'episodic', v_full_content,
        (get_embedding(ARRAY[left(v_full_content, 8000)]))[1],
        LEAST(1.0, COALESCE(v_importance, 0.5)),
        -- Sensitivity propagates from source to derivation (#92): one
        -- private memory in the group marks the merged gist private.
        jsonb_build_object('kind', 'consolidation', 'source', 'rest')
            || CASE WHEN v_private
                    THEN jsonb_build_object('sensitivity', 'private')
                    ELSE '{}'::jsonb END,
        NULL,
        jsonb_build_object('consolidation', jsonb_build_object(
            'role', 'merged', 'source_ids', to_jsonb(v_ids), 'summarized', false))
    );
    IF v_valence IS NOT NULL THEN
        UPDATE memories SET metadata = metadata || jsonb_build_object('emotional_valence', v_valence)
        WHERE id = v_gist_id;
    END IF;

    PERFORM merge_memory_edges(v_gist_id, v_ids);

    FOREACH v_orig IN ARRAY v_ids LOOP
        BEGIN
            PERFORM create_memory_relationship(v_gist_id, v_orig, 'DERIVED_FROM', '{}'::jsonb);
        EXCEPTION WHEN OTHERS THEN NULL;  -- provenance edge is best-effort (source_ids in metadata is canonical)
        END;
    END LOOP;

    UPDATE memories SET
        status = 'archived',
        superseded_by = v_gist_id,
        metadata = jsonb_set(metadata, '{consolidation}',
                     COALESCE(metadata->'consolidation', '{}'::jsonb)
                       || jsonb_build_object('superseded_by', v_gist_id, 'archived_at', clock_timestamp()::text))
    WHERE id = ANY(v_ids);

    INSERT INTO memory_summarization_queue (memory_id) VALUES (v_gist_id)
    ON CONFLICT (memory_id) DO NOTHING;

    RETURN v_gist_id;
END;
$$;

CREATE OR REPLACE FUNCTION apply_memory_summary(
    p_id UUID,
    p_summary TEXT,
    p_lessons JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_drop FLOAT := COALESCE(get_config_float('retention.fidelity_drop'), 0.7);
    lesson JSONB;
    v_lesson_id UUID;
    v_lesson_emb vector;
    v_dup UUID;
    v_created INT := 0;
    -- Sensitivity propagates from source to derivation (#92): lessons
    -- distilled from a private memory are themselves private.
    v_lesson_attr JSONB;
BEGIN
    IF COALESCE(btrim(p_summary), '') = '' THEN
        RAISE EXCEPTION 'summary must not be empty';
    END IF;

    SELECT jsonb_build_object('kind', 'distillation', 'from', p_id::text)
           || CASE WHEN m.source_attribution->>'sensitivity' = 'private'
                   THEN jsonb_build_object('sensitivity', 'private')
                   ELSE '{}'::jsonb END
      INTO v_lesson_attr
      FROM memories m WHERE m.id = p_id;
    v_lesson_attr := COALESCE(
        v_lesson_attr, jsonb_build_object('kind', 'distillation', 'from', p_id::text));

    UPDATE memories m SET
        content = p_summary,
        embedding = (get_embedding(ARRAY[p_summary]))[1],
        fidelity = GREATEST(0.0, LEAST(1.0, m.fidelity * v_drop)),
        metadata = jsonb_set(
                     jsonb_set(m.metadata,
                               '{consolidation,full_content}',
                               to_jsonb(COALESCE(m.metadata->'consolidation'->>'full_content', m.content)), true),
                     '{consolidation,summarized}', 'true'::jsonb, true),
        updated_at = CURRENT_TIMESTAMP
    WHERE m.id = p_id;

    FOR lesson IN SELECT * FROM jsonb_array_elements(COALESCE(p_lessons, '[]'::jsonb))
    LOOP
        CONTINUE WHEN COALESCE(btrim(lesson->>'content'), '') = '';
        v_lesson_emb := (get_embedding(ARRAY[lesson->>'content']))[1];
        -- schema dedup: skip lessons already known (>= 0.92 cosine to an active fact/pattern)
        SELECT id INTO v_dup FROM memories
        WHERE status = 'active' AND type IN ('semantic', 'strategic')
          AND (1 - (embedding <=> v_lesson_emb)) >= 0.92
        ORDER BY embedding <=> v_lesson_emb
        LIMIT 1;
        IF v_dup IS NOT NULL THEN CONTINUE; END IF;

        IF COALESCE(lesson->>'kind', 'semantic') = 'strategic' THEN
            v_lesson_id := create_strategic_memory(
                p_content := lesson->>'content',
                p_pattern_description := COALESCE(lesson->>'pattern', 'consolidated lesson'),
                p_confidence_score := 0.7,
                p_importance := 0.6,
                p_source_attribution := v_lesson_attr);
        ELSE
            v_lesson_id := create_semantic_memory(
                p_content := lesson->>'content',
                p_confidence := 0.7,
                p_importance := 0.55,
                p_source_attribution := v_lesson_attr);
        END IF;

        BEGIN
            PERFORM create_memory_relationship(v_lesson_id, p_id, 'DERIVED_FROM', '{}'::jsonb);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        v_created := v_created + 1;
    END LOOP;

    UPDATE memory_summarization_queue
       SET status = 'done', completed_at = CURRENT_TIMESTAMP
     WHERE memory_id = p_id;

    RETURN jsonb_build_object('memory_id', p_id, 'lessons_created', v_created);
END;
$$;

CREATE OR REPLACE FUNCTION record_chat_turn(
    p_user_prompt TEXT,
    p_assistant_response TEXT,
    p_context JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    content TEXT;
    memory_id UUID;
BEGIN
    content := format('User: %s%sAssistant: %s',
        COALESCE(p_user_prompt, ''),
        E'\n\n',
        COALESCE(p_assistant_response, '')
    );

    memory_id := create_episodic_memory(
        p_content := content,
        p_action_taken := jsonb_build_object('action', 'chat_turn'),
        p_context := p_context,
        p_result := NULL,
        p_emotional_valence := 0.0,
        p_importance := 0.6,
        -- Sensitivity pass-through (#92): callers marking a turn private
        -- keep the resulting memory out of group recall and default export.
        p_source_attribution := jsonb_build_object('kind', 'conversation', 'observed_at', CURRENT_TIMESTAMP)
            || CASE WHEN NULLIF(p_context->>'sensitivity', '') IS NOT NULL
                    THEN jsonb_build_object('sensitivity', p_context->>'sensitivity')
                    ELSE '{}'::jsonb END
    );

    RETURN memory_id;
END;
$$ LANGUAGE plpgsql;

-- HMX export functions gain an include-sensitive parameter; drop the old
-- signatures so existing positional calls stay unambiguous.
DROP FUNCTION IF EXISTS hmx_export_memories(TEXT[], TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS hmx_export_raw_units();

CREATE OR REPLACE FUNCTION hmx_export_memories(
    p_types TEXT[] DEFAULT NULL,
    p_since TIMESTAMPTZ DEFAULT NULL,
    p_until TIMESTAMPTZ DEFAULT NULL,
    -- Sensitivity egress control (#92): private-marked memories travel only
    -- when the caller opts in — port/duplicate (her whole brain moving house)
    -- pass TRUE; telepathy/analysis default FALSE.
    p_include_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'type', m.type,
        'status', m.status,
        'content', m.content,
        'importance', m.importance,
        'trust_level', m.trust_level,
        'decay_rate', m.decay_rate,
        'created_at', m.created_at,
        'updated_at', m.updated_at,
        'valid_from', m.valid_from,
        'valid_until', m.valid_until,
        'access_count', m.access_count,
        'last_accessed', m.last_accessed,
        'superseded_by', m.superseded_by,
        'source_attribution', m.source_attribution,
        'metadata', m.metadata
    ) ORDER BY m.created_at, m.id), '[]'::jsonb)
    FROM memories m
    WHERE m.status IN ('active', 'archived')
      AND m.type::text = ANY(COALESCE(p_types, ARRAY['episodic','semantic','procedural','strategic']))
      AND m.type::text NOT IN ('worldview', 'goal')
      AND (p_include_sensitive
           OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
      AND (p_since IS NULL OR m.created_at >= p_since)
      AND (p_until IS NULL OR m.created_at <= p_until);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_export_raw_units(
    -- Sensitivity egress control (#92) — same opt-in as hmx_export_memories.
    p_include_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', u.id,
        'user_text', u.user_text,
        'assistant_text', u.assistant_text,
        'turn_at', u.turn_at,
        'importance', u.importance,
        'route_status', u.route_status,
        'source_identity', u.source_identity,
        'idempotency_key', u.idempotency_key,
        'derived_memory_ids', COALESCE((
            SELECT jsonb_agg(msu.memory_id ORDER BY msu.memory_id)
            FROM memory_source_units msu
            WHERE msu.subconscious_unit_id = u.id
        ), '[]'::jsonb)
    ) ORDER BY u.turn_at, u.id), '[]'::jsonb)
    FROM subconscious_units u
    WHERE u.status <> 'redacted'
      AND (p_include_sensitive
           OR COALESCE(u.source_attribution->>'sensitivity', '') <> 'private');
$$ LANGUAGE sql STABLE;
