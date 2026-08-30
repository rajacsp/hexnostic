-- Preserve the selected character card as canonical configuration. The graph
-- remains an evolving, derived self-model rather than the source of persona.
CREATE OR REPLACE FUNCTION normalize_character_card(p_card JSONB)
RETURNS JSONB AS $$
DECLARE
    document JSONB := COALESCE(p_card, '{}'::jsonb);
    card_data JSONB;
    hexis_profile JSONB;
    standard_profile JSONB;
BEGIN
    card_data := CASE
        WHEN jsonb_typeof(document->'data') = 'object' THEN document->'data'
        ELSE document
    END;
    hexis_profile := CASE
        WHEN jsonb_typeof(card_data#>'{extensions,hexis}') = 'object'
            THEN card_data#>'{extensions,hexis}'
        ELSE '{}'::jsonb
    END;
    standard_profile := jsonb_strip_nulls(jsonb_build_object(
        'name', card_data->'name',
        'description', card_data->'description',
        'personality_description', card_data->'personality'
    ));

    RETURN jsonb_build_object(
        'document', document,
        'data', card_data,
        'profile', standard_profile || hexis_profile
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

DO $$
BEGIN
    IF to_regprocedure('init_from_character_profile(jsonb,text)') IS NULL THEN
        ALTER FUNCTION init_from_character_card(JSONB, TEXT)
            RENAME TO init_from_character_profile;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION init_from_character_card(
    p_card JSONB,
    p_user_name TEXT DEFAULT 'User'
)
RETURNS JSONB AS $$
DECLARE
    normalized JSONB := normalize_character_card(p_card);
    document JSONB := normalized->'document';
    result JSONB;
BEGIN
    result := init_from_character_profile(normalized->'profile', p_user_name);
    PERFORM merge_init_profile(jsonb_build_object(
        'character_card', jsonb_strip_nulls(jsonb_build_object(
            'spec', document->'spec',
            'spec_version', document->'spec_version',
            'data', normalized->'data'
        ))
    ));
    RETURN result;
END;
$$ LANGUAGE plpgsql;

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
