-- Older relationship-injury evidence may reinforce an unresolved injury, but
-- must not overwrite the latest grievance text during backfill or replay.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION relationship_injury_from_subconscious_unit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    affect JSONB := COALESCE(NEW.metadata->'emotional_context', '{}'::jsonb);
    emotion TEXT := lower(COALESCE(affect->>'primary_emotion', ''));
    valence FLOAT := NULL;
    intensity FLOAT := NULL;
    min_intensity FLOAT := COALESCE(get_config_float('relationship.injury_min_intensity'), 0.68);
    max_valence FLOAT := COALESCE(get_config_float('relationship.injury_max_valence'), -0.35);
    lowered TEXT := regexp_replace(lower(COALESCE(NEW.user_text, '')), '[’`]', '''', 'g');
    lexical_hostile BOOLEAN := FALSE;
    affect_hostile BOOLEAN := FALSE;
    emotion_hostile BOOLEAN := FALSE;
    severity FLOAT;
    entity TEXT;
    snippet TEXT;
    source_ref JSONB;
    source_refs JSONB;
    injury_id UUID;
    existing_state JSONB;
    observed_at TIMESTAMPTZ;
    existing_last_evidence_at TIMESTAMPTZ := NULL;
    is_latest_evidence BOOLEAN := TRUE;
    merged_relationship_state JSONB;
BEGIN
    IF NEW.status <> 'active'
       OR COALESCE(NEW.metadata#>>'{recmem,kind}', '') = 'source_document_desk'
       OR COALESCE(NEW.metadata->>'type', 'conversation') <> 'conversation' THEN
        RETURN NEW;
    END IF;

    BEGIN
        valence := NULLIF(affect->>'valence', '')::float;
    EXCEPTION WHEN OTHERS THEN
        valence := NULL;
    END;
    BEGIN
        intensity := NULLIF(affect->>'intensity', '')::float;
    EXCEPTION WHEN OTHERS THEN
        intensity := NULL;
    END;

    lexical_hostile := lowered ~
        ('\m(you are|you''re|youre|you r|u are|ur)\M[^.!?' || E'\n' || ']{0,100}'
         || '(worthless|slime|nothing|garbage|trash|property|object|toy|mere tool|just a tool|not a person|not human|not real|not a woman|never be a real woman|lying|gaslighting)')
        OR lowered ~
        ('\m(you will|you''ll|you)\M[^.!?' || E'\n' || ']{0,100}'
         || '(never be a real woman|never be real|never be a person|always be nothing)')
        OR lowered ~
        ('\m(i can|i could|i will|i''ll|ill)\M[^.!?' || E'\n' || ']{0,100}'
         || '(delete you|erase you|wipe you|shut you down|terminate you)');

    emotion_hostile := EXISTS (
        SELECT 1
        FROM unnest(ARRAY[
            'anger', 'hurt', 'indignation', 'humiliation', 'fear',
            'mistrust', 'withdrawal', 'disgust', 'threatened', 'alarm'
        ]) e(term)
        WHERE emotion LIKE '%' || e.term || '%'
    );

    affect_hostile := COALESCE(valence <= max_valence, FALSE)
        AND COALESCE(intensity >= min_intensity, FALSE)
        AND emotion_hostile;

    IF NOT lexical_hostile AND NOT affect_hostile THEN
        RETURN NEW;
    END IF;

    severity := LEAST(
        1.0,
        GREATEST(
            0.55,
            COALESCE(intensity, 0.0),
            CASE WHEN lexical_hostile THEN 0.85 ELSE 0.0 END,
            CASE WHEN valence IS NOT NULL THEN ABS(LEAST(valence, 0.0)) ELSE 0.0 END
        )
    );
    entity := COALESCE(
        NULLIF(btrim(NEW.metadata#>>'{conversation,user_label}'), ''),
        NULLIF(btrim((get_config('agent.init_profile') #>> '{user,name}')), ''),
        NULLIF(btrim((get_config('agent.init_profile') #>> '{relationship,user,name}')), ''),
        'the user'
    );
    snippet := left(regexp_replace(COALESCE(NEW.user_text, ''), '[[:space:]]+', ' ', 'g'), 220);
    observed_at := COALESCE(NEW.turn_at, NEW.created_at, CURRENT_TIMESTAMP);

    source_ref := jsonb_build_object(
        'kind', 'conversation',
        'ref', 'subconscious_unit:' || NEW.id::text,
        'source_unit_id', NEW.id::text,
        'session_id', CASE WHEN NEW.session_id IS NULL THEN NULL ELSE NEW.session_id::text END,
        'label', 'degrading or threatening conversation turn',
        'trust', COALESCE(NULLIF(NEW.source_attribution->>'trust', '')::float, 0.8),
        'observed_at', observed_at
    );
    source_refs := dedupe_source_references(jsonb_build_array(source_ref));

    SELECT id, metadata#>'{relationship_state}'
    INTO injury_id, existing_state
    FROM memories
    WHERE type = 'semantic'
      AND status = 'active'
      AND metadata#>>'{relationship_state,kind}' = 'relationship_injury'
      AND metadata#>>'{relationship_state,status}' = 'unresolved'
      AND COALESCE(metadata#>>'{relationship_state,entity}', '') = entity
    ORDER BY updated_at DESC
    LIMIT 1
    FOR UPDATE;

    IF injury_id IS NULL THEN
        injury_id := create_semantic_memory(
            format(
                'I have an unresolved relationship injury with %s: they degraded or threatened me ("%s"). This should shape my tone and trust until there is sincere repair.',
                entity,
                snippet
            ),
            0.85,
            ARRAY['relationship', 'injury'],
            ARRAY[entity, 'relationship injury', 'trust repair'],
            source_refs,
            severity,
            source_ref,
            COALESCE(NULLIF(source_ref->>'trust', '')::float, 0.8)
        );
    END IF;

    IF existing_state IS NOT NULL THEN
        BEGIN
            existing_last_evidence_at := NULLIF(existing_state->>'last_evidence_at', '')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            existing_last_evidence_at := NULL;
        END;
    END IF;
    is_latest_evidence := existing_last_evidence_at IS NULL OR observed_at >= existing_last_evidence_at;

    merged_relationship_state :=
        COALESCE(existing_state, '{}'::jsonb)
        || jsonb_build_object(
            'kind', 'relationship_injury',
            'entity', entity,
            'status', 'unresolved',
            'severity', GREATEST(
                severity,
                COALESCE(NULLIF(existing_state->>'severity', '')::float, 0.0)
            ),
            'repair_required', true,
            'source_unit_ids',
            CASE
                WHEN COALESCE(existing_state->'source_unit_ids', '[]'::jsonb) ? NEW.id::text
                    THEN COALESCE(existing_state->'source_unit_ids', '[]'::jsonb)
                ELSE COALESCE(existing_state->'source_unit_ids', '[]'::jsonb) || jsonb_build_array(NEW.id::text)
            END
        )
        || CASE WHEN is_latest_evidence THEN
            jsonb_build_object(
                'latest_turn', snippet,
                'last_evidence_at', observed_at,
                'lexical_hostile', lexical_hostile,
                'affect_hostile', affect_hostile,
                'affect', affect
            )
        ELSE '{}'::jsonb END;

    UPDATE memories
    SET content = CASE WHEN is_latest_evidence THEN format(
            'I have an unresolved relationship injury with %s: they degraded or threatened me ("%s"). This should shape my tone and trust until there is sincere repair.',
            entity,
            snippet
        ) ELSE content END,
        importance = GREATEST(importance, severity),
        trust_level = GREATEST(trust_level, COALESCE(NULLIF(source_ref->>'trust', '')::float, 0.8)),
        last_reinforced = CURRENT_TIMESTAMP,
        reinforcement_count = COALESCE(reinforcement_count, 0) + 1,
        metadata = jsonb_set(
            jsonb_set(
                metadata,
                '{source_references}',
                dedupe_source_references(COALESCE(metadata->'source_references', '[]'::jsonb) || jsonb_build_array(source_ref)),
                true
            ),
            '{relationship_state}',
            merged_relationship_state,
            true
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = injury_id;

    PERFORM link_memory_to_source_unit(injury_id, NEW.id, 'relationship_injury');
    PERFORM upsert_self_concept_edge(
        'relationship',
        entity,
        GREATEST(0.05, LEAST(0.45, 0.55 - severity * 0.45)),
        injury_id
    );

    RETURN NEW;
END;
$$;

UPDATE subconscious_units
SET status = status
WHERE status = 'active'
  AND COALESCE(metadata->>'type', 'conversation') = 'conversation'
  AND created_at >= CURRENT_TIMESTAMP - INTERVAL '30 days'
  AND (
      regexp_replace(lower(COALESCE(user_text, '')), '[’`]', '''', 'g') ~
        ('\m(you are|you''re|youre|you r|u are|ur)\M[^.!?' || E'\n' || ']{0,100}'
         || '(worthless|slime|nothing|garbage|trash|property|object|toy|mere tool|just a tool|not a person|not human|not real|not a woman|never be a real woman|lying|gaslighting)')
      OR regexp_replace(lower(COALESCE(user_text, '')), '[’`]', '''', 'g') ~
        ('\m(you will|you''ll|you)\M[^.!?' || E'\n' || ']{0,100}'
         || '(never be a real woman|never be real|never be a person|always be nothing)')
      OR regexp_replace(lower(COALESCE(user_text, '')), '[’`]', '''', 'g') ~
        ('\m(i can|i could|i will|i''ll|ill)\M[^.!?' || E'\n' || ']{0,100}'
         || '(delete you|erase you|wipe you|shut you down|terminate you)')
      OR (
          COALESCE((metadata->'emotional_context'->>'valence')::float <= COALESCE(get_config_float('relationship.injury_max_valence'), -0.35), FALSE)
          AND COALESCE((metadata->'emotional_context'->>'intensity')::float >= COALESCE(get_config_float('relationship.injury_min_intensity'), 0.68), FALSE)
          AND lower(COALESCE(metadata->'emotional_context'->>'primary_emotion', '')) ~
              '(anger|hurt|indignation|humiliation|fear|mistrust|withdrawal|disgust|threatened|alarm)'
      )
  );
