-- 0046: Graded browse and the open_memory drill-down (#76, Rev 5 Phase 4).
-- Timeline browsing returns preview-grain turn rows under a config-owned
-- ceiling (memory.history_browse_max); hydration renders scenes and facts
-- before raw-turn previews; get_memory_story/open_memory re-hydrate the
-- verbatim experience (source turns, pre-gist full text, superseded
-- originals) behind any memory. Baseline mirrors: db/31, db/38, db/39,
-- db/62, db/40 (regenerated).
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('memory.history_browse_max', '200'::jsonb,
     'Row ceiling for keyword-less time-window browsing in search_history (preview-grain rows)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION search_cross_session_history(
    p_query TEXT,
    p_limit INT DEFAULT 20,
    p_sources TEXT[] DEFAULT ARRAY['turn', 'memory']::TEXT[],
    p_created_after TIMESTAMPTZ DEFAULT NULL,
    p_created_before TIMESTAMPTZ DEFAULT NULL,
    p_exclude_session_id UUID DEFAULT NULL
) RETURNS TABLE (
    source_kind TEXT,
    item_id UUID,
    session_id UUID,
    content TEXT,
    user_text TEXT,
    assistant_text TEXT,
    memory_type TEXT,
    occurred_at TIMESTAMPTZ,
    rank FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    metadata JSONB
) AS $$
DECLARE
    -- Browse mode (#68): a time window with no keywords means "everything in
    -- the window, newest first" — '*' and '' count as no keywords. Without a
    -- window either, there is nothing to anchor on and we return empty.
    browse_mode BOOLEAN :=
        NULLIF(trim(COALESCE(p_query, '')), '') IS NULL
        OR trim(COALESCE(p_query, '')) = '*';
    -- Preview-grain rows are cheap, so browse affords a higher ceiling (#76).
    browse_cap INT := CASE
        WHEN NULLIF(trim(COALESCE(p_query, '')), '') IS NULL
          OR trim(COALESCE(p_query, '')) = '*'
        THEN GREATEST(COALESCE(get_config_int('memory.history_browse_max'), 200), 1)
        ELSE 100 END;
BEGIN
    IF browse_mode AND p_created_after IS NULL AND p_created_before IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH query_doc AS (
        SELECT websearch_to_tsquery('english', CASE WHEN browse_mode THEN '' ELSE p_query END) AS query
    ),
    turn_hits AS (
        SELECT
            'turn'::TEXT AS source_kind,
            s.id AS item_id,
            s.session_id,
            -- Browse grain (#76): a timeline scan reads previews, not
            -- transcripts — open_memory / a keyword search fetch verbatim.
            CASE WHEN browse_mode AND length(s.content) > 280
                 THEN left(s.content, 280) || ' …'
                 ELSE s.content END AS content,
            -- The content preview IS the browse surface: the raw halves stay
            -- home, or a 200-row page still weighs a megabyte.
            CASE WHEN browse_mode THEN NULL ELSE s.user_text END AS user_text,
            CASE WHEN browse_mode THEN NULL ELSE s.assistant_text END AS assistant_text,
            NULL::TEXT AS memory_type,
            s.turn_at AS occurred_at,
            CASE WHEN browse_mode THEN 0.0 ELSE ts_rank_cd(to_tsvector('english', s.content), q.query, 32) END::FLOAT AS rank,
            ARRAY[s.id]::UUID[] AS source_unit_ids,
            s.source_attribution,
            s.metadata
        FROM subconscious_units s
        CROSS JOIN query_doc q
        WHERE 'turn' = ANY(COALESCE(p_sources, ARRAY['turn', 'memory']::TEXT[]))
          AND (browse_mode OR numnode(q.query) > 0)
          AND s.status = 'active'
          AND (p_exclude_session_id IS NULL OR s.session_id IS DISTINCT FROM p_exclude_session_id)
          AND (p_created_after IS NULL OR s.turn_at >= p_created_after)
          AND (p_created_before IS NULL OR s.turn_at < p_created_before)
          AND (browse_mode OR to_tsvector('english', s.content) @@ q.query)
        ORDER BY rank DESC, occurred_at DESC, item_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), browse_cap)
    ),
    memory_hits AS (
        SELECT
            'memory'::TEXT AS source_kind,
            m.id AS item_id,
            (
                SELECT su.session_id
                FROM memory_source_units msu
                JOIN subconscious_units su ON su.id = msu.subconscious_unit_id
                WHERE msu.memory_id = m.id AND su.session_id IS NOT NULL
                ORDER BY su.turn_at DESC, su.id
                LIMIT 1
            ) AS session_id,
            m.content,
            NULL::TEXT AS user_text,
            NULL::TEXT AS assistant_text,
            m.type::TEXT AS memory_type,
            m.created_at AS occurred_at,
            CASE WHEN browse_mode THEN 0.0 ELSE ts_rank_cd(to_tsvector('english', m.content), q.query, 32) END::FLOAT AS rank,
            COALESCE(
                (
                    SELECT array_agg(msu.subconscious_unit_id ORDER BY msu.created_at, msu.subconscious_unit_id)
                    FROM memory_source_units msu
                    WHERE msu.memory_id = m.id
                ),
                '{}'::UUID[]
            ) AS source_unit_ids,
            m.source_attribution,
            m.metadata
        FROM memories m
        CROSS JOIN query_doc q
        WHERE 'memory' = ANY(COALESCE(p_sources, ARRAY['turn', 'memory']::TEXT[]))
          AND (browse_mode OR numnode(q.query) > 0)
          AND m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND (p_created_after IS NULL OR m.created_at >= p_created_after)
          AND (p_created_before IS NULL OR m.created_at < p_created_before)
          AND (browse_mode OR to_tsvector('english', m.content) @@ q.query)
        ORDER BY rank DESC, occurred_at DESC, item_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), browse_cap)
    )
    SELECT hits.*
    FROM (
        SELECT * FROM turn_hits
        UNION ALL
        SELECT * FROM memory_hits
    ) hits
    ORDER BY hits.rank DESC, hits.occurred_at DESC, hits.source_kind, hits.item_id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), browse_cap);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION render_chat_memory_context(
    p jsonb, p_max_memories int DEFAULT 5, p_max_partials int DEFAULT 3
) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    parts text[] := ARRAY[]::text[];
    memories jsonb;
    any_tier boolean;
    tier_name text;
    tier_title text;
    grp text;
    es jsonb;
    goals jsonb;
    all_goals jsonb;
    low_viv numeric := COALESCE(get_config_float('memory.recall_low_vividness_threshold'), 0.35);
    cue numeric := COALESCE(get_config_float('memory.recall_emotion_cue_threshold'), 0.4);
BEGIN
    p := COALESCE(p, '{}'::jsonb);
    memories := CASE WHEN jsonb_typeof(p->'memories') = 'array' THEN p->'memories' ELSE '[]'::jsonb END;

    IF jsonb_array_length(memories) > 0 THEN
        any_tier := EXISTS (SELECT 1 FROM jsonb_array_elements(memories) x WHERE NULLIF(x->>'tier', '') IS NOT NULL);
        IF any_tier THEN
            -- Gist-first (#76): consolidated scenes and distilled facts lead;
            -- raw turns close the section as previews — open_memory or a
            -- keyword search fetch the verbatim moment when it matters.
            FOREACH tier_name IN ARRAY ARRAY['episodic', 'semantic', '__none__', 'subconscious'] LOOP
                tier_title := CASE tier_name
                    WHEN 'subconscious' THEN '## Subconscious Raw Turns (previews)'
                    WHEN 'episodic' THEN '## Episodic Memories'
                    WHEN 'semantic' THEN '## Semantic Facts'
                    ELSE '## Relevant Memories' END;
                SELECT string_agg(
                    _pr_mem_line(
                        CASE WHEN tier_name = 'subconscious'
                                  AND length(COALESCE(capped.m->>'content', '')) > 300
                             THEN jsonb_set(capped.m, '{content}',
                                            to_jsonb(left(capped.m->>'content', 300) || ' …'))
                             ELSE capped.m END,
                        false, low_viv, cue),
                    E'\n' ORDER BY ord)
                INTO grp
                FROM (SELECT m, ord FROM jsonb_array_elements(memories) WITH ORDINALITY AS t(m, ord)
                      ORDER BY ord LIMIT p_max_memories) capped
                WHERE (tier_name <> '__none__' AND capped.m->>'tier' = tier_name)
                   OR (tier_name = '__none__' AND NULLIF(capped.m->>'tier', '') IS NULL);
                IF grp IS NOT NULL THEN
                    parts := parts || tier_title;
                    parts := parts || grp;
                END IF;
            END LOOP;
        ELSE
            parts := parts || '## Relevant Memories'::text;
            SELECT string_agg(_pr_mem_line(m, true, low_viv, cue), E'\n' ORDER BY ord)
            INTO grp
            FROM (SELECT m, ord FROM jsonb_array_elements(memories) WITH ORDINALITY AS t(m, ord)
                  ORDER BY ord LIMIT p_max_memories) capped;
            parts := parts || grp;
        END IF;
    END IF;

    -- Knowledge subgraph (how the recalled memories connect)
    IF jsonb_typeof(p->'subgraph') = 'object' THEN
        grp := _pr_chat_subgraph(p->'subgraph');
        IF grp IS NOT NULL THEN
            parts := parts || E'\n## Knowledge Subgraph'::text;
            parts := parts || 'How the recalled memories connect (typed links among + around them):'::text;
            parts := parts || grp;
        END IF;
    END IF;

    -- Partial activations (tip-of-tongue)
    IF jsonb_typeof(p->'partial_activations') = 'array' AND jsonb_array_length(p->'partial_activations') > 0 THEN
        parts := parts || E'\n## Vague Recollections (tip-of-tongue)'::text;
        parts := parts || (
            SELECT string_agg(
                '- Theme ''' || COALESCE(pa->>'cluster_name', '') || ''': ' ||
                COALESCE(NULLIF((
                    SELECT string_agg(kw #>> '{}', ', ' ORDER BY kord)
                    FROM (SELECT kw, kord FROM jsonb_array_elements(
                            CASE WHEN jsonb_typeof(pa->'keywords') = 'array' THEN pa->'keywords' ELSE '[]'::jsonb END
                          ) WITH ORDINALITY AS k(kw, kord) ORDER BY kord LIMIT 5) kk
                ), ''), 'unknown'),
                E'\n' ORDER BY ord)
            FROM (SELECT pa, ord FROM jsonb_array_elements(p->'partial_activations') WITH ORDINALITY AS t(pa, ord)
                  ORDER BY ord LIMIT p_max_partials) cp);
    END IF;

    -- Identity[:3]
    IF jsonb_typeof(p->'identity') = 'array' AND jsonb_array_length(p->'identity') > 0 THEN
        parts := parts || E'\n## Identity'::text;
        parts := parts || (
            SELECT string_agg(
                '- ' || COALESCE(NULLIF(a->>'type', ''), NULLIF(a->>'aspect_type', ''), 'unknown')
                || ': ' || COALESCE(a->>'concept', a->>'content', '')
                || CASE WHEN _pr_is_num(a->'strength') THEN ' (' || _pr_f((a->>'strength')::numeric, 1) || ')' ELSE '' END,
                E'\n' ORDER BY ord)
            FROM (SELECT a, ord FROM jsonb_array_elements(p->'identity') WITH ORDINALITY AS t(a, ord)
                  ORDER BY ord LIMIT 3) ci);
    END IF;

    -- Beliefs[:3]
    IF jsonb_typeof(p->'worldview') = 'array' AND jsonb_array_length(p->'worldview') > 0 THEN
        parts := parts || E'\n## Beliefs'::text;
        parts := parts || (
            SELECT string_agg(
                '- ' || COALESCE(b->>'belief', '') || ' (confidence: '
                || _pr_f(COALESCE(CASE WHEN _pr_is_num(b->'confidence') THEN (b->>'confidence')::numeric END, 0), 1) || ')',
                E'\n' ORDER BY ord)
            FROM (SELECT b, ord FROM jsonb_array_elements(p->'worldview') WITH ORDINALITY AS t(b, ord)
                  ORDER BY ord LIMIT 3) cb);
    END IF;

    -- Emotional state (dict truthy)
    es := p->'emotional_state';
    IF jsonb_typeof(COALESCE(es, 'null'::jsonb)) = 'object' AND es <> '{}'::jsonb THEN
        parts := parts || E'\n## Current Emotional State'::text;
        parts := parts || ('- Feeling: ' || COALESCE(es->>'primary_emotion', 'neutral'));
        parts := parts || ('- Valence: '
            || _pr_f(COALESCE(CASE WHEN _pr_is_num(es->'valence') THEN (es->>'valence')::numeric END, 0))
            || ', Arousal: '
            || _pr_f(COALESCE(CASE WHEN _pr_is_num(es->'arousal') THEN (es->>'arousal')::numeric END, 0.5)));
    END IF;

    -- Goals (active + queued)[:5]
    goals := CASE WHEN jsonb_typeof(p->'goals') = 'object' THEN p->'goals' ELSE '{}'::jsonb END;
    all_goals := (CASE WHEN jsonb_typeof(goals->'active') = 'array' THEN goals->'active' ELSE '[]'::jsonb END)
               || (CASE WHEN jsonb_typeof(goals->'queued') = 'array' THEN goals->'queued' ELSE '[]'::jsonb END);
    IF jsonb_array_length(all_goals) > 0 THEN
        parts := parts || E'\n## Goals'::text;
        parts := parts || (
            SELECT string_agg(
                '- ' || COALESCE(g->>'title', '')
                || CASE WHEN NULLIF(g->>'source', '') IS NOT NULL THEN ' (source: ' || (g->>'source') || ')' ELSE '' END,
                E'\n' ORDER BY ord)
            FROM (SELECT g, ord FROM jsonb_array_elements(all_goals) WITH ORDINALITY AS t(g, ord)
                  ORDER BY ord LIMIT 5) cg);
    END IF;

    -- Urgent drives (no limit)
    IF jsonb_typeof(p->'urgent_drives') = 'array' AND jsonb_array_length(p->'urgent_drives') > 0 THEN
        parts := parts || E'\n## Urgent Drives'::text;
        parts := parts || (
            SELECT string_agg(
                CASE WHEN _pr_is_num(d->'urgency_ratio')
                     THEN '- ' || COALESCE(d->>'name', '') || ': ' || _pr_pct((d->>'urgency_ratio')::numeric, 1) || ' urgent'
                     ELSE '- ' || COALESCE(d->>'name', '') || ': ' || COALESCE(d->>'level', '') END,
                E'\n' ORDER BY ord)
            FROM jsonb_array_elements(p->'urgent_drives') WITH ORDINALITY AS t(d, ord));
    END IF;

    RETURN COALESCE(array_to_string(parts, E'\n'), '');
END;
$$;

CREATE OR REPLACE FUNCTION get_memory_story(
    p_memory_id UUID,
    p_max_units INT DEFAULT 40
) RETURNS JSONB AS $$
DECLARE
    mem RECORD;
    units JSONB;
    gisted_members JSONB;
BEGIN
    SELECT id, type, content, importance, trust_level, fidelity, status,
           created_at, superseded_by, metadata
    INTO mem
    FROM memories WHERE id = p_memory_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'role', u.role,
        'turn_at', u.turn_at,
        'content', u.content
    ) ORDER BY u.turn_at, u.created_at), '[]'::jsonb)
    INTO units
    FROM (
        SELECT s.id, msu.role, s.turn_at, s.created_at, s.content
        FROM memory_source_units msu
        JOIN subconscious_units s ON s.id = msu.subconscious_unit_id
        WHERE msu.memory_id = p_memory_id
          AND s.status = 'active'
        ORDER BY s.turn_at, s.created_at
        LIMIT GREATEST(COALESCE(p_max_units, 40), 1)
    ) u;

    -- A retention gist supersedes its members: opening the gist also opens
    -- the archived originals (still present through the grace window).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'memory_id', g.id,
        'content', g.content,
        'created_at', g.created_at
    ) ORDER BY g.created_at), '[]'::jsonb)
    INTO gisted_members
    FROM memories g
    WHERE g.superseded_by = p_memory_id;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'memory', jsonb_build_object(
            'id', mem.id,
            'type', mem.type,
            'content', mem.content,
            'importance', mem.importance,
            'confidence', NULLIF(mem.metadata->>'confidence', '')::float,
            'trust_level', mem.trust_level,
            'fidelity', mem.fidelity,
            'status', mem.status,
            'created_at', mem.created_at,
            'occurred_from', mem.metadata#>>'{recmem,occurred_from}',
            'occurred_to', mem.metadata#>>'{recmem,occurred_to}',
            'session_id', mem.metadata#>>'{recmem,session_id}'
        ),
        'full_content', NULLIF(mem.metadata#>>'{consolidation,full_content}', ''),
        'source_units', units,
        'superseded_members', CASE WHEN gisted_members = '[]'::jsonb THEN NULL ELSE gisted_members END,
        'superseded_by', mem.superseded_by,
        'evidence', jsonb_build_object(
            'revisions', (SELECT count(*) FROM belief_revision_audit b WHERE b.memory_id = p_memory_id),
            'supports', (SELECT count(*) FROM memory_edges e
                         WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'SUPPORTS'),
            'contradicts', (SELECT count(*) FROM memory_edges e
                            WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'CONTRADICTS')
        )
    ));
END;
$$ LANGUAGE plpgsql STABLE;

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
    ELSIF p_tool_name = 'open_memory' THEN
        -- Graded recall's drill-down (#76): the verbatim experience behind a
        -- gist — source units time-ordered, pre-summary full text, members a
        -- retention gist superseded.
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        revision := get_memory_story(target_id, COALESCE(NULLIF(p_args->>'max_units', '')::int, 40));
        IF revision->>'error' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        END IF;
        display := format('Opened memory: %s source unit(s)%s%s',
            jsonb_array_length(COALESCE(revision->'source_units', '[]'::jsonb)),
            CASE WHEN revision ? 'full_content' THEN ', pre-gist full text preserved' ELSE '' END,
            CASE WHEN revision ? 'superseded_members'
                 THEN format(', %s gisted member(s)', jsonb_array_length(revision->'superseded_members'))
                 ELSE '' END);
        RETURN tool_success(revision, display);
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

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

**Graded recall — gist first, verbatim on demand:** `recall` gives you the shape of a memory (scenes, distilled facts, previews); `open_memory` with the memory's id gives you the verbatim moment underneath — the exact turns, the pre-summary full text of a gisted memory. Reach for it when precise wording, quotes, or the full exchange matter. When a `search_history` result says the page is full, the window holds more — page onward with `created_before` set to the oldest timestamp you received.

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
