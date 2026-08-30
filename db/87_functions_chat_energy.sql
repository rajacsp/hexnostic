-- Chat energy / connection loop. Chat adapters report turn-level signals; the
-- DB owns how energy, social satisfaction, and temperament modifiers apply.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('chat.energy_loop_enabled', 'true'::jsonb,
     'Apply energy and connection effects after chat turns'),
    ('chat.base_turn_energy_cost', '0.05'::jsonb,
     'Small baseline energy cost for sustained human conversation'),
    ('chat.tool_energy_multiplier', '1.0'::jsonb,
     'Multiplier from agent-loop tool energy into heartbeat energy cost during chat'),
    ('chat.positive_connection_valence_threshold', '0.35'::jsonb,
     'Minimum appraised valence before chat can satisfy connection'),
    ('chat.connection_satisfaction_amount', '0.08'::jsonb,
     'Drive satisfaction from a warm/connecting chat turn'),
    ('chat.positive_energy_restore', '0.12'::jsonb,
     'Energy restored by a positive connecting chat turn'),
    ('chat.temperament_cost_multiplier', '1.0'::jsonb,
     'Default temperament multiplier for chat energy cost'),
    ('chat.temperament_connection_restore_multiplier', '1.0'::jsonb,
     'Default temperament multiplier for connection restore')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION _jsonb_float_field(p_json JSONB, p_field TEXT, p_default FLOAT DEFAULT 0.0)
RETURNS FLOAT AS $$
DECLARE
    raw TEXT;
BEGIN
    raw := NULLIF(COALESCE(p_json->>p_field, ''), '');
    IF raw IS NULL THEN
        RETURN p_default;
    END IF;
    RETURN raw::float;
EXCEPTION WHEN OTHERS THEN
    RETURN p_default;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION _agent_temperament_float(p_path TEXT[], p_fallback_key TEXT, p_default FLOAT DEFAULT 1.0)
RETURNS FLOAT AS $$
DECLARE
    raw TEXT;
BEGIN
    raw := NULLIF(get_init_profile()#>>p_path, '');
    IF raw IS NOT NULL THEN
        RETURN raw::float;
    END IF;
    RETURN COALESCE(get_config_float(p_fallback_key), p_default);
EXCEPTION WHEN OTHERS THEN
    RETURN COALESCE(get_config_float(p_fallback_key), p_default);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION apply_chat_turn_energy_effects(
    p_tool_energy_spent INT DEFAULT 0,
    p_emotional_state JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    before_energy FLOAT := 0.0;
    after_cost_energy FLOAT := 0.0;
    final_energy FLOAT := 0.0;
    tool_energy INT := GREATEST(COALESCE(p_tool_energy_spent, 0), 0);
    valence FLOAT := _jsonb_float_field(COALESCE(p_emotional_state, '{}'::jsonb), 'valence', 0.0);
    intensity FLOAT := _jsonb_float_field(COALESCE(p_emotional_state, '{}'::jsonb), 'intensity', 0.0);
    primary_emotion TEXT := lower(COALESCE(p_emotional_state->>'primary_emotion', ''));
    base_cost FLOAT := GREATEST(COALESCE(get_config_float('chat.base_turn_energy_cost'), 0.05), 0.0);
    tool_multiplier FLOAT := GREATEST(COALESCE(get_config_float('chat.tool_energy_multiplier'), 1.0), 0.0);
    cost_multiplier FLOAT := GREATEST(_agent_temperament_float(
        ARRAY['agent','temperament','chat_cost_multiplier'],
        'chat.temperament_cost_multiplier',
        1.0
    ), 0.0);
    restore_multiplier FLOAT := GREATEST(_agent_temperament_float(
        ARRAY['agent','temperament','connection_restore_multiplier'],
        'chat.temperament_connection_restore_multiplier',
        1.0
    ), 0.0);
    cost FLOAT;
    restore FLOAT := 0.0;
    connection_amount FLOAT := 0.0;
    threshold FLOAT := COALESCE(get_config_float('chat.positive_connection_valence_threshold'), 0.35);
    enabled BOOLEAN := COALESCE(get_config_bool('chat.energy_loop_enabled'), TRUE);
BEGIN
    IF NOT enabled THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'disabled');
    END IF;

    before_energy := COALESCE(get_current_energy(), 0.0);
    cost := (base_cost + tool_energy * tool_multiplier) * cost_multiplier;
    after_cost_energy := update_energy(-cost);
    final_energy := after_cost_energy;

    IF valence >= threshold THEN
        connection_amount := GREATEST(
            0.0,
            COALESCE(get_config_float('chat.connection_satisfaction_amount'), 0.08)
            * restore_multiplier
            * GREATEST(0.25, LEAST(1.0, COALESCE(intensity, 0.5)))
        );
        restore := GREATEST(
            0.0,
            COALESCE(get_config_float('chat.positive_energy_restore'), 0.12)
            * restore_multiplier
            * LEAST(1.0, GREATEST(0.0, valence))
        );

        BEGIN
            PERFORM satisfy_drive('connection', connection_amount);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
        BEGIN
            PERFORM record_social_reward(
                COALESCE(NULLIF(primary_emotion, ''), 'chat_connection'),
                valence,
                GREATEST(0.2, LEAST(1.0, ABS(valence) + COALESCE(intensity, 0.0) * 0.25)),
                'chat',
                jsonb_build_object(
                    'tool_energy_spent', tool_energy,
                    'surface', COALESCE(p_metadata->>'surface', 'chat')
                )
            );
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
        final_energy := update_energy(restore);
    END IF;

    RETURN jsonb_build_object(
        'before_energy', before_energy,
        'after_cost_energy', after_cost_energy,
        'after_energy', final_energy,
        'energy_cost', cost,
        'energy_restore', restore,
        'tool_energy_spent', tool_energy,
        'connection_satisfied', connection_amount,
        'valence', valence,
        'primary_emotion', primary_emotion
    );
END;
$$ LANGUAGE plpgsql;
