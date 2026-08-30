-- 0048: Init convergence (#79) — one core for every init frontend.
-- get_init_status() gains a step-level ground-truth map (llm, names,
-- timezone, consent, configured) so frontends render gaps from the DB
-- instead of each wizard's memory of what init entails; init_set_timezone()
-- is the single timezone step (CLI sends the host zone, the web wizard the
-- browser zone) — found drifted: web-initialized agents lived in UTC.
-- Baseline mirrors: db/07, db/10.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION get_init_status()
RETURNS JSONB AS $$
DECLARE
    state_record RECORD;
    remaining TEXT[];
    profile JSONB := get_init_profile();
BEGIN
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    remaining := ARRAY(
        SELECT stage::text
        FROM unnest(enum_range(NULL::init_stage)) AS stage
        WHERE stage > state_record.init_stage
    );

    RETURN jsonb_build_object(
        'stage', state_record.init_stage::text,
        'is_complete', state_record.init_stage = 'complete',
        'data_collected', COALESCE(state_record.init_data, '{}'::jsonb),
        'stages_remaining', COALESCE(remaining, ARRAY[]::text[]),
        -- Step-level ground truth (init convergence): every frontend renders
        -- gaps from THIS map instead of its own memory of what init entails —
        -- a step a wizard forgets shows up as false here, not as silent drift.
        'steps', jsonb_build_object(
            'llm_configured', COALESCE(
                NULLIF(get_config('llm.heartbeat'), 'null'::jsonb),
                NULLIF(get_config('llm.chat'), 'null'::jsonb)) IS NOT NULL,
            'profile_named', NULLIF(profile#>>'{agent,name}', '') IS NOT NULL,
            'user_named', NULLIF(profile#>>'{user,name}', '') IS NOT NULL,
            'timezone_set', COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC') <> 'UTC',
            'timezone', COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC'),
            'consent', COALESCE(get_agent_consent_status(), 'not_requested'),
            'configured', COALESCE(is_agent_configured(), false)
        )
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION init_set_timezone(
    p_timezone TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    tz TEXT := NULLIF(trim(COALESCE(p_timezone, '')), '');
BEGIN
    IF tz IS NULL THEN
        RETURN FALSE;
    END IF;
    IF COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC') <> 'UTC' THEN
        RETURN FALSE;
    END IF;
    BEGIN
        PERFORM CURRENT_TIMESTAMP AT TIME ZONE tz;
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;
    END;
    PERFORM set_config('agent.timezone', to_jsonb(tz));
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
