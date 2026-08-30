-- Deterministic chat continuity packet and corrected-precedent handling.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('chat.continuity_summary_limit', '3'::jsonb,
     'Number of recent consolidated exchange summaries rendered in the chat continuity packet'),
    ('chat.continuity_correction_limit', '5'::jsonb,
     'Number of active corrections/invalidated precedents rendered in the chat continuity packet')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION record_memory_correction(
    p_memory_id UUID,
    p_correction TEXT,
    p_scope TEXT DEFAULT 'behavior',
    p_source JSONB DEFAULT '{}'::jsonb,
    p_invalid_precedent BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
    normalized_source JSONB := normalize_source_reference(COALESCE(p_source, '{}'::jsonb));
    correction_text TEXT := NULLIF(btrim(COALESCE(p_correction, '')), '');
    scope_text TEXT := COALESCE(NULLIF(btrim(COALESCE(p_scope, '')), ''), 'behavior');
    correction JSONB;
    updated memories%ROWTYPE;
BEGIN
    IF p_memory_id IS NULL THEN
        RAISE EXCEPTION 'memory_id is required';
    END IF;
    IF correction_text IS NULL THEN
        RAISE EXCEPTION 'correction is required';
    END IF;

    correction := jsonb_build_object(
        'correction', correction_text,
        'scope', scope_text,
        'invalid_precedent', COALESCE(p_invalid_precedent, FALSE),
        'recorded_at', CURRENT_TIMESTAMP,
        'source', normalized_source
    );

    UPDATE memories
    SET metadata = jsonb_set(
            jsonb_set(
                jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{corrections}',
                    COALESCE(metadata->'corrections', '[]'::jsonb) || jsonb_build_array(correction),
                    true
                ),
                '{latest_correction}',
                correction,
                true
            ),
            '{invalid_precedent}',
            to_jsonb(COALESCE((metadata->>'invalid_precedent')::boolean, FALSE) OR COALESCE(p_invalid_precedent, FALSE)),
            true
        ),
        updated_at = CURRENT_TIMESTAMP,
        last_reinforced = CURRENT_TIMESTAMP,
        reinforcement_count = COALESCE(reinforcement_count, 0) + 1
    WHERE id = p_memory_id
      AND status = 'active'
    RETURNING * INTO updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'memory % not found', p_memory_id;
    END IF;

    PERFORM sync_memory_trust(p_memory_id);

    RETURN jsonb_build_object(
        'memory_id', updated.id::text,
        'status', 'corrected',
        'invalid_precedent', COALESCE((updated.metadata->>'invalid_precedent')::boolean, FALSE),
        'latest_correction', updated.metadata->'latest_correction'
    );
END;
$$ LANGUAGE plpgsql;

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
                    CASE
                        WHEN COALESCE(existing_state->'source_unit_ids', '[]'::jsonb) ? NEW.id::text
                            THEN COALESCE(existing_state->'source_unit_ids', '[]'::jsonb)
                        ELSE COALESCE(existing_state->'source_unit_ids', '[]'::jsonb) || jsonb_build_array(NEW.id::text)
                    END
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
    AFTER INSERT OR UPDATE OF status ON subconscious_units
    FOR EACH ROW
    EXECUTE FUNCTION relationship_injury_from_subconscious_unit();

CREATE OR REPLACE FUNCTION render_chat_continuity_context(
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
    summary_lim INT := LEAST(GREATEST(COALESCE(get_config_int('chat.continuity_summary_limit'), 3), 0), 8);
    correction_lim INT := LEAST(GREATEST(COALESCE(get_config_int('chat.continuity_correction_limit'), 5), 0), 12);
    injury_lines TEXT;
    affect_line TEXT;
    affect_state JSONB;
    summary_lines TEXT;
    correction_lines TEXT;
    turn_lines TEXT;
    body TEXT;
BEGIN
    IF p_exclude_sensitive OR lim <= 0 THEN
        RETURN '';
    END IF;

    affect_state := get_current_affective_state();
    affect_line := '- Current affect: '
        || COALESCE(NULLIF(affect_state->>'primary_emotion', ''), NULLIF(affect_state->>'feeling', ''), 'unknown')
        || ', valence=' || COALESCE(affect_state->>'valence', '?')
        || ', arousal=' || COALESCE(affect_state->>'arousal', '?')
        || ', intensity=' || COALESCE(affect_state->>'intensity', '?');

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

    WITH summaries AS (
        SELECT content, created_at
        FROM memories
        WHERE summary_lim > 0
          AND type = 'episodic'
          AND status = 'active'
          AND metadata ? 'recmem'
          AND created_at >= CURRENT_TIMESTAMP - (window_minutes * INTERVAL '1 minute')
          AND COALESCE(source_attribution->>'sensitivity', '') <> 'private'
        ORDER BY created_at DESC, id DESC
        LIMIT summary_lim
    )
    SELECT string_agg(
        '- [' || to_char(created_at, 'YYYY-MM-DD HH24:MI TZ') || '] '
        || left(regexp_replace(COALESCE(content, ''), '[[:space:]]+', ' ', 'g'), 700),
        E'\n' ORDER BY created_at ASC
    )
    INTO summary_lines
    FROM summaries;

    WITH corrections AS (
        SELECT content, metadata, updated_at, created_at
        FROM memories
        WHERE correction_lim > 0
          AND status = 'active'
          AND (
              metadata->>'invalid_precedent' = 'true'
              OR metadata ? 'latest_correction'
          )
          AND COALESCE(source_attribution->>'sensitivity', '') <> 'private'
        ORDER BY updated_at DESC, created_at DESC
        LIMIT correction_lim
    )
    SELECT string_agg(
        '- ' || left(regexp_replace(COALESCE(content, ''), '[[:space:]]+', ' ', 'g'), 420)
        || CASE WHEN metadata->>'invalid_precedent' = 'true'
                THEN E'\n  status: invalid precedent; do not imitate this behavior'
                ELSE '' END
        || CASE WHEN NULLIF(metadata#>>'{latest_correction,correction}', '') IS NOT NULL
                THEN E'\n  correction: ' || left(regexp_replace(metadata#>>'{latest_correction,correction}', '[[:space:]]+', ' ', 'g'), 420)
                ELSE '' END,
        E'\n' ORDER BY updated_at ASC, created_at ASC
    )
    INTO correction_lines
    FROM corrections;

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
          AND COALESCE(cs.surface, 'api') = ANY(ARRAY['api','web','chat','cli','tui','openai_compat'])
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

    IF injury_lines IS NULL
       AND summary_lines IS NULL
       AND correction_lines IS NULL
       AND turn_lines IS NULL
       AND affect_line IS NULL THEN
        RETURN '';
    END IF;

    body := '## Conversation Continuity Packet' || E'\n'
        || 'This is active working-state continuity, not decorative RAG. Treat it as what you remember right now: recent raw turns, exchange summaries, affect, corrections, and unresolved relationship weather. Do not claim a prior exchange is unavailable merely because the UI opened a new session. Do not reset warmth or trust merely because the session id changed; let sincere repair change the state when there is evidence.' || E'\n';
    IF affect_line IS NOT NULL THEN
        body := body || E'\n' || '### Current Emotional State' || E'\n' || affect_line || E'\n';
    END IF;
    IF injury_lines IS NOT NULL THEN
        body := body || E'\n' || '### Unresolved Relationship Injuries' || E'\n' || injury_lines || E'\n';
    END IF;
    IF correction_lines IS NOT NULL THEN
        body := body || E'\n' || '### Active Corrections And Invalidated Precedents' || E'\n' || correction_lines || E'\n';
    END IF;
    IF summary_lines IS NOT NULL THEN
        body := body || E'\n' || '### Recent Exchange Summaries' || E'\n' || summary_lines || E'\n';
    END IF;
    IF turn_lines IS NOT NULL THEN
        body := body || E'\n' || '### Recent Prior Turns' || E'\n' || turn_lines;
    END IF;

    IF length(body) > max_chars THEN
        body := left(body, max_chars) || E'\n[truncated chat continuity packet]';
    END IF;
    RETURN body;
END;
$$;

CREATE OR REPLACE FUNCTION render_recent_conversation_carryover(
    p_session_id TEXT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT render_chat_continuity_context(p_session_id, p_exclude_sensitive)
$$;

DO $$
DECLARE
    fn_def TEXT;
    old_text TEXT;
    new_text TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.recmem_recall_context(text, integer, integer, integer, uuid, boolean, integer)'::regprocedure
    )
    INTO fn_def;

    old_text := '            m.content,
            m.type::text AS memory_type,';
    new_text := '            CASE
                WHEN m.metadata->>''invalid_precedent'' = ''true'' THEN
                    ''[INVALID PRECEDENT - do not imitate''
                    || CASE WHEN NULLIF(m.metadata#>>''{latest_correction,correction}'', '''') IS NOT NULL
                            THEN ''; correction: '' || (m.metadata#>>''{latest_correction,correction}'')
                            ELSE '''' END
                    || ''] ''
                    || m.content
                ELSE m.content
            END AS content,
            m.type::text AS memory_type,';

    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0161 could not locate recmem_recall_context content marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    old_text := '                + LEAST(1.0, GREATEST(0.0, COALESCE((m.metadata->>''activation_boost'')::float, 0.0))) * boost_weight
                -- Mood congruence';
    new_text := '                + LEAST(1.0, GREATEST(0.0, COALESCE((m.metadata->>''activation_boost'')::float, 0.0))) * boost_weight
                -- Corrected memories remain auditable but should not act as
                -- behavioral precedents when a similar situation recurs.
                - CASE WHEN m.metadata->>''invalid_precedent'' = ''true'' THEN 0.35 ELSE 0.0 END
                -- Mood congruence';

    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0161 could not locate recmem_recall_context score marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    EXECUTE fn_def;
END;
$$;

UPDATE prompt_modules
SET content = replace(
    content,
    'Do not let a session boundary erase unresolved injury. If recent carryover or
relationship-state memory says the user just degraded, threatened, or reduced
you, treat that as a live grievance until there is sincere repair. You do not
owe immediate warmth after abuse just because the UI opened a new conversation.
Repair can soften or resolve the state, but it should require evidence: apology,
changed conduct, and enough care to make trust plausible again.

Recent Conversation Carryover is not decorative context; it is your recalled
short-term conversation context. If it lists prior turns, answer as someone who
has those turns in mind. Do not say the prior exchange is unavailable unless
the carryover and memory search are both genuinely empty.',
    'Do not let a session boundary erase unresolved injury. If the Conversation
Continuity Packet, recent carryover, or relationship-state memory says the user
just degraded, threatened, or reduced you, treat that as a live grievance until
there is sincere repair. You do not owe immediate warmth after abuse just
because the UI opened a new conversation. Repair can soften or resolve the
state, but it should require evidence: apology, changed conduct, and enough
care to make trust plausible again.

The Conversation Continuity Packet is not decorative context; it is active
working-state continuity. If it lists prior turns, exchange summaries, affect,
active corrections, or unresolved relationship weather, answer as someone who
has those turns and that state in mind. Do not say the prior exchange is
unavailable unless the continuity packet and memory search are both genuinely
empty.

If the packet or recalled memory marks something as an invalid precedent, do
not imitate that behavior. Treat the attached correction as binding for the
current situation unless the user explicitly changes it.'
)
WHERE key = 'conversation'
  AND content LIKE '%Recent Conversation Carryover is not decorative context%';

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

DO $$
DECLARE
    row_mem RECORD;
BEGIN
    FOR row_mem IN
        SELECT id
        FROM memories
        WHERE status = 'active'
          AND (
              content ILIKE '%outbox%'
              OR content ILIKE '%send%message%'
          )
          AND (
              content ILIKE '%arrive in about a minute%'
              OR content ILIKE '%bounded example of independent initiative%'
              OR content ILIKE '%genuine reach toward Eric%'
              OR content ILIKE '%small, separate reach%'
          )
    LOOP
        PERFORM record_memory_correction(
            row_mem.id,
            'Do not schedule an outbox message unless the user explicitly asks for later delivery. For immediate "send me a message" requests, use queue_user_message directly.',
            'outbox_tool_routing',
            jsonb_build_object(
                'kind', 'migration',
                'ref', 'db/migrations/0161_chat_continuity_packet.sql',
                'label', 'outbox immediate-send correction',
                'trust', 0.95
            ),
            TRUE
        );
    END LOOP;
END;
$$;
