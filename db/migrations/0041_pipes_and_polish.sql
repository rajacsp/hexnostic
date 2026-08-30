-- 0041: Fix the pipes (#67 #68 #69 #70 #72, Tranche 2 of the stress-test plan).
-- search_cross_session_history gains browse mode (a time window with no
-- keywords returns the window newest-first — "what happened yesterday" was
-- unanswerable with 110 records present); the gut reaction truncates at a
-- sentence boundary instead of a mid-word left(…,200); character-card
-- {{user}}/{{char}} macros resolve at render time and the guardrail learns
-- correction claims; the ## Now line carries day-of-life; subgraph rendering
-- shows memory→concept links as "mentions".
-- Baseline mirrors: db/31, db/39, db/58 (seed), db/62, db/07.
SET search_path = public, ag_catalog, "$user";

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
            s.content,
            s.user_text,
            s.assistant_text,
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
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
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
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    )
    SELECT hits.*
    FROM (
        SELECT * FROM turn_hits
        UNION ALL
        SELECT * FROM memory_hits
    ) hits
    ORDER BY hits.rank DESC, hits.occurred_at DESC, hits.source_kind, hits.item_id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION render_subconscious_signals(p jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    parts text[] := ARRAY['## Subconscious Signals'];
    es jsonb;
    queries text[];
    tmp text;
BEGIN
    p := COALESCE(p, '{}'::jsonb);

    -- instincts[:3]
    IF jsonb_typeof(p->'instincts') = 'array' AND jsonb_array_length(p->'instincts') > 0 THEN
        parts := parts || (
            SELECT array_agg(
                '- Instinct: ' || COALESCE(i->>'impulse', 'unknown')
                || ' (' || _pr_f(COALESCE(CASE WHEN _pr_is_num(i->'intensity') THEN (i->>'intensity')::numeric END, 0), 1)
                || ') — ' || COALESCE(i->>'reason', '') ORDER BY ord)
            FROM (SELECT i, ord FROM jsonb_array_elements(p->'instincts') WITH ORDINALITY AS t(i, ord)
                  ORDER BY ord LIMIT 3) ci);
    END IF;

    -- emotional_state (raw numbers, not fixed-precision — mirrors the Python f-string)
    es := p->'emotional_state';
    IF jsonb_typeof(COALESCE(es, 'null'::jsonb)) = 'object' AND es <> '{}'::jsonb THEN
        parts := parts || ('- Emotional state: ' || COALESCE(es->>'primary_emotion', 'neutral')
            || ' (valence: ' || COALESCE(es->>'valence', '0')
            || ', arousal: ' || COALESCE(es->>'arousal', '0') || ')');
    END IF;

    -- memory_expansions[:3] with non-empty query, quoted like Python repr()
    IF jsonb_typeof(p->'memory_expansions') = 'array' THEN
        SELECT array_agg('''' || q || '''' ORDER BY ord)
        INTO queries
        FROM (SELECT me->>'query' AS q, ord
              FROM jsonb_array_elements(p->'memory_expansions') WITH ORDINALITY AS t(me, ord)
              ORDER BY ord LIMIT 3) ce
        WHERE NULLIF(q, '') IS NOT NULL;
        IF array_length(queries, 1) IS NOT NULL THEN
            parts := parts || ('- Suggested memory searches: ' || array_to_string(queries, ', '));
        END IF;
    END IF;

    -- salient_memories[:3]
    IF jsonb_typeof(p->'salient_memories') = 'array' AND jsonb_array_length(p->'salient_memories') > 0 THEN
        parts := parts || (
            SELECT array_agg(
                '- Salient memory: [' || COALESCE(sm->>'memory_id', '?') || '] (' || COALESCE(sm->>'reason', '') || ')'
                ORDER BY ord)
            FROM (SELECT sm, ord FROM jsonb_array_elements(p->'salient_memories') WITH ORDINALITY AS t(sm, ord)
                  ORDER BY ord LIMIT 3) cs);
    END IF;

    -- Gut reaction, truncated at a sentence boundary (#69): the old hard
    -- left(…,200) amputated the most intense reactions mid-word — exactly the
    -- turns where the gut line matters most.
    tmp := COALESCE(p->>'subconscious_response', '');
    IF tmp <> '' THEN
        IF length(tmp) > 600 THEN
            tmp := COALESCE(substring(left(tmp, 600) from '^.*[.!?]'), left(tmp, 600) || '…');
        END IF;
        parts := parts || ('- Gut reaction: ' || tmp);
    END IF;

    IF array_length(parts, 1) <= 1 THEN RETURN ''; END IF;
    RETURN array_to_string(parts, E'\n');
END;
$$;

CREATE OR REPLACE FUNCTION _pr_chat_subgraph(p jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    WITH nodes AS (
        SELECT (n->>'type') AS ntype, (n->>'id') AS nid,
               left(btrim(COALESCE(NULLIF(n->>'label', ''), NULLIF(n->>'id', ''), '')), 80) AS label
        FROM jsonb_array_elements(_pr_arr(p->'nodes')) n
        WHERE jsonb_typeof(n) = 'object'
    ),
    edges AS (
        SELECT (e->>'src_type') AS st, (e->>'src_id') AS si,
               (e->>'dst_type') AS dt, (e->>'dst_id') AS di,
               -- Memory→concept links are typed INSTANCE_OF mechanically
               -- (db/05 link plumbing); rendered literally, "statement
               -- instance_of person" reads as broken ontology (#72) — what
               -- the link means is "mentions".
               CASE WHEN lower(COALESCE(e->>'rel', '')) = 'instance_of' THEN 'mentions'
                    ELSE lower(COALESCE(NULLIF(e->>'rel', ''), 'related')) END AS rel,
               COALESCE(e->>'rel', '') AS rel_key
        FROM jsonb_array_elements(_pr_arr(p->'edges')) e
        WHERE jsonb_typeof(e) = 'object'
        ORDER BY COALESCE(e->>'rel', ''), COALESCE(e->>'src_id', '')
        LIMIT 20
    )
    SELECT string_agg(
        '- ' || COALESCE(ns.label, e.si) || '  —' || e.rel || '→  ' || COALESCE(nd.label, e.di),
        E'\n' ORDER BY e.rel_key, e.si)
    FROM edges e
    LEFT JOIN nodes ns ON ns.ntype = e.st AND ns.nid = e.si
    LEFT JOIN nodes nd ON nd.ntype = e.dt AND nd.nid = e.di;
$$;

CREATE OR REPLACE FUNCTION get_temporal_context()
RETURNS JSONB AS $$
DECLARE
    tz TEXT := COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC');
    now_local TIMESTAMP;
    born TIMESTAMPTZ;
BEGIN
    BEGIN
        now_local := CURRENT_TIMESTAMP AT TIME ZONE tz;
    EXCEPTION WHEN OTHERS THEN
        tz := 'UTC';
        now_local := CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
    END;

    SELECT min(created_at) INTO born
    FROM memories
    WHERE type = 'episodic' AND metadata->>'type' = 'initialization';
    IF born IS NULL THEN
        SELECT min(created_at) INTO born FROM memories;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'now', to_char(now_local, 'FMDay, FMMonth DD, YYYY, HH24:MI'),
        'timezone', tz,
        'born_on', CASE WHEN born IS NOT NULL
                        THEN to_char(born AT TIME ZONE tz, 'FMMonth DD, YYYY') END,
        -- Calendar day-of-life (#72): "day 7" reconciles with date arithmetic
        -- at a glance; floored elapsed days ("5 day(s) ago" on the 7th
        -- calendar day) read as a contradiction the agent then distrusts.
        'day_of_life', CASE WHEN born IS NOT NULL
                            THEN ((now_local::date - (born AT TIME ZONE tz)::date) + 1) END,
        'age_days', CASE WHEN born IS NOT NULL
                         THEN GREATEST(0, EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - born))::bigint / 86400) END
    ));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION _resolve_card_macros(
    p_value JSONB,
    p_char_name TEXT,
    p_user_name TEXT
) RETURNS JSONB AS $$
DECLARE
    txt TEXT;
BEGIN
    IF p_value IS NULL OR jsonb_typeof(p_value) <> 'string' THEN
        RETURN p_value;
    END IF;
    txt := p_value #>> '{}';
    txt := regexp_replace(txt, '\{\{char\}\}', COALESCE(NULLIF(p_char_name, ''), 'the character'), 'gi');
    txt := regexp_replace(txt, '\{\{user\}\}', COALESCE(NULLIF(p_user_name, ''), 'the person you''re speaking with'), 'gi');
    RETURN to_jsonb(txt);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION get_agent_profile_context()
RETURNS JSONB AS $$
DECLARE
    init_profile JSONB := COALESCE(get_config('agent.init_profile'), '{}'::jsonb);
    agent JSONB;
    card_data JSONB;
    narrative TEXT;
    persona JSONB;
    char_name TEXT;
    user_name TEXT;
BEGIN
    agent := COALESCE(init_profile->'agent', '{}'::jsonb);
    card_data := COALESCE(init_profile#>'{character_card,data}', '{}'::jsonb);
    char_name := COALESCE(NULLIF(agent->>'name', ''), NULLIF(card_data->>'name', ''));
    user_name := COALESCE(
        NULLIF(init_profile#>>'{relationship,name}', ''),
        NULLIF(init_profile#>>'{user,name}', ''));
    SELECT m.content
    INTO narrative
    FROM memories m
    WHERE m.type = 'worldview'
      AND m.status = 'active'
      AND m.metadata->>'origin' = 'initialization'
      AND m.metadata->>'subcategory' = 'narrative'
      AND m.metadata->>'attribute' = 'foundational'
    ORDER BY m.created_at DESC
    LIMIT 1;

    persona := jsonb_strip_nulls(jsonb_build_object(
        'name', agent->'name',
        'pronouns', agent->'pronouns',
        'voice', agent->'voice',
        'description', agent->'description',
        'personality', agent->'personality',
        'purpose', agent->'purpose',
        'values', init_profile->'values',
        'worldview', init_profile->'worldview',
        'boundaries', init_profile->'boundaries',
        'interests', init_profile->'interests',
        'relationship', init_profile->'relationship',
        'relationship_aspiration', init_profile->'relationship_aspiration',
        'character_description', _resolve_card_macros(card_data->'description', char_name, user_name),
        'character_personality', _resolve_card_macros(card_data->'personality', char_name, user_name),
        'scenario', _resolve_card_macros(card_data->'scenario', char_name, user_name),
        'character_instructions', _resolve_card_macros(card_data->'system_prompt', char_name, user_name),
        'post_history_instructions', _resolve_card_macros(card_data->'post_history_instructions', char_name, user_name),
        'example_dialogue', _resolve_card_macros(card_data->'mes_example', char_name, user_name),
        'narrative', to_jsonb(narrative)
    ));

    RETURN jsonb_build_object(
        'objectives', COALESCE(get_config('agent.objectives'), '[]'::jsonb),
        'budget', COALESCE(get_config('agent.budget'), '{}'::jsonb),
        'guardrails', COALESCE(get_config('agent.guardrails'), '[]'::jsonb),
        'tools', COALESCE(get_config('agent.tools'), '[]'::jsonb),
        'initial_message', COALESCE(get_config('agent.initial_message'), to_jsonb(''::text)),
        'persona', persona
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Correction claims (#67): "I've corrected that in my memory" is only
-- supported by a revision-class action.
INSERT INTO action_claim_patterns (claim_kind, pattern, satisfied_by_tools, require_arg_key, notes)
SELECT v.claim_kind, v.pattern, v.satisfied_by_tools, v.require_arg_key, v.notes
FROM (VALUES
    ('memory_correction',
     '\mI(''ve| have)? ?((just|also|already|now|then) )?(corrected|revised|updated|amended|fixed|reattributed|retracted) [^.!?]*(attribut|belief|record|memor|confidence|the fact)',
     ARRAY['add_evidence'],
     NULL,
     'memory-correction claims require a belief revision, not just any memory write')
) AS v(claim_kind, pattern, satisfied_by_tools, require_arg_key, notes)
WHERE NOT EXISTS (
    SELECT 1 FROM action_claim_patterns p
    WHERE p.claim_kind = v.claim_kind AND p.pattern = v.pattern
);
