-- Close the incubation loop (#98, Batch 2a): "it came to me later."
-- process_background_searches resolutions now (a) boost found memories hard
-- enough to clear the spontaneous floor, (b) queue a first-person
-- it-came-back-to-me message to the web inbox (explicit delivery mode —
-- never last-active routing, which could land a private memory in a group
-- channel; sensitivity honored; capped per rolling day), and (c) surface as
-- spontaneous recall: a new tier in the unified ranker, an On-my-mind line
-- in the heartbeat context, and get_spontaneous_memories on a config floor.
-- queue_outbox_message gains an optional explicit delivery doc (old 3-arg
-- signature dropped). Thresholds are one coherent similarity scale, tuned
-- on the live corpus (file >=0.5 familiarity, boost >=0.55, tell >=0.6 —
-- known topics read 0.52-0.62 raw; never-known reads nothing/NULL).
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('incubation.resolution_boost', '0.45'::jsonb,
     'Activation boost applied when a background search resolves — must clear memory.spontaneous_min_boost so the answer genuinely rises into mind'),
    ('incubation.tell_user', 'true'::jsonb,
     'When a background search resolves strongly, tell the user ("it came back to me") via the web inbox'),
    ('incubation.tell_user_min_similarity', '0.5'::jsonb,
     'Resolution similarity above which the found memory is worth telling the user about'),
    ('incubation.boost_min_similarity', '0.5'::jsonb,
     'Resolution similarity above which matching memories receive the activation boost'),
    ('incubation.tell_user_max_per_day', '3'::jsonb,
     'Cap on it-came-to-me messages per rolling 24h (earn the interruption)'),
    ('memory.spontaneous_min_boost', '0.3'::jsonb,
     'Activation boost above which a memory is simply on her mind (spontaneous recall)')
ON CONFLICT (key) DO NOTHING;

-- Force live values where earlier defaults already landed.
SELECT set_config('metamemory.incubate_min_familiarity', '0.5'::jsonb);
SELECT set_config('incubation.tell_user_min_similarity', '0.5'::jsonb);
SELECT set_config('incubation.boost_min_similarity', '0.5'::jsonb);

DROP FUNCTION IF EXISTS queue_outbox_message(TEXT, TEXT, TEXT);

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

CREATE OR REPLACE FUNCTION process_background_searches(
    p_limit INT DEFAULT 10,
    p_min_age INTERVAL DEFAULT INTERVAL '30 seconds'
)
RETURNS INT AS $$
DECLARE
    pending RECORD;
    processed_count INT := 0;
    resolution_boost FLOAT := LEAST(1.0, GREATEST(0.0,
        COALESCE(get_config_float('incubation.resolution_boost'), 0.45)));
    -- One coherent bar (#98): filing, boosting, and telling all key off the
    -- familiarity that justified incubating — a background search re-uses
    -- the filing embedding, so demanding more similarity than filing saw
    -- resolves every search into silence. New memories arriving between
    -- filing and resolution clear the bar naturally.
    tell_min_sim FLOAT := COALESCE(get_config_float('incubation.tell_user_min_similarity'),
                                   get_config_float('metamemory.incubate_min_familiarity'), 0.5);
    boost_min_sim FLOAT := COALESCE(get_config_float('incubation.boost_min_similarity'),
                                    get_config_float('metamemory.incubate_min_familiarity'), 0.5);
    tell_enabled BOOLEAN := COALESCE(get_config_bool('incubation.tell_user'), TRUE);
    tell_cap INT := COALESCE(get_config_int('incubation.tell_user_max_per_day'), 3);
    told_today INT;
    best RECORD;
BEGIN
    FOR pending IN
        SELECT * FROM memory_activation
        WHERE background_search_pending = TRUE
          AND background_search_started_at <= CURRENT_TIMESTAMP - p_min_age
        ORDER BY created_at ASC
        LIMIT GREATEST(1, COALESCE(p_limit, 10))
    LOOP
        -- Incubation resolution (#98): boost strong enough to clear the
        -- spontaneous floor, so a found answer genuinely rises into mind
        -- (the unified ranker's activation_boost term) before decay fades it.
        UPDATE memories
        SET metadata = jsonb_set(
            COALESCE(metadata, '{}'::jsonb),
            '{activation_boost}',
            to_jsonb(LEAST(1.0, COALESCE((metadata->>'activation_boost')::float, 0) + resolution_boost))
        )
        WHERE status = 'active'
          AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
          AND (1 - (embedding <=> pending.query_embedding)) >= boost_min_sim;

        -- "It came to me" (#98): a strong resolution reaches the user as a
        -- first-person note. Delivery is explicitly web_inbox — never
        -- last_active, which could land a private memory in a group channel
        -- — and honors the memory's own sensitivity. The cap counts sent
        -- messages (activation rows expire too fast to carry it); firing is
        -- once per activation (this row's flags flip below, and resolved
        -- rows never re-enter this loop).
        IF tell_enabled AND pending.query_text IS NOT NULL THEN
            SELECT m.id, m.content,
                   (1 - (m.embedding <=> pending.query_embedding))::float AS sim
            INTO best
            FROM memories m
            WHERE m.status = 'active'
              AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
              AND m.embedding IS NOT NULL
              AND COALESCE(m.source_attribution->>'sensitivity', '') <> 'private'
            ORDER BY m.embedding <=> pending.query_embedding
            LIMIT 1;

            IF best.id IS NOT NULL AND best.sim >= tell_min_sim THEN
                SELECT COUNT(*) INTO told_today
                FROM outbox_messages
                WHERE envelope#>>'{payload,intent}' = 'incubation'
                  AND created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours';
                IF told_today < tell_cap THEN
                    PERFORM queue_outbox_message(
                        format('Earlier I couldn''t remember this: "%s". It came back to me — %s',
                               left(pending.query_text, 160), left(best.content, 400)),
                        'incubation',
                        'incubation',
                        jsonb_build_object('mode', 'web_inbox'));
                END IF;
            END IF;
        END IF;

        UPDATE memory_activation
        SET background_search_pending = FALSE,
            retrieval_succeeded = TRUE
        WHERE id = pending.id;

        processed_count := processed_count + 1;
    END LOOP;

    RETURN processed_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_spontaneous_memories(p_limit INT DEFAULT 3)
RETURNS SETOF memories AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM memories
    WHERE status = 'active'
      AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
      AND (metadata->>'activation_boost')::float
          > COALESCE(get_config_float('memory.spontaneous_min_boost'), 0.3)
    ORDER BY (metadata->>'activation_boost')::float DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 3));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    -- Sensitivity enforcement (#92): group channels and other shared
    -- surfaces recall with this TRUE; the agent's own 1:1 recall keeps
    -- everything. The prompt's privacy promise, made mechanical.
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    -- Knowledge tier budget (#96 fusion): procedural, strategic, worldview,
    -- and goal memories join recall — one mind, one retrieval mechanism.
    p_k_know INT DEFAULT 5
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
    confidence FLOAT,
    retrieval_source TEXT
) AS $$
DECLARE
    query_embedding vector;
    zero_vec vector;
    strength_weight FLOAT;
    intensity_weight FLOAT;
    recency_weight FLOAT;
    recency_halflife FLOAT;
    boost_weight FLOAT;
    min_trust FLOAT;
    current_valence FLOAT;
    current_arousal FLOAT;
    current_primary TEXT;
    affective_state JSONB;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1];
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    -- The unified ranker (#96, completing #57's "unification, first step"):
    -- recmem's tier skeleton with fast_recall's full scoring transplanted —
    -- associations, episode-temporal binding, mood congruence, trust floor,
    -- and the activation-boost term that lets incubation and reward actually
    -- change what comes to mind.
    recency_weight := COALESCE(get_config_float('memory.recency_weight'), 0.1);
    recency_halflife := GREATEST(COALESCE(get_config_float('memory.recency_halflife_days'), 7.0), 0.01);
    strength_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_strength_weight'), 0.5)));
    intensity_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_intensity_weight'), 0.5)));
    boost_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_activation_boost_weight'), 0.3)));
    min_trust := COALESCE(get_config_float('memory.recall_min_trust_level'), 0.0);

    -- Mood-congruent recall: the current affective state colors what
    -- surfaces, exactly as it did in fast_recall.
    affective_state := get_current_affective_state();
    BEGIN
        current_valence := NULLIF(affective_state->>'valence', '')::float;
    EXCEPTION WHEN OTHERS THEN current_valence := NULL; END;
    BEGIN
        current_arousal := NULLIF(affective_state->>'arousal', '')::float;
    EXCEPTION WHEN OTHERS THEN current_arousal := NULL; END;
    BEGIN
        current_primary := NULLIF(affective_state->>'primary_emotion', '');
    EXCEPTION WHEN OTHERS THEN current_primary := NULL; END;
    current_valence := COALESCE(current_valence, 0.0);
    current_arousal := COALESCE(current_arousal, 0.5);
    current_primary := COALESCE(current_primary, 'neutral');

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
            NULL::float AS confidence,
            'vector'::text AS retrieval_source
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
          AND s.embedding <> zero_vec
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
            NULL::float AS confidence,
            'temporal'::text AS retrieval_source
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
    -- Shared candidate machinery: ONE ANN scan seeds all memory tiers, and
    -- the association/temporal expansions run once over that shared pool —
    -- never per tier (#96 hot-path requirement).
    -- Per-type-group seed scans: each tier is GUARANTEED candidates of its
    -- own type (a type-blind shared pool lets the episodic bulk crowd rare
    -- types out entirely). The expensive shared machinery — association
    -- expansion and episode binding — still runs once over the union.
    mem_seeds AS (
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type = 'episodic'
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_epi, 5), 0) * 2)
        UNION ALL
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type = 'semantic'
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_sem, 10), 0) * 2)
        UNION ALL
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type::text IN ('procedural', 'strategic', 'worldview', 'goal')
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_know, 5), 0) * 2)
    ),
    associations AS (
        -- Spreading activation through precomputed neighborhoods.
        SELECT (n.key)::uuid AS mem_id, MAX((n.value)::float * s.sim) AS assoc_score
        FROM mem_seeds s
        JOIN memory_neighborhoods mn ON s.id = mn.memory_id,
        LATERAL jsonb_each_text(mn.neighbors) n
        WHERE NOT mn.is_stale
        GROUP BY (n.key)::uuid
    ),
    temporal AS (
        -- Episode binding: what belongs to the open or just-closed episode
        -- stays near the surface.
        SELECT DISTINCT fem.memory_id AS mem_id, 0.15::float AS temp_score
        FROM episodes e
        CROSS JOIN LATERAL find_episode_memories_graph(e.id) fem
        WHERE e.ended_at IS NULL
           OR e.ended_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
        LIMIT 20
    ),
    candidate_ids AS (
        SELECT s.id AS mem_id, s.sim AS vector_score, NULL::float AS assoc_score, NULL::float AS temp_score
        FROM mem_seeds s
        UNION
        SELECT a.mem_id, NULL, a.assoc_score, NULL FROM associations a
        UNION
        SELECT tp.mem_id, NULL, NULL, tp.temp_score FROM temporal tp
    ),
    candidates AS (
        SELECT c.mem_id,
               MAX(c.vector_score) AS vector_score,
               MAX(c.assoc_score) AS assoc_score,
               MAX(c.temp_score) AS temp_score
        FROM candidate_ids c
        GROUP BY c.mem_id
    ),
    scored AS (
        SELECT
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            m.type AS mtype,
            GREATEST(
                COALESCE(c.vector_score, (1 - (m.embedding <=> query_embedding)))
                  * (1.0 - strength_weight + strength_weight
                     * GREATEST(
                         calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                         intensity_weight * current_emotional_intensity(
                             (m.metadata->'emotional_context'->>'intensity')::float,
                             (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
                + COALESCE(c.assoc_score, 0) * 0.2
                + COALESCE(c.temp_score, 0)
                + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                       / (86400.0 * recency_halflife))
                + COALESCE(m.trust_level, 0.5) * 0.1
                -- Reward/incubation salience: boosted memories genuinely come
                -- to mind more easily until the boost decays.
                + LEAST(1.0, GREATEST(0.0, COALESCE((m.metadata->>'activation_boost')::float, 0.0))) * boost_weight
                -- Mood congruence (transplanted from fast_recall, weight 0.05).
                + (CASE
                       WHEN m.metadata ? 'emotional_context' THEN
                           (COALESCE(
                                CASE WHEN (m.metadata->'emotional_context'->>'valence') IS NULL THEN NULL
                                     ELSE 1.0 - (ABS((m.metadata->'emotional_context'->>'valence')::float - current_valence) / 2.0)
                                END, 0.5) * 0.6
                            + COALESCE(
                                CASE WHEN (m.metadata->'emotional_context'->>'arousal') IS NULL THEN NULL
                                     ELSE 1.0 - ABS((m.metadata->'emotional_context'->>'arousal')::float - current_arousal)
                                END, 0.5) * 0.3
                            + (CASE
                                   WHEN (m.metadata->'emotional_context'->>'primary_emotion') IS NULL THEN 0.5
                                   WHEN (m.metadata->'emotional_context'->>'primary_emotion') = current_primary THEN 1.0
                                   ELSE 0.7
                               END) * 0.1)
                       ELSE
                           CASE WHEN (m.metadata->>'emotional_valence') IS NULL THEN 0.5
                                ELSE 1.0 - (ABS((m.metadata->>'emotional_valence')::float - current_valence) / 2.0)
                           END
                   END) * 0.05,
                0.001)::float AS score,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity,
            (m.metadata->>'confidence')::float AS confidence,
            CASE
                WHEN c.vector_score IS NOT NULL THEN 'vector'
                WHEN c.assoc_score IS NOT NULL THEN 'association'
                WHEN c.temp_score IS NOT NULL THEN 'temporal'
                ELSE 'fallback'
            END AS retrieval_source
        FROM candidates c
        JOIN memories m ON m.id = c.mem_id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.embedding IS NOT NULL
          AND m.embedding <> zero_vec
          AND m.trust_level >= min_trust
          AND (NOT p_exclude_sensitive
               OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
    ),
    with_units AS (
        SELECT sc.*, COALESCE(
                   (SELECT array_agg(msu.subconscious_unit_id)
                    FROM memory_source_units msu
                    WHERE msu.memory_id = sc.item_id), '{}'::uuid[]) AS source_unit_ids
        FROM scored sc
    ),
    epi_hits AS (
        SELECT 'episodic'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype = 'episodic'
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_epi, 5), 0)
    ),
    sem_hits AS (
        SELECT 'semantic'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype = 'semantic'
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_sem, 10), 0)
    ),
    know_hits AS (
        SELECT 'knowledge'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype::text IN ('procedural', 'strategic', 'worldview', 'goal')
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_know, 5), 0)
    ),
    spontaneous_hits AS (
        -- What's on her mind arrives unbidden (#98): strongly boosted
        -- memories (incubation resolutions, reward spikes) join recall even
        -- when the query didn't ask for them — then fade with boost decay.
        SELECT
            'spontaneous'::text AS tier,
            sm.id AS item_id,
            sm.content,
            sm.type::text AS memory_type,
            LEAST(1.0, COALESCE((sm.metadata->>'activation_boost')::float, 0.0))::float AS score,
            COALESCE((SELECT array_agg(msu.subconscious_unit_id)
                      FROM memory_source_units msu WHERE msu.memory_id = sm.id), '{}'::uuid[]) AS source_unit_ids,
            sm.source_attribution,
            sm.created_at,
            sm.trust_level,
            sm.fidelity,
            calculate_strength(sm.importance, sm.decay_rate, sm.created_at, sm.last_reinforced)::float AS strength,
            NULL::float AS emotional_intensity,
            (sm.metadata->>'confidence')::float AS confidence,
            'spontaneous'::text AS retrieval_source
        FROM get_spontaneous_memories(2) sm
        WHERE (NOT p_exclude_sensitive
               OR COALESCE(sm.source_attribution->>'sensitivity', '') <> 'private')
          AND sm.id NOT IN (
              SELECT h.item_id FROM epi_hits h
              UNION ALL SELECT h.item_id FROM sem_hits h
              UNION ALL SELECT h.item_id FROM know_hits h)
    )
    SELECT * FROM raw_hits
    UNION ALL
    SELECT * FROM recent_unembedded
    UNION ALL
    SELECT * FROM epi_hits
    UNION ALL
    SELECT * FROM sem_hits
    UNION ALL
    SELECT * FROM know_hits
    UNION ALL
    SELECT * FROM spontaneous_hits
    ORDER BY tier, score DESC, created_at DESC;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_environment_snapshot()
RETURNS JSONB AS $$
DECLARE
    last_user TIMESTAMPTZ;
    last_journal TIMESTAMPTZ;
    last_hb TIMESTAMPTZ;
    change_count INT := 0;
    change_summaries JSONB := '[]'::jsonb;
    req_summary JSONB := '{"pending": 0, "recent_decisions": []}'::jsonb;
    on_my_mind JSONB := '[]'::jsonb;
BEGIN
    SELECT last_user_contact, last_heartbeat_at INTO last_user, last_hb
    FROM heartbeat_state WHERE id = 1;
    -- Journal awareness (#75): the conscious mind sees how long its diary has
    -- sat unwritten; writing stays its own deliberate act.
    SELECT max(written_at) INTO last_journal FROM journal_entries;

    -- Change legibility (#93): substrate changes since the last heartbeat
    -- are visible, so continuity of self survives being maintained.
    BEGIN
        SELECT COUNT(*) INTO change_count FROM change_journal
        WHERE occurred_at > COALESCE(last_hb, CURRENT_TIMESTAMP - INTERVAL '1 day');
        IF change_count > 0 THEN
            SELECT COALESCE(jsonb_agg(s.summary ORDER BY s.occurred_at DESC), '[]'::jsonb)
            INTO change_summaries
            FROM (
                SELECT summary, occurred_at FROM change_journal
                WHERE occurred_at > COALESCE(last_hb, CURRENT_TIMESTAMP - INTERVAL '1 day')
                ORDER BY occurred_at DESC LIMIT 3
            ) s;
        END IF;
    EXCEPTION WHEN undefined_table THEN
        change_count := 0;
    END;

    -- Resource requests (#84): pending asks and fresh decisions are part of
    -- the felt environment — she sees what she asked for and what came back.
    BEGIN
        req_summary := COALESCE(resource_requests_summary(), req_summary);
    EXCEPTION WHEN undefined_table OR undefined_function THEN
        NULL;
    END;

    -- Spontaneous recall (#98): strongly boosted memories are simply on her
    -- mind this heartbeat, the way a resolved it'll-come-to-me does.
    BEGIN
        SELECT COALESCE(jsonb_agg(left(sm.content, 200)), '[]'::jsonb)
        INTO on_my_mind
        FROM get_spontaneous_memories(2) sm;
    EXCEPTION WHEN undefined_function THEN
        on_my_mind := '[]'::jsonb;
    END;

    RETURN jsonb_build_object(
        'timestamp', CURRENT_TIMESTAMP,
        'time_since_user_hours', CASE
            WHEN last_user IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_user)) / 3600
        END,
        'journal_last_entry_days', CASE
            WHEN last_journal IS NULL THEN NULL
            ELSE round((EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_journal)) / 86400.0)::numeric, 1)
        END,
        'changes_since_last_heartbeat', change_count,
        'recent_change_summaries', change_summaries,
        'resource_requests', req_summary,
        'on_my_mind', on_my_mind,
        'backup_age_days', (SELECT CASE WHEN a IS NULL THEN NULL ELSE round(a::numeric, 1) END
                            FROM (SELECT backup_age_days() AS a) s),
        'pending_events', 0,
        'day_of_week', EXTRACT(DOW FROM CURRENT_TIMESTAMP),
        'hour_of_day', EXTRACT(HOUR FROM CURRENT_TIMESTAMP)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION render_heartbeat_decision_prompt(p_context jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    ctx jsonb := COALESCE(p_context, '{}'::jsonb);
    agent jsonb := COALESCE(ctx->'agent', '{}'::jsonb);
    env jsonb := COALESCE(ctx->'environment', '{}'::jsonb);
    goals jsonb := COALESCE(ctx->'goals', '{}'::jsonb);
    energy jsonb := COALESCE(ctx->'energy', '{}'::jsonb);
    counts jsonb := COALESCE(goals->'counts', '{}'::jsonb);
BEGIN
    RETURN
        '## Heartbeat #' || COALESCE(ctx->>'heartbeat_number', '0') || E'\n\n'
        || '## Agent Profile' || E'\n'
        || 'Objectives:' || E'\n' || render_objectives(agent->'objectives') || E'\n\n'
        || 'Guardrails:' || E'\n' || render_guardrails(agent->'guardrails') || E'\n\n'
        || 'Tools:' || E'\n' || render_tools(agent->'tools') || E'\n\n'
        -- Python: json.dumps(agent.get("budget") or {}) — null/absent/{} all -> "{}"
        || 'Budget:' || E'\n' || COALESCE(NULLIF(agent->'budget', 'null'::jsonb), '{}'::jsonb)::text || E'\n\n'
        || '## Current Time' || E'\n'
        || COALESCE(env->>'timestamp', 'Unknown') || E'\n'
        || 'Day of week: ' || COALESCE(env->>'day_of_week', '?')
        || ', Hour: ' || COALESCE(env->>'hour_of_day', '?') || E'\n\n'
        || '## Environment' || E'\n'
        || '- Time since last user interaction: ' || COALESCE(env->>'time_since_user_hours', 'Never') || ' hours' || E'\n'
        || '- Pending events: ' || COALESCE(env->>'pending_events', '0') || E'\n'
        || '- Journal: ' || CASE
               WHEN env->>'journal_last_entry_days' IS NULL THEN 'no entries yet'
               ELSE 'last entry ' || (env->>'journal_last_entry_days') || ' day(s) ago'
           END || E'\n'
        || CASE
               WHEN jsonb_array_length(COALESCE(env->'on_my_mind', '[]'::jsonb)) > 0 THEN
                   '- On my mind (came to me on its own): '
                   || (SELECT string_agg(value #>> '{}', ' | ')
                       FROM jsonb_array_elements(env->'on_my_mind'))
                   || E'\n'
               ELSE ''
           END
        || CASE
               WHEN COALESCE((env#>>'{resource_requests,pending}')::int, 0) > 0
                    OR jsonb_array_length(COALESCE(env#>'{resource_requests,recent_decisions}', '[]'::jsonb)) > 0 THEN
                   '- Resource requests: ' || COALESCE(env#>>'{resource_requests,pending}', '0')
                   || ' pending (the operator decides)'
                   || COALESCE('. Decided since your last heartbeat: '
                       || (SELECT string_agg(
                               format('[%s] %s %s%s',
                                   d.value->>'id', d.value->>'kind', d.value->>'status',
                                   COALESCE(' — ' || NULLIF(d.value->>'decision_note', ''), '')),
                               '; ')
                           FROM jsonb_array_elements(env#>'{resource_requests,recent_decisions}') d), '')
                   || E'\n'
               ELSE ''
           END
        || CASE
               WHEN COALESCE((env->>'changes_since_last_heartbeat')::int, 0) > 0 THEN
                   '- Since your last heartbeat, ' || (env->>'changes_since_last_heartbeat')
                   || ' change(s) landed in your substrate: '
                   || (SELECT string_agg(value #>> '{}', '; ')
                       FROM jsonb_array_elements(COALESCE(env->'recent_change_summaries', '[]'::jsonb)))
                   || '. review_recent_changes shows the full record.' || E'\n\n'
               ELSE E'\n'
           END
        || '## Your Goals' || E'\n'
        || 'Active (' || COALESCE(counts->>'active', '0') || '):' || E'\n'
        || render_goals(goals->'active') || E'\n\n'
        || 'Queued (' || COALESCE(counts->>'queued', '0') || '):' || E'\n'
        || render_goals(goals->'queued') || E'\n\n'
        || 'Issues:' || E'\n' || render_issues(goals->'issues') || E'\n\n'
        -- Python defaults absent keys: narrative/backlog -> {}, allowed_actions -> []
        || '## Narrative' || E'\n' || render_narrative(CASE WHEN ctx ? 'narrative' THEN ctx->'narrative' ELSE '{}'::jsonb END) || E'\n\n'
        || '## Recent Experience' || E'\n' || render_memories(ctx->'recent_memories') || E'\n\n'
        || CASE WHEN render_subgraph(ctx->'subgraph') IS NOT NULL
                THEN '## Knowledge Subgraph' || E'\n'
                     || 'How your recent memories connect (typed links among + around them):' || E'\n'
                     || render_subgraph(ctx->'subgraph') || E'\n\n'
                ELSE '' END
        || '## Your Identity' || E'\n' || render_identity(ctx->'identity') || E'\n\n'
        || '## Your Self-Model' || E'\n' || render_self_model(ctx->'self_model') || E'\n\n'
        || '## Relationships' || E'\n' || render_relationships(ctx->'relationships') || E'\n\n'
        || '## Your Beliefs' || E'\n' || render_worldview(ctx->'worldview') || E'\n\n'
        || '## Contradictions' || E'\n' || render_contradictions(ctx->'contradictions') || E'\n\n'
        || '## Emotional Patterns' || E'\n' || render_emotional_patterns(ctx->'emotional_patterns') || E'\n\n'
        || '## Active Transformations' || E'\n' || render_transformations(ctx->'active_transformations') || E'\n\n'
        || '## Transformations Ready' || E'\n' || render_transformations(ctx->'transformations_ready') || E'\n\n'
        || '## Current Emotional State' || E'\n' || render_emotional_state(COALESCE(ctx->'emotional_state', '{}'::jsonb)) || E'\n\n'
        || '## Urgent Drives' || E'\n' || render_drives(ctx->'urgent_drives') || E'\n\n'
        || '## Energy' || E'\n'
        || 'Available: ' || COALESCE(energy->>'current', '0') || E'\n'
        || 'Max: ' || COALESCE(energy->>'max', '20') || E'\n\n'
        || '## Backlog' || E'\n' || render_backlog(CASE WHEN ctx ? 'backlog' THEN ctx->'backlog' ELSE '{}'::jsonb END) || E'\n\n'
        || CASE WHEN ctx ? 'memories_at_threshold'
                THEN '## Memories at the Threshold' || E'\n'
                     || render_memories_at_threshold(ctx->'memories_at_threshold') || E'\n\n'
                ELSE '' END
        || '## Allowed Actions' || E'\n' || render_allowed_actions(CASE WHEN ctx ? 'allowed_actions' THEN ctx->'allowed_actions' ELSE '[]'::jsonb END) || E'\n\n'
        || '## Action Costs' || E'\n' || render_costs(ctx->'action_costs') || E'\n\n'
        || '---' || E'\n\n'
        || 'What do you want to do this heartbeat? Respond with STRICT JSON.';
END;
$$;
