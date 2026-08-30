-- The unified ranker (#96/#78, Batch 1b): one mind, one retrieval
-- mechanism. recmem_recall_context becomes the single scoring engine —
-- recmem's tier skeleton with fast_recall's machinery transplanted:
-- neighborhood associations, episode-temporal binding, mood-congruent
-- recall, the trust floor, and a new activation-boost term (incubation and
-- reward genuinely change what comes to mind). A knowledge tier joins
-- (procedural/strategic/worldview/goal — previously reachable only via
-- fast_recall's type-unfiltered scan). fast_recall becomes a flattening
-- wrapper over the unified function, which transitively upgrades the whole
-- db/05 recall wrapper family (recall_hybrid, recall_memories_filtered/
-- structured/stub) and every downstream caller in one move.
-- Shared-CTE architecture: one ANN seed scan + one association expansion +
-- one episode-binding pass, scored once, split per tier.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('memory.recall_activation_boost_weight', '0.3'::jsonb,
     'How strongly activation boosts (incubation resolutions, dopamine spikes) lift a memory in unified recall')
ON CONFLICT (key) DO NOTHING;

-- Both functions change signature; drop the old forms so positional calls
-- stay unambiguous.
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID, BOOLEAN);
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID, BOOLEAN, INT);
DROP FUNCTION IF EXISTS fast_recall(TEXT, INT, BOOLEAN);
DROP FUNCTION IF EXISTS fast_recall(TEXT, INT);

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
    ORDER BY tier, score DESC, created_at DESC;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fast_recall(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    fidelity FLOAT,
    emotional_intensity FLOAT
) AS $$
    -- One mind, one retrieval mechanism (#96/#78): fast_recall is now a
    -- flattening wrapper over the unified ranker in recmem_recall_context —
    -- every caller (the db/05 recall wrapper family, context gathering,
    -- observation sweeps) gets the same scoring the chat hot path uses:
    -- associations, episode binding, recency, strength, mood congruence,
    -- trust floor, activation boost, and sensitivity enforcement.
    SELECT
        r.item_id AS memory_id,
        r.content,
        r.memory_type::memory_type,
        r.score,
        r.retrieval_source AS source,
        r.fidelity,
        r.emotional_intensity
    FROM recmem_recall_context(
        p_query_text,
        0,                    -- no unit tiers: fast_recall's contract is memories
        GREATEST(p_limit, 5),
        GREATEST(p_limit, 5),
        NULL,
        p_exclude_sensitive,
        GREATEST(p_limit, 5)
    ) r
    WHERE r.tier IN ('episodic', 'semantic', 'knowledge')
    ORDER BY r.score DESC, r.created_at DESC
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;
