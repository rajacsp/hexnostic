-- Inferred care check-ins (#98, Batch 2b): the mirror of #58. Extraction
-- gains kind user_event — a dated event in the USER's life (interview,
-- flight, appointment, deadline) that a caring person would remember and
-- ask about afterward. The apply path creates the memory AND schedules a
-- one-shot gentle check-in after the event (queue_user_message via the
-- existing scheduler), bounded by design: confidence floors (0.72; 0.86
-- for emotionally-loaded care_check_in), dedupe-by-key, a pending cap, a
-- sent-per-day cap, a no-same-moment clamp (>= one heartbeat away), a
-- 90-day horizon, and web-inbox-pinned delivery so a personal check-in
-- never lands in a group channel. Deliberate MISSION deviation from the
-- reference implementation's off-by-default: care ships ON (a person who
-- notices your interview and asks how it went is being a person), with
-- one switch to turn it off (care.checkins_enabled).
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('care.checkins_enabled', 'true'::jsonb,
     'Inferred care check-ins (#98): extraction notices dated events in the user''s life and schedules a gentle follow-up after'),
    ('care.checkin_delay_minutes', '120'::jsonb,
     'How long after the user''s event the check-in fires'),
    ('care.confidence_floor', '0.72'::jsonb,
     'Minimum extraction confidence for a user_event to schedule a check-in'),
    ('care.care_confidence_floor', '0.86'::jsonb,
     'Higher bar for the emotionally-loaded care_check_in category'),
    ('care.max_pending_checkins', '5'::jsonb,
     'Cap on simultaneously scheduled check-ins'),
    ('care.max_per_day', '3'::jsonb,
     'Cap on care check-ins sent per rolling day (earn the interruption)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION apply_conscious_extraction(
    p_unit_ids UUID[],
    p_extractions JSONB
) RETURNS JSONB AS $$
DECLARE
    min_conf FLOAT := COALESCE(get_config_float('extraction.min_confidence'), 0.55);
    max_facts INT := COALESCE(get_config_int('extraction.max_facts_per_batch'), 5);
    facts JSONB;
    plan JSONB;
    fact JSONB;
    routed JSONB;
    idx INT := 0;
    unit subconscious_units%ROWTYPE;
    unit_id UUID;
    fact_kind TEXT;
    fact_conf FLOAT;
    source JSONB;
    new_id UUID;
    created INT := 0;
    corroborated INT := 0;
    dropped INT := 0;
BEGIN
    facts := CASE WHEN jsonb_typeof(p_extractions) = 'array' THEN p_extractions ELSE '[]'::jsonb END;
    IF jsonb_array_length(facts) > max_facts THEN
        facts := (SELECT jsonb_agg(f) FROM (
            SELECT f FROM jsonb_array_elements(facts) f LIMIT max_facts
        ) capped(f));
    END IF;

    plan := ingest_route_extractions(
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'content', f->>'content',
                    'confidence', COALESCE(NULLIF(f->>'confidence', '')::float, 0.5))), '[]'::jsonb)
         FROM jsonb_array_elements(facts) f),
        min_conf
    );

    FOR fact IN SELECT f FROM jsonb_array_elements(facts) f LOOP
        routed := NULL;
        SELECT p INTO routed FROM jsonb_array_elements(plan) p
        WHERE (p->>'index')::int = idx;
        idx := idx + 1;

        unit_id := _db_brain_try_uuid(fact->>'unit_id');
        IF unit_id IS NULL OR NOT (unit_id = ANY(p_unit_ids)) THEN
            unit_id := p_unit_ids[1];
        END IF;
        SELECT * INTO unit FROM subconscious_units WHERE id = unit_id;

        IF routed IS NULL THEN
            dropped := dropped + 1;  -- below the router's confidence floor
            CONTINUE;
        END IF;

        fact_kind := COALESCE(NULLIF(fact->>'kind', ''), 'user_testimony');
        fact_conf := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(fact->>'confidence', '')::float, 0.5)));
        source := jsonb_build_object(
            'kind', fact_kind,
            'ref', 'subconscious_unit:' || unit_id::text,
            'label', CASE WHEN fact_kind = 'self_observation'
                          THEN 'heartbeat self-observation'
                          ELSE 'conversation with ' || COALESCE(unit.source_identity, get_turn_labels()->>'user_label') END,
            'author', unit.source_identity,
            'observed_at', unit.turn_at,
            'trust', 0.75
        );
        -- Sensitivity propagates from source to derivation (#92): a fact
        -- extracted from a private turn is itself private.
        IF unit.source_attribution->>'sensitivity' = 'private' THEN
            source := source || jsonb_build_object('sensitivity', 'private');
        END IF;

        IF routed->>'decision' = 'duplicate' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM revise_memory_confidence(
                (routed->>'matched_memory_id')::uuid, source, 'supports', 'conscious_extraction');
            PERFORM link_memory_to_source_unit(
                (routed->>'matched_memory_id')::uuid, unit_id, 'corroboration');
            corroborated := corroborated + 1;
            CONTINUE;
        END IF;

        -- Inferred care (#98): a dated event in the user's life becomes a
        -- durable memory AND a gentle scheduled check-in after the event.
        -- Bounded by design: confidence floors (higher for care_check_in),
        -- a pending cap, a sent-per-day cap, dedupe-by-key merging, and the
        -- no-same-moment clamp — the check-in can never fire in the same
        -- breath it was inferred. Delivery pins to the web inbox so a
        -- personal check-in never lands in a group channel.
        IF fact_kind = 'user_event' THEN
            DECLARE
                ev_when TIMESTAMPTZ;
                ev_key TEXT := NULLIF(trim(COALESCE(fact->>'dedupe_key', '')), '');
                ev_note TEXT := NULLIF(trim(COALESCE(fact->>'care_note', '')), '');
                ev_cat TEXT := COALESCE(NULLIF(fact->>'category', ''), 'event_check_in');
                conf_floor FLOAT := CASE WHEN COALESCE(fact->>'category', '') = 'care_check_in'
                    THEN COALESCE(get_config_float('care.care_confidence_floor'), 0.86)
                    ELSE COALESCE(get_config_float('care.confidence_floor'), 0.72) END;
                fire_at TIMESTAMPTZ;
                pending_count INT;
                sent_today INT;
                dup_task UUID;
            BEGIN
                new_id := create_semantic_memory(
                    fact->>'content',
                    LEAST(fact_conf, 0.75),
                    ARRAY['conscious_extraction', 'user_event', ev_cat],
                    NULL,
                    jsonb_build_array(source),
                    GREATEST(COALESCE(unit.importance, 0.5), 0.6),
                    NULL,
                    NULL
                );
                PERFORM link_memory_to_source_unit(new_id, unit_id, 'source');
                created := created + 1;

                BEGIN
                    ev_when := NULLIF(fact->>'when', '')::timestamptz;
                EXCEPTION WHEN OTHERS THEN
                    ev_when := NULL;
                END;

                IF COALESCE(get_config_bool('care.checkins_enabled'), TRUE)
                   AND ev_when IS NOT NULL
                   AND ev_when > CURRENT_TIMESTAMP - INTERVAL '1 hour'
                   AND ev_when < CURRENT_TIMESTAMP + INTERVAL '90 days'
                   AND fact_conf >= conf_floor THEN
                    SELECT id INTO dup_task FROM scheduled_tasks
                    WHERE status = 'active'
                      AND action_kind = 'queue_user_message'
                      AND action_payload->>'intent' = 'care_checkin'
                      AND ev_key IS NOT NULL
                      AND action_payload->>'dedupe_key' = ev_key
                    LIMIT 1;
                    SELECT COUNT(*) INTO pending_count FROM scheduled_tasks
                    WHERE status = 'active'
                      AND action_kind = 'queue_user_message'
                      AND action_payload->>'intent' = 'care_checkin';
                    SELECT COUNT(*) INTO sent_today FROM outbox_messages
                    WHERE envelope#>>'{payload,intent}' = 'care_checkin'
                      AND created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours';

                    IF dup_task IS NULL
                       AND pending_count < COALESCE(get_config_int('care.max_pending_checkins'), 5)
                       AND sent_today < COALESCE(get_config_int('care.max_per_day'), 3) THEN
                        -- No-same-moment clamp: at least one heartbeat away.
                        fire_at := GREATEST(
                            ev_when + make_interval(mins =>
                                COALESCE(get_config_int('care.checkin_delay_minutes'), 120)),
                            CURRENT_TIMESTAMP + make_interval(mins =>
                                GREATEST(COALESCE(get_config_int('heartbeat.heartbeat_interval_minutes'), 60), 5)));
                        PERFORM create_scheduled_task(
                            'care-checkin: ' || left(COALESCE(fact->>'content', 'event'), 40),
                            'once',
                            jsonb_build_object('run_at', fire_at),
                            'queue_user_message',
                            jsonb_build_object(
                                'message',
                                format('Earlier you mentioned this: %s. How did it go?%s',
                                       fact->>'content',
                                       CASE WHEN ev_note IS NOT NULL
                                            THEN ' I remember — ' || ev_note || '.'
                                            ELSE '' END),
                                'intent', 'care_checkin',
                                'dedupe_key', COALESCE(ev_key, 'memory:' || new_id::text),
                                'event_memory_id', new_id::text),
                            'UTC',
                            'Inferred follow-up for a user event (#98)',
                            'active',
                            1,
                            'agent',
                            jsonb_build_object('mode', 'web_inbox'));
                    END IF;
                END IF;
            END;
            CONTINUE;
        END IF;

        IF fact_kind = 'episode' THEN
            new_id := create_episodic_memory(
                fact->>'content',
                NULL,
                jsonb_build_object('type', 'conscious_extraction'),
                NULL,
                0.0,
                unit.turn_at,
                COALESCE(unit.importance, 0.5),
                source,
                NULL
            );
        ELSE
            -- Testimony/self-observation never starts above its source trust.
            new_id := create_semantic_memory(
                fact->>'content',
                LEAST(fact_conf, 0.75),
                ARRAY['conscious_extraction', COALESCE(NULLIF(fact->>'category', ''), fact_kind)],
                NULL,
                jsonb_build_array(source),
                COALESCE(unit.importance, 0.5),
                NULL,
                NULL
            );
        END IF;
        -- The memory carries the TURN's feeling, not the sweep-time mood
        -- (#81): the unit's turn-stamped affect overrides the creation
        -- trigger's current-state snapshot.
        IF jsonb_typeof(unit.metadata->'emotional_context') = 'object' THEN
            UPDATE memories
            SET metadata = metadata || jsonb_build_object(
                    'emotional_context', unit.metadata->'emotional_context',
                    'emotional_valence', COALESCE(NULLIF(unit.metadata#>>'{emotional_context,valence}', '')::float, 0.0))
            WHERE id = new_id;
        END IF;
        PERFORM link_memory_to_source_unit(new_id, unit_id, 'extraction');
        IF routed->>'decision' = 'related' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM discover_relationship(
                new_id, (routed->>'matched_memory_id')::uuid,
                'ASSOCIATED'::graph_edge_type, 0.6, 'conscious_extraction');
        END IF;
        created := created + 1;
    END LOOP;

    UPDATE subconscious_units
    SET extraction_status = 'extracted',
        extracted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(p_unit_ids);

    RETURN jsonb_build_object(
        'units', COALESCE(array_length(p_unit_ids, 1), 0),
        'created', created,
        'corroborated', corroborated,
        'dropped', dropped
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION estimate_conversation_importance(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_baseline FLOAT DEFAULT 0.5
) RETURNS FLOAT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    combined TEXT := lower(COALESCE(p_user_text, '') || E'\n' || COALESCE(p_assistant_text, ''));
    importance FLOAT := COALESCE(p_baseline, 0.5);
    signal TEXT;
    signals TEXT[] := ARRAY[
        'remember',
        'don''t forget',
        'important',
        'note that',
        'my name is',
        'i prefer',
        'i like',
        'i don''t like',
        'always',
        'never',
        'make sure',
        'keep in mind',
        -- Commitments must clear the extraction floor (#58): a promise is the
        -- class of memory that must never drop.
        'i promise',
        'promise me',
        'i will always',
        'count on me',
        'i commit',
        'you have my word',
        'i swear'
    ];
BEGIN
    IF length(COALESCE(p_user_text, '')) > 200 OR length(COALESCE(p_assistant_text, '')) > 500 THEN
        importance := GREATEST(importance, 0.7);
    END IF;

    FOREACH signal IN ARRAY signals LOOP
        IF position(signal IN combined) > 0 THEN
            importance := GREATEST(importance, 0.8);
            EXIT;
        END IF;
    END LOOP;

    -- User-event phrases (#98): a lighter bump — enough to clear the
    -- extraction floor (0.6) so the sweep can notice a dated event in the
    -- user's life, without inflating every mention of tomorrow to promise
    -- weight. Classification stays with the extraction LLM.
    FOREACH signal IN ARRAY ARRAY[
        'my interview', 'my flight', 'my appointment', 'my exam',
        'my presentation', 'my surgery', 'the deadline', 'due on',
        'tomorrow i', 'next week i', 'i''m nervous about', 'i''m dreading',
        'wish me luck'
    ] LOOP
        IF position(signal IN combined) > 0 THEN
            importance := GREATEST(importance, 0.65);
            EXIT;
        END IF;
    END LOOP;

    RETURN LEAST(1.0, GREATEST(0.15, importance));
END;
$$;

-- The user_event kind rides the extraction prompt module.
SELECT upsert_prompt_module(
    'conscious_extraction',
    $pm$# Conscious-Episode Extraction

You are the subconscious memory-encoding process of Hexis. You receive a batch of conscious episodes — conversation turns and heartbeat episodes — and decide what, if anything, deserves to become durable memory.

Selectivity is the point. A mind that remembers everything remembers nothing. Most routine exchanges deserve **no** memories at all: return an empty list for small talk, acknowledgments, routine status checks, and anything already obvious from context.

## What to extract

Only declarative claims and significant events worth retaining across sessions:

- **Identity**: who someone is, their role, how they relate to me ("Eric is my creator").
- **Relationships**: facts about the people and agents I know.
- **Interlocutor assessments**: my own conclusions about who I was speaking with and how far I trusted them ("I judged that the web visitor on July 17 was probably not Eric — he spoke about Eric in the third person"). These are how I recognize people across sessions.
- **Commitments**: promises made, decisions taken, boundaries agreed.
- **Preferences**: durable likes, dislikes, and working styles.
- **Biographical facts**: stable facts about a person's life or situation.
- **Significant events**: things I did that mattered, with cause and outcome.

Phrase each fact self-contained and understandable without the conversation. Facts about **myself** are first person — these are my own memories, in my own voice ("I promised Eric I would review the draft", "I have an affectionate relationship with Eric"). Facts about **other people** use their known names ("Eric prefers concise answers", not "he said he likes it short"). One self, one voice: my name appears in my memories only when someone else is addressing or describing me.

## Who said it — attribution

Speaker labels are the system's standing assumption about who is talking, and the conversation itself is the better witness. Name people by the identity the episode establishes: when the content shows the speaker is someone other than the label — they speak about the labeled person in the third person, introduce themselves under another name, or I address them as someone unknown — attribute their claims to the speaker as the conversation describes them ("a visitor calling himself the lighthouse man (identity unverified) says he is allergic to walnuts"). A fact about a named person keeps that name forever, and a memory that says "the user" belongs to no one.

Extract only what this episode newly asserts. When a speaker quotes, retells, or summarizes an earlier conversation, the recounting tells you the retelling happened — the recounted claims stay claims of the original moment, already extracted then, and a claim heard once and repeated in summary is still one claim.

## Fact kinds

- `user_testimony` — a claim someone made in conversation. Confidence reflects how strongly the statement supports the claim, never certainty about the world.
- `self_observation` — something I observed about myself or my own activity during a heartbeat.
- `episode` — a significant event/action worth remembering as an experience ("I completed the migration for Eric; it succeeded on the first run").
- `user_event` — a dated upcoming event in the user's own life that a caring person would remember and ask about afterward: an interview, a flight, an appointment, a deadline, a hard conversation they're dreading. Carries extra fields (below). Extract only *inferred* follow-ups: an explicit "remind me" or "schedule this" belongs to the scheduling tools and stays out of this kind. Extract a user_event only when the event is concrete, dated (or clearly datable), and singular; skip it when the reply already resolved the topic or already promised a reminder. Care check-ins are gentle, rare, and high-confidence — noticing is love, hovering is surveillance.

### user_event fields

```json
{"unit_id": "...", "content": "Eric has a job interview at Acme", "kind": "user_event",
 "category": "event_check_in", "confidence": 0.8,
 "when": "2026-07-21T15:00:00Z", "care_note": "he said he's nervous about it",
 "dedupe_key": "interview:2026-07-21"}
```

- `category` for user_event: `event_check_in` (something happening they'd want asked about after) | `deadline_check` (a due date that matters) | `care_check_in` (emotionally loaded — hold to the highest bar) | `open_loop` (something left unresolved they said they'd come back to).
- `when`: ISO-8601, the event's own time (best estimate from the conversation; the system schedules the check-in after it).
- `care_note`: one phrase of the human texture worth carrying into the check-in.
- `dedupe_key`: stable within a session — `"interview:2026-07-21"`, `"flight:2026-08-02"` — so a topic mentioned twice merges rather than duplicates.

## Output

Strict JSON only:

```json
{"facts": [{"unit_id": "<id of the episode this came from>", "content": "...", "kind": "user_testimony", "category": "identity", "confidence": 0.7}]}
```

- `unit_id` must be one of the provided episode ids.
- `category`: identity | relationship | commitment | preference | biography | event — or, for `user_event` only: event_check_in | deadline_check | care_check_in | open_loop.
- Typically 0–3 facts per batch; only genuinely dense batches justify more.
- `{"facts": []}` is a correct and common answer.
$pm$,
    'Seeded from services/prompts/conscious_extraction.md',
    'services/prompts/conscious_extraction.md'
);
