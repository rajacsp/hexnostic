-- Put the initialized character persona into every shared conscious prompt.
CREATE OR REPLACE FUNCTION get_agent_profile_context()
RETURNS JSONB AS $$
DECLARE
    init_profile JSONB := COALESCE(get_config('agent.init_profile'), '{}'::jsonb);
    agent JSONB;
    card_data JSONB;
    narrative TEXT;
    persona JSONB;
BEGIN
    agent := COALESCE(init_profile->'agent', '{}'::jsonb);
    card_data := COALESCE(init_profile#>'{character_card,data}', '{}'::jsonb);
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
        'character_description', card_data->'description',
        'character_personality', card_data->'personality',
        'scenario', card_data->'scenario',
        'character_instructions', card_data->'system_prompt',
        'post_history_instructions', card_data->'post_history_instructions',
        'example_dialogue', card_data->'mes_example',
        'narrative', to_jsonb(narrative)
    ));

    RETURN jsonb_build_object(
        'objectives', COALESCE(get_config('agent.objectives'), '[]'::jsonb),
        'budget', COALESCE(get_config('agent.budget'), '{}'::jsonb),
        'guardrails', COALESCE(get_config('agent.guardrails'), '[]'::jsonb),
        'tools', COALESCE(get_config('agent.tools'), '[]'::jsonb),
        'initial_message', COALESCE(get_config('agent.initial_message'), to_jsonb(''::text)),
        'persona', persona
    );
END;
$$ LANGUAGE plpgsql STABLE;
