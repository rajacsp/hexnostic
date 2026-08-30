-- The chat memory-context renderer gains the recall-hedge and
-- felt-emotion-cue prefixes (config thresholds) and the knowledge-subgraph
-- section, replacing the deleted Python format_context_for_prompt.
-- Mirrors db/39_functions_prompt_render.sql.

SET check_function_bodies = off;

-- One memory line for the chat context (score/trust always; source only in the
-- non-tiered branch). A faint memory renders as a hedged reconstruction and a
-- memory with signed felt intensity gets an emotion cue; thresholds come from
-- config (memory.recall_low_vividness_threshold / recall_emotion_cue_threshold).
DROP FUNCTION IF EXISTS _pr_mem_line(jsonb, boolean);
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

-- Chat-context subgraph lines: '- A  —rel→  B', edges sorted by (rel, src_id)
-- and capped at 20, node labels trimmed to 80 chars, missing rel reads
-- 'related'. NULL when there are no edges (section is skipped).
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
               lower(COALESCE(NULLIF(e->>'rel', ''), 'related')) AS rel,
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

-- The chat memory context renderer (the deleted Python
-- format_context_for_prompt's output is pinned by golden fixtures).
-- STABLE, not IMMUTABLE: hedge/emotion-cue thresholds come from config.
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
            FOREACH tier_name IN ARRAY ARRAY['subconscious', 'episodic', 'semantic', '__none__'] LOOP
                tier_title := CASE tier_name
                    WHEN 'subconscious' THEN '## Subconscious Raw Turns'
                    WHEN 'episodic' THEN '## Episodic Memories'
                    WHEN 'semantic' THEN '## Semantic Facts'
                    ELSE '## Relevant Memories' END;
                SELECT string_agg(_pr_mem_line(m, false, low_viv, cue), E'\n' ORDER BY ord)
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

SET check_function_bodies = on;
