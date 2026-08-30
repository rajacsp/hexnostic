-- get_agent_profile_context gains a top-level 'name': the CLI status
-- panel resolved identity from keys the profile never had and showed
-- 'unnamed' for a configured agent.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION get_agent_profile_context()
RETURNS JSONB AS $$
DECLARE
    init_profile JSONB := COALESCE(get_config('agent.init_profile'), '{}'::jsonb);
    agent JSONB;
    card_data JSONB;
    narrative TEXT;
    persona JSONB;
    char_name TEXT;
    user_name TEXT;
BEGIN
    agent := COALESCE(init_profile->'agent', '{}'::jsonb);
    card_data := COALESCE(init_profile#>'{character_card,data}', '{}'::jsonb);
    char_name := COALESCE(NULLIF(agent->>'name', ''), NULLIF(card_data->>'name', ''));
    user_name := COALESCE(
        NULLIF(init_profile#>>'{relationship,name}', ''),
        NULLIF(init_profile#>>'{user,name}', ''));
    SELECT m.content
    INTO narrative
    FROM memories m
    WHERE m.type = 'worldview'
      AND m.status = 'active'
      AND m.metadata->>'origin' = 'initialization'
      AND m.metadata->>'subcategory' = 'narrative'
      AND m.metadata->>'attribute' = 'foundational'
    ORDER BY m.created_at DESC
    LIMIT 1;

    persona := jsonb_strip_nulls(jsonb_build_object(
        'name', agent->'name',
        'pronouns', agent->'pronouns',
        'voice', agent->'voice',
        'description', agent->'description',
        'personality', agent->'personality',
        'purpose', agent->'purpose',
        'values', init_profile->'values',
        'worldview', init_profile->'worldview',
        'boundaries', init_profile->'boundaries',
        'interests', init_profile->'interests',
        'relationship', init_profile->'relationship',
        'relationship_aspiration', init_profile->'relationship_aspiration',
        'character_description', _resolve_card_macros(card_data->'description', char_name, user_name),
        'character_personality', _resolve_card_macros(card_data->'personality', char_name, user_name),
        'scenario', _resolve_card_macros(card_data->'scenario', char_name, user_name),
        'character_instructions', _resolve_card_macros(card_data->'system_prompt', char_name, user_name),
        'post_history_instructions', _resolve_card_macros(card_data->'post_history_instructions', char_name, user_name),
        'example_dialogue', _resolve_card_macros(card_data->'mes_example', char_name, user_name),
        'narrative', to_jsonb(narrative)
    ));

    RETURN jsonb_strip_nulls(jsonb_build_object(
        -- Top-level identity name: consumers (CLI status, dashboards) read
        -- one field instead of re-deriving it from the persona/card.
        'name', to_jsonb(char_name),
        'objectives', COALESCE(get_config('agent.objectives'), '[]'::jsonb),
        'budget', COALESCE(get_config('agent.budget'), '{}'::jsonb),
        'guardrails', COALESCE(get_config('agent.guardrails'), '[]'::jsonb),
        'tools', COALESCE(get_config('agent.tools'), '[]'::jsonb),
        'initial_message', COALESCE(get_config('agent.initial_message'), to_jsonb(''::text)),
        'persona', persona
    ));
END;
$$ LANGUAGE plpgsql STABLE;
