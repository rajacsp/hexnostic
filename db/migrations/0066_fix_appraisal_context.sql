-- get_appraisal_db_context (0054) referenced get_active_goals(), which does
-- not exist — the function threw on every live call and the Python caller's
-- advisory except degraded the appraisal payload to hydrated-only context
-- (empty identity/worldview/relationships). Goals were already inside the
-- gather_turn_context() document; read them from there. Also brings the
-- ag_catalog stray get_dopamine_state home (#77 family).
SET search_path = public, ag_catalog, "$user";

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE p.proname = 'get_dopamine_state' AND n.nspname = 'ag_catalog')
       AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE p.proname = 'get_dopamine_state' AND n.nspname = 'public') THEN
        ALTER FUNCTION ag_catalog.get_dopamine_state() SET SCHEMA public;
    END IF;
END $$;

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
        'dopamine_state', NULLIF(get_dopamine_state(), '{}'::jsonb)
    ));
END;
$$ LANGUAGE plpgsql;
