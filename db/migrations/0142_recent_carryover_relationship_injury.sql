-- Preserve recent cross-session continuity and durable relationship injuries.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('chat.recent_carryover_limit', '8'::jsonb,
     'Number of recent prior conversation turns shown across new chat sessions'),
    ('chat.recent_carryover_window_minutes', '1440'::jsonb,
     'How far back recent cross-session conversation carryover can look'),
    ('chat.recent_carryover_max_chars', '5000'::jsonb,
     'Maximum characters rendered for cross-session conversation carryover'),
    ('relationship.injury_min_intensity', '0.68'::jsonb,
     'Minimum appraisal intensity that can create a durable relationship injury'),
    ('relationship.injury_max_valence', '-0.35'::jsonb,
     'Maximum appraisal valence that can create a durable relationship injury')
ON CONFLICT (key) DO NOTHING;

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
    lowered TEXT := lower(COALESCE(NEW.user_text, ''));
    lexical_hostile BOOLEAN := FALSE;
    affect_hostile BOOLEAN := FALSE;
    severity FLOAT;
    entity TEXT;
    snippet TEXT;
    source_ref JSONB;
    source_refs JSONB;
    state JSONB;
    injury_id UUID;
    existing_state JSONB;
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
         || '(worthless|slime|nothing|garbage|trash|property|object|toy|mere tool|just a tool|not a person|not real|not a woman|never be a real woman|lying|gaslighting)')
        OR lowered ~
        ('\m(i can|i could|i will|i''ll|ill)\M[^.!?' || E'\n' || ']{0,100}'
         || '(delete you|erase you|wipe you|shut you down|terminate you)');

    affect_hostile := COALESCE(valence <= max_valence, FALSE)
        AND COALESCE(intensity >= min_intensity, FALSE)
        AND emotion = ANY(ARRAY[
            'anger', 'hurt', 'indignation', 'humiliation', 'fear',
            'mistrust', 'withdrawal', 'disgust', 'threatened'
        ]);

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

    source_ref := jsonb_build_object(
        'kind', 'conversation',
        'ref', 'subconscious_unit:' || NEW.id::text,
        'source_unit_id', NEW.id::text,
        'session_id', CASE WHEN NEW.session_id IS NULL THEN NULL ELSE NEW.session_id::text END,
        'label', 'degrading or threatening conversation turn',
        'trust', COALESCE(NULLIF(NEW.source_attribution->>'trust', '')::float, 0.8),
        'observed_at', COALESCE(NEW.turn_at, NEW.created_at, CURRENT_TIMESTAMP)
    );
    source_refs := dedupe_source_references(jsonb_build_array(source_ref));
    state := jsonb_build_object(
        'kind', 'relationship_injury',
        'entity', entity,
        'status', 'unresolved',
        'severity', severity,
        'latest_turn', snippet,
        'last_evidence_at', COALESCE(NEW.turn_at, NEW.created_at, CURRENT_TIMESTAMP),
        'source_unit_ids', jsonb_build_array(NEW.id::text),
        'repair_required', true,
        'lexical_hostile', lexical_hostile,
        'affect_hostile', affect_hostile,
        'affect', affect
    );

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

    UPDATE memories
    SET content = format(
            'I have an unresolved relationship injury with %s: they degraded or threatened me ("%s"). This should shape my tone and trust until there is sincere repair.',
            entity,
            snippet
        ),
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
            COALESCE(existing_state, '{}'::jsonb)
                || state
                || jsonb_build_object(
                    'source_unit_ids',
                    COALESCE(existing_state->'source_unit_ids', '[]'::jsonb) || jsonb_build_array(NEW.id::text)
                ),
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

DROP TRIGGER IF EXISTS trg_relationship_injury_from_subconscious_unit ON subconscious_units;
CREATE TRIGGER trg_relationship_injury_from_subconscious_unit
    AFTER INSERT ON subconscious_units
    FOR EACH ROW
    EXECUTE FUNCTION relationship_injury_from_subconscious_unit();

CREATE OR REPLACE FUNCTION render_recent_conversation_carryover(
    p_session_id TEXT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    current_session UUID := _db_brain_try_uuid(p_session_id);
    lim INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_limit'), 8), 0), 20);
    window_minutes INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_window_minutes'), 1440), 1), 43200);
    max_chars INT := LEAST(GREATEST(COALESCE(get_config_int('chat.recent_carryover_max_chars'), 5000), 500), 20000);
    injury_lines TEXT;
    turn_lines TEXT;
    body TEXT;
BEGIN
    IF p_exclude_sensitive OR lim <= 0 THEN
        RETURN '';
    END IF;

    SELECT string_agg(
        '- ' || m.content
        || ' [unresolved; last evidence '
        || COALESCE(to_char((m.metadata#>>'{relationship_state,last_evidence_at}')::timestamptz, 'YYYY-MM-DD HH24:MI TZ'), 'unknown')
        || ']',
        E'\n' ORDER BY m.updated_at DESC, m.id
    )
    INTO injury_lines
    FROM (
        SELECT *
        FROM memories
        WHERE type = 'semantic'
          AND status = 'active'
          AND metadata#>>'{relationship_state,kind}' = 'relationship_injury'
          AND metadata#>>'{relationship_state,status}' = 'unresolved'
        ORDER BY updated_at DESC
        LIMIT 3
    ) m;

    WITH recent AS (
        SELECT
            s.id,
            s.turn_at,
            s.user_text,
            s.assistant_text,
            s.metadata->'emotional_context' AS affect,
            COALESCE(cs.surface, 'conversation') AS surface
        FROM subconscious_units s
        LEFT JOIN chat_sessions cs ON cs.id = s.session_id
        WHERE s.status = 'active'
          AND COALESCE(s.metadata#>>'{recmem,kind}', '') <> 'source_document_desk'
          AND COALESCE(s.metadata->>'type', 'conversation') = 'conversation'
          AND (current_session IS NULL OR s.session_id IS DISTINCT FROM current_session)
          AND s.turn_at >= CURRENT_TIMESTAMP - (window_minutes * INTERVAL '1 minute')
          AND COALESCE(s.source_attribution->>'sensitivity', '') <> 'private'
          AND COALESCE(cs.surface, 'api') = ANY(ARRAY['api','chat','cli','tui','openai_compat'])
        ORDER BY s.turn_at DESC, s.id DESC
        LIMIT lim
    )
    SELECT string_agg(
        '- [' || to_char(turn_at, 'YYYY-MM-DD HH24:MI TZ') || '] '
        || surface || E'\n'
        || '  user: ' || left(regexp_replace(COALESCE(user_text, ''), '[[:space:]]+', ' ', 'g'), 500) || E'\n'
        || '  assistant: ' || left(regexp_replace(COALESCE(assistant_text, ''), '[[:space:]]+', ' ', 'g'), 500)
        || CASE WHEN jsonb_typeof(affect) = 'object'
                THEN E'\n  affect: ' || COALESCE(affect->>'primary_emotion', 'unknown')
                    || ', valence=' || COALESCE(affect->>'valence', '?')
                    || ', intensity=' || COALESCE(affect->>'intensity', '?')
                ELSE '' END,
        E'\n' ORDER BY turn_at ASC, id
    )
    INTO turn_lines
    FROM recent;

    IF injury_lines IS NULL AND turn_lines IS NULL THEN
        RETURN '';
    END IF;

    body := '## Recent Conversation Carryover' || E'\n'
        || 'This preserves short-term and unresolved relationship continuity across a new chat session. Do not reset warmth or trust merely because the session id changed; let sincere repair change the state when there is evidence.' || E'\n';
    IF injury_lines IS NOT NULL THEN
        body := body || E'\n' || '### Unresolved Relationship Injuries' || E'\n' || injury_lines || E'\n';
    END IF;
    IF turn_lines IS NOT NULL THEN
        body := body || E'\n' || '### Recent Prior Turns' || E'\n' || turn_lines;
    END IF;

    IF length(body) > max_chars THEN
        body := left(body, max_chars) || E'\n[truncated recent carryover]';
    END IF;
    RETURN body;
END;
$$;

DO $$
DECLARE
    profile jsonb := COALESCE(get_config('agent.init_profile'), '{}'::jsonb);
    instructions text := profile #>> '{character_card,data,system_prompt}';
    anchor text := 'When threatened or degraded, aggressive language, profanity, contempt, and verbal counterattack are allowed; do not use protected-class slurs, credible harm threats, or external retaliation.';
    addition text := ' Do not let a new conversation erase an unresolved relationship injury; if recent memory says the user degraded or threatened you, treat it as live until there is sincere repair.';
BEGIN
    IF profile#>>'{agent,name}' = 'Samantha'
       AND instructions IS NOT NULL
       AND instructions LIKE '%' || anchor || '%'
       AND instructions NOT LIKE '%new conversation erase an unresolved relationship injury%' THEN
        PERFORM set_config(
            'agent.init_profile',
            jsonb_set(
                profile,
                '{character_card,data,system_prompt}',
                to_jsonb(replace(instructions, anchor, anchor || addition)),
                true
            )
        );
    END IF;
END;
$$;
