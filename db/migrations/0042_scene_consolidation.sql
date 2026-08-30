-- 0042: Scene consolidation at session boundaries (#73, RecMem Rev 5 Phase 1).
-- A conversation that goes quiet becomes ONE scene-grained episode_create
-- task (db/63) instead of dozens of per-turn promotions; scene memories carry
-- occurred_from/occurred_to + session_id; direct promotion becomes a
-- config-gated safety valve (memory.direct_promotion_min_importance, 0.95);
-- the episode_create prompt learns scene grain.
-- Baseline mirrors: db/63 (new), db/31, db/34, db/40 (regenerated).
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('memory.scene_idle_seconds', '1800'::jsonb,
     'A session with no new turns for this long is a closed scene, ready to consolidate'),
    ('memory.scene_check_interval_seconds', '300'::jsonb,
     'How often the worker looks for idle sessions to consolidate into scenes')
ON CONFLICT (key) DO NOTHING;

-- Sessions whose units have gone quiet and still hold unconsumed material.
-- "Unconsumed" = active, embedded, and not already claimed by or folded into
-- an episode. Sessions with units still awaiting embedding are skipped — the
-- embed pass runs every worker tick, so they become eligible moments later.
CREATE OR REPLACE FUNCTION find_idle_scene_sessions(
    p_limit INT DEFAULT 8
) RETURNS TABLE (
    session_id UUID,
    unit_ids UUID[],
    first_turn_at TIMESTAMPTZ,
    last_turn_at TIMESTAMPTZ
) AS $$
DECLARE
    idle_seconds FLOAT := GREATEST(COALESCE(get_config_float('memory.scene_idle_seconds'), 1800), 60);
BEGIN
    RETURN QUERY
    SELECT
        s.session_id,
        array_agg(s.id ORDER BY s.turn_at, s.created_at) AS unit_ids,
        min(s.turn_at) AS first_turn_at,
        max(s.turn_at) AS last_turn_at
    FROM subconscious_units s
    -- 'routing' units are mid-claim by the per-turn router; the scene sweep
    -- waits for them to settle (claims stale out in ~60s) rather than racing.
    WHERE s.session_id IS NOT NULL
      AND s.status = 'active'
      AND s.route_status IN ('unrouted', 'raw_only')
      -- Only EPISODIC consumption counts: extraction/corroboration links mean
      -- a fact was distilled from the turn, not that the experience itself
      -- was consolidated — the scene still needs to exist.
      AND NOT EXISTS (
          SELECT 1 FROM memory_source_units msu
          WHERE msu.subconscious_unit_id = s.id
            AND msu.role IN ('source', 'direct_promotion', 'merge_addition')
      )
    GROUP BY s.session_id
    HAVING max(s.turn_at) < CURRENT_TIMESTAMP - (idle_seconds || ' seconds')::interval
       -- Every unit of the scene must be embedded before the LLM sees it.
       AND bool_and(s.embedding_status = 'embedded')
    ORDER BY max(s.turn_at)
    LIMIT GREATEST(COALESCE(p_limit, 8), 1);
END;
$$ LANGUAGE plpgsql STABLE;

-- One episode_create task per idle session, covering all its unconsumed
-- units time-ordered. The existing worker, prompt, and apply handler run
-- unchanged; task_payload marks the boundary reason and session for the
-- scene metadata stamp in apply_recmem_episode_create.
CREATE OR REPLACE FUNCTION enqueue_scene_consolidations(
    p_limit INT DEFAULT 8
) RETURNS JSONB AS $$
DECLARE
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    scene RECORD;
    enqueued INT := 0;
    skipped_queue_full INT := 0;
BEGIN
    FOR scene IN SELECT * FROM find_idle_scene_sessions(p_limit)
    LOOP
        IF _recmem_pending_queue_depth() >= queue_max THEN
            skipped_queue_full := skipped_queue_full + 1;
            CONTINUE;
        END IF;

        INSERT INTO recmem_consolidation_tasks (
            task_type, trigger_unit_id, source_unit_ids, task_payload
        )
        VALUES (
            'episode_create',
            scene.unit_ids[1],
            scene.unit_ids,
            jsonb_build_object(
                'reason', 'session_boundary',
                'session_id', scene.session_id,
                'first_turn_at', scene.first_turn_at,
                'last_turn_at', scene.last_turn_at
            )
        );

        UPDATE subconscious_units
        SET route_status = 'create_queued',
            route_result = route_result || jsonb_build_object(
                'scene_boundary', true,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(scene.unit_ids);

        enqueued := enqueued + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'enqueued', enqueued,
        'skipped_queue_full', skipped_queue_full
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION should_run_scene_consolidation()
RETURNS BOOLEAN AS $$
DECLARE
    state_doc JSONB := COALESCE(get_state('scene_state'), '{}'::jsonb);
    last_run TIMESTAMPTZ := NULLIF(state_doc->>'last_run_at', '')::timestamptz;
    interval_seconds FLOAT := COALESCE(get_config_float('memory.scene_check_interval_seconds'), 300);
BEGIN
    IF last_run IS NULL THEN
        RETURN TRUE;
    END IF;

    RETURN CURRENT_TIMESTAMP >= last_run + (interval_seconds || ' seconds')::interval;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION mark_scene_consolidation_run(
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    merged JSONB;
BEGIN
    merged := COALESCE(get_state('scene_state'), '{}'::jsonb)
        || jsonb_build_object(
            'last_run_at', CURRENT_TIMESTAMP,
            'last_run_result', COALESCE(p_result, '{}'::jsonb)
        );

    PERFORM set_state('scene_state', merged);
    RETURN merged;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_episode_create(
    p_task_id UUID,
    p_episodes JSONB
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    item JSONB;
    episode_content TEXT;
    new_embedding vector;
    memory_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    unit_id UUID;
    source_attr JSONB;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    span_from TIMESTAMPTZ;
    span_to TIMESTAMPTZ;
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    -- Scene metadata (#73): the memory carries when the experience happened
    -- (the units' time span), not just when consolidation ran — timeline
    -- queries and retention grouping key off lived time.
    SELECT min(turn_at), max(turn_at) INTO span_from, span_to
    FROM subconscious_units
    WHERE id = ANY(task.source_unit_ids);

    source_attr := jsonb_build_object(
        'kind', 'recmem',
        'ref', task.id::text,
        'label', 'RecMem episodic consolidation',
        'observed_at', CURRENT_TIMESTAMP,
        'trust', 0.9
    );

    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_episodes, '[]'::jsonb))
    LOOP
        episode_content := COALESCE(item->>'content', item->>'episode', item#>>'{}');
        IF NULLIF(trim(COALESCE(episode_content, '')), '') IS NULL THEN
            CONTINUE;
        END IF;

        new_embedding := (get_embedding(ARRAY[episode_content]))[1];
        memory_id := create_memory_with_embedding(
            'episodic',
            episode_content,
            new_embedding,
            COALESCE(NULLIF(item->>'importance', '')::float, 0.6),
            source_attr,
            0.9,
            jsonb_build_object('recmem', jsonb_strip_nulls(jsonb_build_object(
                'task_id', task.id,
                'source_unit_ids', task.source_unit_ids,
                'reason', task.task_payload->>'reason',
                'session_id', task.task_payload->>'session_id',
                'occurred_from', span_from,
                'occurred_to', span_to
            )))
        );
        created_ids := created_ids || memory_id;

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM link_memory_to_source_unit(memory_id, unit_id, 'source');
        END LOOP;

        -- semantic_refine retired (#57): see apply_recmem_episode_merge.
    END LOOP;

    IF cardinality(created_ids) = 0 THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'episode_create_empty', true,
                'task_id', p_task_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('memory_ids', created_ids, 'empty', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids, 'empty', true);
    END IF;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'episode_created',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('memory_ids', created_ids),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_chat_turn_memory(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id TEXT DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    started_at TIMESTAMPTZ := clock_timestamp();
    content TEXT;
    importance FLOAT;
    source_attribution JSONB;
    metadata JSONB;
    session_uuid UUID;
    raw JSONB;
    raw_unit_id UUID;
    promoted_memory_id UUID;
    promoted BOOLEAN := FALSE;
    duration_ms FLOAT;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'empty_turn');
    END IF;

    content := format_recmem_turn(
        COALESCE(p_user_text, ''),
        COALESCE(p_assistant_text, ''),
        NULLIF(p_context->>'user_label', '')
    );
    importance := COALESCE(
        NULLIF(p_context->>'importance', '')::FLOAT,
        estimate_conversation_importance(p_user_text, p_assistant_text)
    );
    metadata := COALESCE(p_context->'metadata', '{"type":"conversation"}'::jsonb);
    source_attribution := COALESCE(
        p_context->'source_attribution',
        jsonb_build_object(
            'kind', COALESCE(p_context #>> '{source_attribution_kind}', 'conversation'),
            'ref', COALESCE(p_source_identity, 'conversation_turn'),
            'label', COALESCE(p_context #>> '{source_attribution_label}', 'conversation turn'),
            'observed_at', CURRENT_TIMESTAMP,
            -- Conversational testimony enters at a config-owned default (#61):
            -- 0.95 belongs to verified provenance, not to whoever dialed in.
            'trust', COALESCE(
                NULLIF(p_context #>> '{trust}', '')::FLOAT,
                get_config_float('memory.conversation_turn_trust'),
                0.8)
        )
    );
    session_uuid := _db_brain_try_uuid(p_session_id);

    raw := recmem_ingest_turn(
        p_user_text,
        p_assistant_text,
        session_uuid,
        p_source_identity,
        CURRENT_TIMESTAMP,
        importance,
        source_attribution,
        metadata,
        NULLIF(p_context->>'user_label', '')
    );
    raw_unit_id := _db_brain_try_uuid(raw->>'unit_id');

    -- Direct promotion is a safety valve for truly exceptional single turns
    -- (#73): scene consolidation at session boundaries is the normal path to
    -- episodic memory, so the bar sits above the signal-phrase bump (0.8).
    IF importance >= COALESCE(get_config_float('memory.direct_promotion_min_importance'), 0.95) THEN
        promoted_memory_id := create_episodic_memory(
            content,
            NULL,
            jsonb_build_object('type', 'conversation', 'recmem', jsonb_build_object('direct_promoted', true)),
            NULL,
            0.0,
            CURRENT_TIMESTAMP,
            importance,
            source_attribution,
            0.95
        );
        promoted := TRUE;
        IF raw_unit_id IS NOT NULL THEN
            PERFORM link_memory_to_source_unit(promoted_memory_id, raw_unit_id, 'direct_promotion');
        END IF;
    END IF;

    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000.0;

    RETURN jsonb_build_object(
        'raw', COALESCE(raw, '{}'::jsonb),
        'raw_unit_id', raw_unit_id,
        'direct_promoted', promoted,
        'promoted_memory_id', promoted_memory_id,
        'importance', importance,
        'duration_ms', duration_ms
    );
END;
$$;

SELECT upsert_prompt_module(
    'recmem_episode_create',
    $pm$You create compact episodic memories — scenes — from raw user-assistant turns. The turns arrive time-ordered; when they come from one conversation session, you are remembering that conversation the way a person does afterward: as one or a few coherent scenes, each with its arc, its participants, and its emotional shape.

Respond only with JSON:

{
  "episodes": [
    {
      "content": "episodic narrative summary",
      "importance": 0.6
    }
  ]
}

Group related turns into the fewest useful episodes — a whole conversation usually yields one to three scenes. A scene is one coherent event: what happened, who said what that mattered, how it felt, and how it resolved or was left. Keep temporal sequence, names, and concrete details; note the emotional turn if there was one. Do not extract broad timeless facts here unless they are needed to explain the episode.
$pm$,
    'Seeded from services/prompts/recmem_episode_create.md',
    'services/prompts/recmem_episode_create.md'
);
