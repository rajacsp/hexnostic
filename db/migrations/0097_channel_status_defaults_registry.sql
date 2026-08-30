-- Continue config-defaults registry cleanup for channel status helpers.
SET search_path = public, ag_catalog, "$user";

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
