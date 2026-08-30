-- Channel-command shapers (plans/db_pushdown.md 3.13): outbox target
-- resolution (broadcast window becomes config), and the /status, /goals,
-- /energy channel-command renderings move into SQL.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
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
    max_energy FLOAT := COALESCE(get_config_float('heartbeat.max_energy'), 20.0);
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
    max_energy FLOAT := COALESCE(get_config_float('heartbeat.max_energy'), 20.0);
    regen FLOAT := COALESCE(get_config_float('heartbeat.base_regeneration'), 10.0);
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
