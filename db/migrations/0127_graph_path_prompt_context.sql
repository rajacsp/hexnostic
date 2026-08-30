-- Surface causal/contradiction/support paths in rendered chat memory context.

CREATE OR REPLACE FUNCTION _pr_chat_context_paths(p_paths jsonb, p_subgraph jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    WITH nodes AS (
        SELECT (n->>'type') AS ntype, (n->>'id') AS nid,
               left(btrim(COALESCE(NULLIF(n->>'label', ''), NULLIF(n->>'id', ''), '')), 72) AS label
        FROM jsonb_array_elements(_pr_arr(p_subgraph->'nodes')) n
        WHERE jsonb_typeof(n) = 'object'
    ),
    path_docs AS (
        SELECT path_doc, doc_ord
        FROM jsonb_array_elements(_pr_arr(p_paths->'paths')) WITH ORDINALITY AS d(path_doc, doc_ord)
        WHERE jsonb_typeof(path_doc) = 'object'
        ORDER BY doc_ord
        LIMIT 8
    ),
    path_rows AS (
        SELECT path_doc, doc_ord, path_obj, path_ord
        FROM path_docs
        CROSS JOIN LATERAL jsonb_array_elements(_pr_arr(path_doc->'paths')) WITH ORDINALITY AS p(path_obj, path_ord)
        WHERE jsonb_typeof(path_obj) = 'object'
          AND jsonb_array_length(_pr_arr(path_obj->'edges')) > 0
        ORDER BY doc_ord, path_ord
        LIMIT 12
    ),
    edge_rows AS (
        SELECT pr.doc_ord, pr.path_ord, edge_obj, edge_ord,
               edge_obj->>'src_type' AS src_type,
               edge_obj->>'src_id' AS src_id,
               edge_obj->>'dst_type' AS dst_type,
               edge_obj->>'dst_id' AS dst_id,
               CASE WHEN lower(COALESCE(edge_obj->>'rel', '')) = 'instance_of' THEN 'mentions'
                    ELSE lower(COALESCE(NULLIF(edge_obj->>'rel', ''), 'related')) END AS rel
        FROM path_rows pr
        CROSS JOIN LATERAL jsonb_array_elements(_pr_arr(pr.path_obj->'edges')) WITH ORDINALITY AS e(edge_obj, edge_ord)
        WHERE jsonb_typeof(edge_obj) = 'object'
    ),
    segments AS (
        SELECT er.doc_ord, er.path_ord, er.edge_ord,
               COALESCE(ns.label, left(NULLIF(er.src_id, ''), 8), 'unknown') AS src_label,
               COALESCE(nd.label, left(NULLIF(er.dst_id, ''), 8), 'unknown') AS dst_label,
               er.rel
        FROM edge_rows er
        LEFT JOIN nodes ns ON ns.ntype = er.src_type AND ns.nid = er.src_id
        LEFT JOIN nodes nd ON nd.ntype = er.dst_type AND nd.nid = er.dst_id
    ),
    lines AS (
        SELECT doc_ord, path_ord,
               string_agg(
                   CASE WHEN edge_ord = 1
                        THEN src_label || '  —' || rel || '→  ' || dst_label
                        ELSE '—' || rel || '→  ' || dst_label
                   END,
                   ' ' ORDER BY edge_ord
               ) AS line
        FROM segments
        GROUP BY doc_ord, path_ord
    )
    SELECT string_agg('- ' || line, E'\n' ORDER BY doc_ord, path_ord)
    FROM lines
    WHERE NULLIF(line, '') IS NOT NULL;
$$;

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

    -- Directed reasoning paths (causal/contradiction/support/supersession)
    IF jsonb_typeof(p->'context_paths') = 'object' THEN
        grp := _pr_chat_context_paths(p->'context_paths', p->'subgraph');
        IF grp IS NOT NULL THEN
            parts := parts || E'\n## Causal/Contradiction Paths'::text;
            parts := parts || 'Focused chains among recalled memories:'::text;
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
