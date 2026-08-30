-- Store relationship labels with their purpose so an overloaded word like
-- "partner" does not masquerade as a fully established intimacy state.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION init_relationship(
    p_user JSONB DEFAULT NULL,
    p_relationship JSONB DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    user_input JSONB := COALESCE(p_user, '{}'::jsonb);
    relationship_input JSONB := COALESCE(p_relationship, '{}'::jsonb);
    user_name TEXT;
    rel_type TEXT;
    rel_purpose TEXT;
    rel_memory_text TEXT;
    embed_texts TEXT[] := ARRAY[]::text[];
    mem_id UUID;
    origin_id UUID;
BEGIN
    user_name := COALESCE(NULLIF(btrim(user_input->>'name'), ''), 'user');
    rel_type := COALESCE(NULLIF(btrim(relationship_input->>'type'), ''), 'partner');
    rel_purpose := NULLIF(btrim(relationship_input->>'purpose'), '');
    rel_memory_text := CASE
        WHEN lower(rel_type) = 'partner' AND lower(COALESCE(rel_purpose, '')) LIKE 'co-develop%' THEN
            format('I am in a co-development partnership with %s.', user_name)
        WHEN rel_purpose IS NOT NULL THEN
            format('My relationship with %s is %s; our purpose is %s.', user_name, rel_type, rel_purpose)
        ELSE
            format('My relationship with %s is %s.', user_name, rel_type)
    END;

    embed_texts := ARRAY[rel_memory_text, format('I met %s and began my life with them.', user_name)];
    IF rel_purpose IS NOT NULL THEN
        embed_texts := embed_texts || format('Our relationship purpose is %s.', rel_purpose);
    END IF;
    PERFORM prefetch_embeddings(embed_texts);

    PERFORM upsert_self_concept_edge('relationship', user_name, 0.9, NULL);

    mem_id := create_worldview_memory(
        rel_memory_text,
        'other',
        0.85,
        0.85,
        0.8,
        'initialization'
    );
    UPDATE memories
    SET metadata = metadata || jsonb_build_object('subcategory', 'relationship'),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = mem_id;

    IF rel_purpose IS NOT NULL THEN
        mem_id := create_worldview_memory(
            format('Our relationship purpose is %s.', rel_purpose),
            'other',
            0.8,
            0.8,
            0.7,
            'initialization'
        );
        UPDATE memories
        SET metadata = metadata || jsonb_build_object('subcategory', 'relationship_purpose'),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = mem_id;
    END IF;

    origin_id := create_episodic_memory(
        format('I met %s and began my life with them.', user_name),
        NULL,
        jsonb_build_object('type', 'initialization', 'user', user_name),
        NULL,
        0.7,
        CURRENT_TIMESTAMP,
        0.7
    );

    PERFORM merge_init_profile(jsonb_build_object(
        'user', jsonb_build_object('name', user_name),
        'relationship', jsonb_build_object('type', rel_type, 'purpose', rel_purpose),
        'origin_memory_id', origin_id::text
    ));

    RETURN advance_init_stage(
        'relationship',
        jsonb_build_object(
            'user', user_input,
            'relationship', relationship_input,
            'origin_memory_id', origin_id::text
        )
    );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    profile JSONB := COALESCE(get_config('agent.init_profile'), '{}'::jsonb);
    user_name TEXT := COALESCE(NULLIF(btrim(profile#>>'{user,name}'), ''), 'user');
    rel_type TEXT := COALESCE(NULLIF(btrim(profile#>>'{relationship,type}'), ''), 'partner');
    rel_purpose TEXT := NULLIF(btrim(profile#>>'{relationship,purpose}'), '');
    old_text TEXT;
    replacement_text TEXT;
    existing_id UUID;
    new_id UUID;
BEGIN
    IF NOT (lower(rel_type) = 'partner' AND lower(COALESCE(rel_purpose, '')) LIKE 'co-develop%') THEN
        RETURN;
    END IF;

    old_text := format('My relationship with %s is %s.', user_name, rel_type);
    replacement_text := format('I am in a co-development partnership with %s.', user_name);

    UPDATE memories
    SET status = 'archived',
        importance = LEAST(COALESCE(importance, 0.8), 0.2),
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
            'archived_reason',
            'Ambiguous initialization relationship label; replaced by purpose-qualified co-development partnership memory in migration 0094.',
            'archived_by',
            'migration 0094',
            'archived_at',
            now()::text)
    WHERE type = 'worldview'
      AND status = 'active'
      AND content = old_text;

    SELECT id INTO existing_id
    FROM memories
    WHERE status = 'active'
      AND type = 'worldview'
      AND content = replacement_text
    LIMIT 1;

    IF existing_id IS NULL THEN
        new_id := create_worldview_memory(
            replacement_text,
            'other',
            0.85,
            0.85,
            0.8,
            'initialization'
        );
        UPDATE memories
        SET metadata = metadata || jsonb_build_object(
                'subcategory', 'relationship',
                'replacement_for', old_text,
                'replacement_reason', 'Purpose-qualified relationship label prevents overloaded partner semantics.')
        WHERE id = new_id;
    END IF;
END;
$$;
