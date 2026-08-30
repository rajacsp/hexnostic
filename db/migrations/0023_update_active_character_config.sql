-- Allow a selected character card to update the canonical persona snapshot
-- without recreating memories or graph edges.
CREATE OR REPLACE FUNCTION store_character_card_config(p_card JSONB)
RETURNS JSONB AS $$
DECLARE
    normalized JSONB := normalize_character_card(p_card);
    document JSONB := normalized->'document';
    profile JSONB := normalized->'profile';
    patch JSONB;
BEGIN
    patch := jsonb_strip_nulls(jsonb_build_object(
        'character_card', jsonb_strip_nulls(jsonb_build_object(
            'spec', document->'spec',
            'spec_version', document->'spec_version',
            'data', normalized->'data'
        )),
        'agent', jsonb_strip_nulls(jsonb_build_object(
            'name', profile->'name',
            'pronouns', profile->'pronouns',
            'voice', profile->'voice',
            'description', profile->'description',
            'purpose', profile->'purpose',
            'personality', profile->'personality_description',
            'personality_traits', profile->'personality_traits'
        )),
        'values', profile->'values',
        'worldview', profile->'worldview',
        'boundaries', profile->'boundaries',
        'interests', profile->'interests'
    ));
    RETURN merge_init_profile(patch);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION init_from_character_card(
    p_card JSONB,
    p_user_name TEXT DEFAULT 'User'
)
RETURNS JSONB AS $$
DECLARE
    normalized JSONB := normalize_character_card(p_card);
    result JSONB;
BEGIN
    result := init_from_character_profile(normalized->'profile', p_user_name);
    PERFORM store_character_card_config(p_card);
    RETURN result;
END;
$$ LANGUAGE plpgsql;
