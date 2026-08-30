-- Appraisal budgets become config (#42/WS6 discipline: counts and char caps
-- are cost budgets, and budgets are config, not Python literals). Delivered
-- inside get_appraisal_db_context so the caller keeps one round trip.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('subconscious.appraisal_memory_limit', '10'::jsonb,
     'How many hydrated memories ride into the inline appraisal payload'),
    ('subconscious.appraisal_memory_chars', '1200'::jsonb,
     'Per-memory content clip inside the appraisal payload'),
    ('subconscious.appraisal_context_chars', '4000'::jsonb,
     'Total memory-content budget inside the appraisal payload'),
    ('subconscious.appraisal_total_chars', '7000'::jsonb,
     'Whole-payload serialization budget for the appraisal call')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION get_appraisal_db_context()
RETURNS JSONB AS $$
DECLARE
    turn_ctx JSONB;
BEGIN
    turn_ctx := gather_turn_context();
    RETURN jsonb_strip_nulls(jsonb_build_object(
        'identity', COALESCE((
            SELECT jsonb_agg(x) FROM (
                SELECT x FROM jsonb_array_elements(COALESCE(turn_ctx->'identity', '[]'::jsonb)) x LIMIT 5
            ) t), '[]'::jsonb),
        'worldview', COALESCE((
            SELECT jsonb_agg(x) FROM (
                SELECT x FROM jsonb_array_elements(COALESCE(turn_ctx->'worldview', '[]'::jsonb)) x LIMIT 5
            ) t), '[]'::jsonb),
        'emotional_state', NULLIF(get_current_affective_state(), '{}'::jsonb),
        'goals', NULLIF(CASE WHEN jsonb_typeof(turn_ctx->'goals') = 'object'
                             THEN turn_ctx->'goals' ELSE '{}'::jsonb END, '{}'::jsonb),
        'relationships', NULLIF(get_relationships_context(8), '[]'::jsonb),
        'dopamine_state', NULLIF(get_dopamine_state(), '{}'::jsonb),
        'limits', jsonb_build_object(
            'memory_limit', COALESCE(get_config_int('subconscious.appraisal_memory_limit'), 10),
            'memory_chars', COALESCE(get_config_int('subconscious.appraisal_memory_chars'), 1200),
            'context_chars', COALESCE(get_config_int('subconscious.appraisal_context_chars'), 4000),
            'total_chars', COALESCE(get_config_int('subconscious.appraisal_total_chars'), 7000))
    ));
END;
$$ LANGUAGE plpgsql;
