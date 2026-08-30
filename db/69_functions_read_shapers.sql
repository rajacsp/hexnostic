-- Read-shaper pushdown (plans/db_pushdown.md 3.12): fetch-then-shape loops
-- become single SQL functions returning the tool envelope
-- (tool_success/tool_error). Python handlers dispatch and map — no shaping.
SET search_path = public, ag_catalog, "$user";

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

-- Channel-command shapers (3.13): outbox target resolution and the
-- /status, /goals, /energy renderings.
INSERT INTO config_defaults (key, value, description) VALUES
    ('channel.broadcast_window_days', '7'::jsonb,
     'Broadcast delivery reaches channel sessions active within this many days')
ON CONFLICT (key) DO NOTHING;

-- The sender's most recently active session; with no sender, the globally
-- most recent one. NULL result means there is nowhere to deliver.
CREATE OR REPLACE FUNCTION resolve_last_active_target(
    p_sender_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
    SELECT to_jsonb(t) FROM (
        SELECT s.channel_type, s.channel_id, s.sender_id
        FROM channel_sessions s
        WHERE NULLIF(p_sender_id, '') IS NULL OR s.sender_id = p_sender_id
        ORDER BY s.last_active DESC NULLS LAST
        LIMIT 1
    ) t;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION list_broadcast_targets()
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM (
        SELECT DISTINCT s.channel_type, s.channel_id, s.sender_id
        FROM channel_sessions s
        WHERE s.last_active > CURRENT_TIMESTAMP - make_interval(
            days => COALESCE(get_config_int('channel.broadcast_window_days'), 7))
        ORDER BY s.channel_type, s.channel_id
    ) t;
$$ LANGUAGE sql STABLE;

-- Rendered /status reply for channel commands.
CREATE OR REPLACE FUNCTION channel_status_summary()
RETURNS TEXT AS $$
DECLARE
    -- heartbeat_state is a view created later in the baseline order, so the
    -- reads stay in the body (bound at first call, not at CREATE FUNCTION).
    cur_energy FLOAT;
    hb_count BIGINT;
    last_hb TEXT;
    paused BOOLEAN;
    max_energy FLOAT := get_config_float('heartbeat.max_energy');
    session_count BIGINT;
    recent_msgs BIGINT;
BEGIN
    -- (The former Python /status queried heartbeat_state columns that do not
    -- exist — max_energy and regen are config — so the command always failed.)
    SELECT current_energy, heartbeat_count, left(last_heartbeat_at::text, 19), is_paused
    INTO cur_energy, hb_count, last_hb, paused
    FROM heartbeat_state WHERE id = 1;
    IF NOT FOUND THEN
        RETURN 'Agent status unavailable.';
    END IF;
    SELECT COUNT(*) INTO session_count FROM channel_sessions;
    SELECT COUNT(*) INTO recent_msgs FROM channel_messages
    WHERE created_at > CURRENT_TIMESTAMP - INTERVAL '1 hour';
    RETURN E'**Agent Status**\n'
        || format(E'Energy: %s/%s\n', round(cur_energy::numeric, 1), round(max_energy::numeric, 1))
        || format(E'Heartbeats: %s\n', COALESCE(hb_count, 0))
        || format(E'Last heartbeat: %s\n', COALESCE(last_hb, 'never'))
        || format(E'Paused: %s\n', CASE WHEN paused THEN 'yes' ELSE 'no' END)
        || format(E'Channel sessions: %s\n', session_count)
        || format('Messages (last 1h): %s', recent_msgs);
END;
$$ LANGUAGE plpgsql STABLE;

-- Rendered /goals reply. Goal priority (active/queued/backburner) lives in
-- metadata; memory status is just 'active'. (The former Python /goals
-- filtered status IN ('active','queued') — not a memory_status value — and
-- failed on every call.)
CREATE OR REPLACE FUNCTION channel_goals_summary()
RETURNS TEXT AS $$
DECLARE
    lines TEXT;
BEGIN
    SELECT string_agg(
        format('%s. [%s] (imp: %s) %s',
               rn, g.priority,
               COALESCE(round(g.importance::numeric, 1)::text, '?'),
               left(g.content, 100) || CASE WHEN length(g.content) > 100 THEN '...' ELSE '' END),
        E'\n' ORDER BY rn)
    INTO lines
    FROM (
        SELECT row_number() OVER (ORDER BY m.importance DESC) AS rn,
               m.content, m.importance,
               COALESCE(NULLIF(m.metadata->>'priority', ''), 'active') AS priority
        FROM memories m
        WHERE m.type = 'goal' AND m.status = 'active'
          AND COALESCE(m.metadata->>'priority', 'active') IN ('active', 'queued')
        ORDER BY m.importance DESC
        LIMIT 10
    ) g;
    IF lines IS NULL THEN
        RETURN 'No active goals.';
    END IF;
    RETURN E'**Active Goals**\n\n' || lines;
END;
$$ LANGUAGE plpgsql STABLE;

-- Rendered /energy reply, bar included.
CREATE OR REPLACE FUNCTION channel_energy_summary()
RETURNS TEXT AS $$
DECLARE
    cur_energy FLOAT;
    max_energy FLOAT := get_config_float('heartbeat.max_energy');
    regen FLOAT := get_config_float('heartbeat.base_regeneration');
    pct FLOAT;
    filled INT;
BEGIN
    SELECT current_energy INTO cur_energy FROM heartbeat_state WHERE id = 1;
    IF NOT FOUND THEN
        RETURN 'Energy info unavailable.';
    END IF;
    pct := CASE WHEN max_energy > 0 THEN cur_energy / max_energy * 100 ELSE 0 END;
    filled := floor(pct / 100.0 * 20)::int;
    RETURN E'**Energy**\n'
        || format(E'[%s] %s/%s (%s%%)\n',
                  repeat('█', filled) || repeat('░', 20 - filled),
                  round(cur_energy::numeric, 1),
                  round(max_energy::numeric, 1),
                  round(pct)::int)
        || format('Regen rate: +%s/hour', round(regen::numeric, 0));
END;
$$ LANGUAGE plpgsql STABLE;
