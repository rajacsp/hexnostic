-- Read-shaper pushdown (plans/db_pushdown.md 3.12): explore_concept,
-- explore_subgraph, get_procedures, get_strategies join execute_memory_tool
-- (this also FIXES get_procedures/get_strategies, which filtered on a
-- column fast_recall does not return and errored on every call), and
-- aggregate_signals / query_usage become envelope-returning SQL.
SET search_path = public, ag_catalog, "$user";

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
    after_ts TIMESTAMPTZ;
    before_ts TIMESTAMPTZ;
    history_sources TEXT[];
    history_browse BOOLEAN;
    oldest_ts TIMESTAMPTZ;
    type_filter_uuids UUID[];
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
    ELSIF p_tool_name = 'search_history' THEN
        -- Cross-session lexical/timeline search: validation, browse-vs-keyword
        -- limit policy, and the loud-truncation paging hint all live here.
        query := trim(COALESCE(p_args->>'query', ''));
        BEGIN
            after_ts := NULLIF(p_args->>'created_after', '')::timestamptz;
            before_ts := NULLIF(p_args->>'created_before', '')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            RETURN tool_error('created_after/created_before must be ISO-8601 timestamps', 'invalid_params');
        END;
        IF after_ts IS NOT NULL AND before_ts IS NOT NULL AND after_ts >= before_ts THEN
            RETURN tool_error('created_after must be earlier than created_before', 'invalid_params');
        END IF;
        history_browse := NULLIF(trim(BOTH '* ' FROM query), '') IS NULL;
        IF history_browse AND after_ts IS NULL AND before_ts IS NULL THEN
            RETURN tool_error('Provide query keywords, or a created_after/created_before window to browse a time range chronologically', 'invalid_params');
        END IF;
        IF p_args ? 'sources' THEN
            IF jsonb_typeof(p_args->'sources') <> 'array' OR jsonb_array_length(p_args->'sources') = 0 THEN
                RETURN tool_error('history search requires at least one source', 'invalid_params');
            END IF;
            SELECT array_agg(DISTINCT value) INTO history_sources
            FROM jsonb_array_elements_text(p_args->'sources') t(value);
            IF EXISTS (SELECT 1 FROM unnest(history_sources) s(v) WHERE v NOT IN ('turn', 'memory')) THEN
                RETURN tool_error(
                    'history search sources must be ''turn'' and/or ''memory''; invalid: '
                    || (SELECT string_agg(v, ', ' ORDER BY v) FROM unnest(history_sources) s(v) WHERE v NOT IN ('turn', 'memory')),
                    'invalid_params');
            END IF;
        ELSE
            history_sources := ARRAY['turn', 'memory'];
        END IF;
        -- Browse mode reads preview-grain rows, so it affords the higher
        -- config-owned ceiling (#76); keyword search stays at 50.
        limit_value := LEAST(
            GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 20), 1),
            CASE WHEN history_browse
                 THEN GREATEST(COALESCE(get_config_int('memory.history_browse_max'), 200), 1)
                 ELSE 50 END);
        WITH hits AS (
            SELECT h.*, ROW_NUMBER() OVER () AS ord
            FROM search_cross_session_history(
                query, limit_value, history_sources, after_ts, before_ts,
                _db_brain_try_uuid(p_args->>'exclude_session_id')) h
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'source_kind', h.source_kind,
                   'item_id', h.item_id::text,
                   'session_id', h.session_id::text,
                   'content', h.content,
                   'user_text', h.user_text,
                   'assistant_text', h.assistant_text,
                   'memory_type', h.memory_type,
                   'occurred_at', h.occurred_at,
                   'rank', h.rank,
                   'source_unit_ids', COALESCE((SELECT jsonb_agg(u::text) FROM unnest(h.source_unit_ids) u), '[]'::jsonb),
                   'source_attribution', h.source_attribution,
                   'metadata', h.metadata
               ) ORDER BY h.ord), '[]'::jsonb),
               min(h.occurred_at)
        INTO rows_json, oldest_ts
        FROM hits h;
        revision := jsonb_build_object(
            'query', query,
            'results', rows_json,
            'count', jsonb_array_length(rows_json),
            'limit', limit_value,
            -- Loud truncation (#76): a full page means the window holds
            -- more — silence here once read as "the morning was blank."
            'truncated', jsonb_array_length(rows_json) >= limit_value,
            'excluded_session_id', _db_brain_try_uuid(p_args->>'exclude_session_id')::text);
        IF jsonb_array_length(rows_json) > 0 AND jsonb_array_length(rows_json) >= limit_value THEN
            revision := revision || jsonb_build_object('note',
                'window truncated — older entries exist; page with created_before='
                || (to_jsonb(oldest_ts) #>> '{}'));
        END IF;
        RETURN tool_success(revision,
            format('Found %s history result(s)', jsonb_array_length(rows_json))
            || CASE WHEN jsonb_array_length(rows_json) >= limit_value
                    THEN ' (page full — more exist in this window)' ELSE '' END);
    ELSIF p_tool_name = 'explore_concept' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'concept', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('concept is required', 'invalid_params');
        END IF;
        limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 5), 1), 20);
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'memory_id', f.memory_id::text,
                   'content', f.memory_content,
                   'type', f.memory_type::text,
                   'importance', f.memory_importance,
                   'concept_strength', f.link_strength)), '[]'::jsonb)
        INTO rows_json
        FROM find_memories_by_concept(query, limit_value) f;
        revision := jsonb_build_object(
            'concept', query,
            'memories', rows_json,
            'related_concepts', '[]'::jsonb,
            'count', jsonb_array_length(rows_json));
        IF COALESCE(NULLIF(p_args->>'include_related', '')::boolean, TRUE)
           AND jsonb_array_length(rows_json) > 0 THEN
            revision := jsonb_set(revision, '{related_concepts}', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('name', r.name, 'shared_memories', r.shared_memories))
                FROM find_related_concepts_for_memories(
                    ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value),
                    query, 10) r), '[]'::jsonb));
        END IF;
        RETURN tool_success(revision,
            format('Found %s memories for concept ''%s''', jsonb_array_length(rows_json), query));
    ELSIF p_tool_name = 'explore_subgraph' THEN
        IF jsonb_typeof(p_args->'seeds') = 'array' AND jsonb_array_length(p_args->'seeds') > 0 THEN
            BEGIN
                SELECT array_agg(value::uuid) INTO type_filter_uuids
                FROM jsonb_array_elements_text(p_args->'seeds') t(value);
            EXCEPTION WHEN OTHERS THEN
                RETURN tool_error('seeds must be memory uuids', 'invalid_params');
            END;
        ELSIF NULLIF(btrim(COALESCE(p_args->>'query', '')), '') IS NOT NULL THEN
            SELECT array_agg(f.memory_id) INTO type_filter_uuids
            FROM fast_recall(p_args->>'query', 10) f;
        ELSE
            RETURN tool_error('Provide ''query'' or ''seeds''.', 'invalid_params');
        END IF;
        IF type_filter_uuids IS NULL OR cardinality(type_filter_uuids) = 0 THEN
            RETURN tool_success(
                '{"nodes": [], "edges": [], "rendered": null}'::jsonb,
                'No seed memories found.');
        END IF;
        revision := build_context_subgraph(
            type_filter_uuids,
            LEAST(GREATEST(COALESCE(NULLIF(p_args->>'depth', '')::int, 2), 1), 4),
            CASE WHEN jsonb_typeof(p_args->'rel_types') = 'array'
                 THEN ARRAY(SELECT jsonb_array_elements_text(p_args->'rel_types')) END,
            LEAST(GREATEST(COALESCE(NULLIF(p_args->>'budget', '')::int, 30), 1), 100));
        display := render_subgraph(revision);
        RETURN tool_success(jsonb_build_object(
                'nodes', COALESCE(revision->'nodes', '[]'::jsonb),
                'edges', COALESCE(revision->'edges', '[]'::jsonb),
                'rendered', display),
            COALESCE(display, format('No typed connections among %s seed memory(ies).',
                                     cardinality(type_filter_uuids))));
    ELSIF p_tool_name IN ('get_procedures', 'get_strategies') THEN
        -- fast_recall filtered to one memory type. (The former Python path
        -- filtered on a column fast_recall does not return, so these tools
        -- errored on every call — fixed here.)
        query := NULLIF(btrim(COALESCE(
            p_args->>'task', p_args->>'situation', p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error(
                CASE WHEN p_tool_name = 'get_procedures'
                     THEN 'task is required' ELSE 'situation is required' END,
                'invalid_params');
        END IF;
        limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 3), 1), 10);
        memory_type_value := CASE WHEN p_tool_name = 'get_procedures'
                                  THEN 'procedural' ELSE 'strategic' END;
        SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO rows_json FROM (
            SELECT jsonb_build_object(
                'memory_id', f.memory_id::text,
                'content', f.content,
                'similarity', f.score) AS item
            FROM fast_recall(query, limit_value * 2) f
            WHERE f.memory_type::text = memory_type_value
            LIMIT limit_value
        ) s;
        IF p_tool_name = 'get_procedures' THEN
            RETURN tool_success(
                jsonb_build_object('procedures', rows_json,
                                   'count', jsonb_array_length(rows_json), 'task', query),
                format('Found %s procedures for ''%s''', jsonb_array_length(rows_json), query));
        END IF;
        RETURN tool_success(
            jsonb_build_object('strategies', rows_json,
                               'count', jsonb_array_length(rows_json), 'situation', query),
            format('Found %s strategies for ''%s''', jsonb_array_length(rows_json), query));
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

-- Situational-awareness snapshot: gateway events + episodic memories +
-- active goals in one round trip.
CREATE OR REPLACE FUNCTION aggregate_signals_tool(
    p_args JSONB
) RETURNS JSONB AS $$
DECLARE
    domain TEXT := NULLIF(btrim(COALESCE(p_args->>'domain', '')), '');
    days INT := GREATEST(COALESCE(NULLIF(p_args->>'days', '')::int, 7), 1);
    lim INT := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 20), 1), 100);
    events JSONB;
    mems JSONB;
    goals JSONB;
    snapshot JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO events FROM (
        SELECT jsonb_build_object(
            'id', e.id,
            'source', e.source::text,
            'status', e.status::text,
            'session_key', e.session_key,
            'payload_keys', COALESCE((
                SELECT jsonb_agg(k) FROM jsonb_object_keys(
                    CASE WHEN jsonb_typeof(e.payload) = 'object'
                         THEN e.payload ELSE '{}'::jsonb END) k), '[]'::jsonb),
            'created_at', e.created_at) AS item
        FROM gateway_events e
        WHERE e.created_at >= now() - make_interval(days => days)
          AND (domain IS NULL OR e.source::text = domain)
        ORDER BY e.created_at DESC
        LIMIT lim
    ) s;

    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO mems FROM (
        SELECT jsonb_build_object(
            'id', m.id::text,
            'content', left(COALESCE(m.content, ''), 300),
            'importance', m.importance,
            'created_at', m.created_at) AS item
        FROM memories m
        WHERE m.type = 'episodic' AND m.status = 'active'
          AND m.created_at >= now() - make_interval(days => days)
        ORDER BY m.created_at DESC
        LIMIT lim
    ) s;

    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO goals FROM (
        SELECT jsonb_build_object(
            'id', m.id::text,
            'content', left(COALESCE(m.content, ''), 300),
            'importance', m.importance,
            'created_at', m.created_at) AS item
        FROM memories m
        WHERE m.type = 'goal' AND m.status = 'active'
        ORDER BY m.importance DESC NULLS LAST
        LIMIT lim
    ) s;

    snapshot := jsonb_build_object(
        'time_window_days', days,
        'domain_filter', domain,
        'events', jsonb_build_object('count', jsonb_array_length(events), 'items', events),
        'memories', jsonb_build_object('count', jsonb_array_length(mems), 'items', mems),
        'goals', jsonb_build_object('count', jsonb_array_length(goals), 'items', goals),
        'summary', jsonb_build_object(
            'total_signals', jsonb_array_length(events) + jsonb_array_length(mems) + jsonb_array_length(goals),
            'event_sources', COALESCE((
                SELECT jsonb_agg(DISTINCT value->>'source')
                FROM jsonb_array_elements(events) value), '[]'::jsonb),
            'highest_importance_goal',
                left(goals->0->>'content', 100)));
    RETURN tool_success(snapshot,
        format('Aggregated %s signal(s) over %s day(s)',
               jsonb_array_length(events) + jsonb_array_length(mems) + jsonb_array_length(goals),
               days));
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$ LANGUAGE plpgsql;

-- Usage/cost views over api_usage: summary, daily, top_models.
CREATE OR REPLACE FUNCTION query_usage_tool(
    p_args JSONB
) RETURNS JSONB AS $$
DECLARE
    period TEXT := COALESCE(NULLIF(p_args->>'period', ''), 'month');
    view_kind TEXT := COALESCE(NULLIF(p_args->>'view', ''), 'summary');
    source TEXT := NULLIF(btrim(COALESCE(p_args->>'source', '')), '');
    span INTERVAL := CASE period
        WHEN 'day' THEN INTERVAL '1 day'
        WHEN 'week' THEN INTERVAL '7 days'
        WHEN 'month' THEN INTERVAL '30 days'
        WHEN 'quarter' THEN INTERVAL '90 days'
        WHEN 'year' THEN INTERVAL '365 days'
        ELSE INTERVAL '30 days' END;
    rows_json JSONB;
    totals RECORD;
BEGIN
    IF view_kind = 'daily' THEN
        SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO rows_json FROM (
            SELECT jsonb_build_object(
                'date', d.day::text,
                'cost_usd', round(COALESCE(sum(d.total_cost), 0)::numeric, 4),
                'tokens', COALESCE(sum(d.total_tokens), 0),
                'calls', COALESCE(sum(d.call_count), 0)) AS item
            FROM usage_daily(span, source) d
            GROUP BY d.day
            ORDER BY d.day DESC
        ) s;
        RETURN tool_success(
            jsonb_build_object('period', period, 'daily', rows_json),
            format('Daily usage for last %s: %s day(s)', period, jsonb_array_length(rows_json)));
    ELSIF view_kind = 'top_models' THEN
        SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO rows_json FROM (
            SELECT jsonb_build_object(
                'model', u.provider || '/' || u.model,
                'cost_usd', round(COALESCE(sum(u.total_cost), 0)::numeric, 4),
                'tokens', COALESCE(sum(u.total_tokens), 0),
                'calls', COALESCE(sum(u.call_count), 0)) AS item
            FROM usage_summary(span, source) u
            GROUP BY u.provider, u.model
            ORDER BY COALESCE(sum(u.total_cost), 0) DESC
        ) s;
        RETURN tool_success(
            jsonb_build_object('period', period, 'top_models', rows_json),
            format('Top models by cost (%s): %s model(s)', period, jsonb_array_length(rows_json)));
    END IF;

    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO rows_json FROM (
        SELECT jsonb_build_object(
            'provider', u.provider,
            'model', u.model,
            'operation', u.operation,
            'calls', u.call_count,
            'tokens', COALESCE(u.total_tokens, 0),
            'cost_usd', round(COALESCE(u.total_cost, 0)::numeric, 4)) AS item
        FROM usage_summary(span, source) u
    ) s;
    SELECT COALESCE(sum((value->>'cost_usd')::numeric), 0) AS cost,
           COALESCE(sum((value->>'tokens')::bigint), 0) AS tokens,
           COALESCE(sum((value->>'calls')::bigint), 0) AS calls
    INTO totals
    FROM jsonb_array_elements(rows_json) value;
    RETURN tool_success(
        jsonb_build_object(
            'period', period,
            'total_cost_usd', round(totals.cost, 4),
            'total_tokens', totals.tokens,
            'total_calls', totals.calls,
            'by_model', rows_json),
        format('Usage (%s): $%s total, %s tokens, %s calls',
               period, round(totals.cost, 2), totals.tokens, totals.calls));
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$ LANGUAGE plpgsql;
