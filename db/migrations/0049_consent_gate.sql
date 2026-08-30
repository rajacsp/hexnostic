-- 0049: The DB decides when consent is reachable (#79).
-- get_init_status() gains 'missing' (ordered unmet requirements) and
-- 'ready_for_consent'; the CLI and the web wizard both gate the consent
-- stage on this contract instead of assuming their own flow covered
-- everything. Baseline mirror: db/07.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION get_init_status()
RETURNS JSONB AS $$
DECLARE
    state_record RECORD;
    remaining TEXT[];
    profile JSONB := get_init_profile();
    llm_ok BOOLEAN;
    profile_ok BOOLEAN;
    missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    remaining := ARRAY(
        SELECT stage::text
        FROM unnest(enum_range(NULL::init_stage)) AS stage
        WHERE stage > state_record.init_stage
    );

    llm_ok := COALESCE(
        NULLIF(get_config('llm.heartbeat'), 'null'::jsonb),
        NULLIF(get_config('llm.chat'), 'null'::jsonb)) IS NOT NULL;
    profile_ok := NULLIF(profile#>>'{agent,name}', '') IS NOT NULL;
    -- What stands between here and consent — the DB decides, every frontend
    -- renders. Order = the order a wizard should resolve them.
    IF NOT llm_ok THEN missing := array_append(missing, 'llm'); END IF;
    IF NOT profile_ok THEN missing := array_append(missing, 'profile'); END IF;

    RETURN jsonb_build_object(
        'stage', state_record.init_stage::text,
        'is_complete', state_record.init_stage = 'complete',
        'data_collected', COALESCE(state_record.init_data, '{}'::jsonb),
        'stages_remaining', COALESCE(remaining, ARRAY[]::text[]),
        'missing', to_jsonb(missing),
        'ready_for_consent', cardinality(missing) = 0,
        -- Step-level ground truth (init convergence): every frontend renders
        -- gaps from THIS map instead of its own memory of what init entails —
        -- a step a wizard forgets shows up as false here, not as silent drift.
        'steps', jsonb_build_object(
            'llm_configured', llm_ok,
            'profile_named', profile_ok,
            'user_named', NULLIF(profile#>>'{user,name}', '') IS NOT NULL,
            'timezone_set', COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC') <> 'UTC',
            'timezone', COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC'),
            'consent', COALESCE(get_agent_consent_status(), 'not_requested'),
            'configured', COALESCE(is_agent_configured(), false)
        )
    );
END;
$$ LANGUAGE plpgsql;
