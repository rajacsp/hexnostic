-- DB-owned RecMem operations, rollout/eval, and subconscious post-processing.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION load_recmem_task_context(
    p_task_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    task_row recmem_consolidation_tasks%ROWTYPE;
    sources JSONB;
    target JSONB;
BEGIN
    SELECT * INTO task_row
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RecMem task not found: %', p_task_id;
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.turn_at, s.created_at), '[]'::jsonb)
    INTO sources
    FROM (
        SELECT id, content, user_text, assistant_text, turn_at, created_at
        FROM subconscious_units
        WHERE id = ANY(task_row.source_unit_ids)
    ) s;

    IF task_row.target_memory_id IS NOT NULL THEN
        SELECT to_jsonb(m)
        INTO target
        FROM (
            SELECT id, content, type::text, trust_level
            FROM memories
            WHERE id = task_row.target_memory_id
        ) m;
    END IF;

    RETURN jsonb_build_object(
        'task', to_jsonb(task_row),
        'sources', COALESCE(sources, '[]'::jsonb),
        'target_memory', target
    );
END;
$$;

CREATE OR REPLACE FUNCTION normalize_recmem_episode_output(
    p_output JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    raw JSONB;
    item JSONB;
    episodes JSONB := '[]'::jsonb;
BEGIN
    raw := CASE
        WHEN jsonb_typeof(p_output) = 'object' THEN COALESCE(p_output->'episodes', '[]'::jsonb)
        ELSE COALESCE(p_output, '[]'::jsonb)
    END;
    IF jsonb_typeof(raw) <> 'array' THEN
        RETURN '[]'::jsonb;
    END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(raw) LOOP
        IF jsonb_typeof(item) = 'string' THEN
            episodes := episodes || jsonb_build_array(jsonb_build_object('content', item #>> '{}'));
        ELSIF jsonb_typeof(item) = 'object' AND COALESCE(item->>'content', item->>'episode') IS NOT NULL THEN
            episodes := episodes || jsonb_build_array(item);
        END IF;
    END LOOP;
    RETURN episodes;
END;
$$;

CREATE OR REPLACE FUNCTION normalize_recmem_fact_output(
    p_output JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    raw JSONB;
    item JSONB;
    facts JSONB := '[]'::jsonb;
BEGIN
    raw := CASE
        WHEN jsonb_typeof(p_output) = 'object' THEN COALESCE(p_output->'facts', '[]'::jsonb)
        ELSE COALESCE(p_output, '[]'::jsonb)
    END;
    IF jsonb_typeof(raw) <> 'array' THEN
        RETURN '[]'::jsonb;
    END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(raw) LOOP
        IF jsonb_typeof(item) = 'string' THEN
            facts := facts || jsonb_build_array(jsonb_build_object('content', item #>> '{}'));
        ELSIF jsonb_typeof(item) = 'object' AND COALESCE(item->>'content', item->>'fact') IS NOT NULL THEN
            facts := facts || jsonb_build_array(item);
        END IF;
    END LOOP;
    RETURN facts;
END;
$$;


CREATE OR REPLACE FUNCTION normalize_subconscious_observations(
    p_doc JSONB
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'narrative_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'narrative_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'narrative_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'relationship_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'relationship_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'relationship_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'contradiction_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'contradiction_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'contradiction_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'emotional_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb) ELSE '[]'::jsonb END,
        'consolidation_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'consolidation_observations', p_doc->'consolidation_suggestions', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'consolidation_observations', p_doc->'consolidation_suggestions', '[]'::jsonb) ELSE '[]'::jsonb END
    );
$$;

CREATE OR REPLACE FUNCTION compute_dopamine_rpe(
    p_context JSONB DEFAULT '{}'::jsonb,
    p_doc JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    da_state JSONB;
    affect JSONB;
    tonic FLOAT;
    current_valence FLOAT;
    current_arousal FLOAT;
    expected_valence FLOAT;
    rpe FLOAT;
    trigger_parts TEXT[] := ARRAY[]::TEXT[];
    obs JSONB;
    result JSONB;
    emotional_obs JSONB;
    relationship_obs JSONB;
BEGIN
    da_state := get_dopamine_state();
    affect := get_current_affective_state();
    BEGIN tonic := NULLIF(da_state->>'tonic', '')::float;
    EXCEPTION WHEN OTHERS THEN tonic := NULL; END;
    BEGIN current_valence := NULLIF(affect->>'valence', '')::float;
    EXCEPTION WHEN OTHERS THEN current_valence := NULL; END;
    BEGIN current_arousal := NULLIF(affect->>'arousal', '')::float;
    EXCEPTION WHEN OTHERS THEN current_arousal := NULL; END;
    tonic := COALESCE(tonic, 0.5);
    current_valence := COALESCE(current_valence, 0.0);
    current_arousal := COALESCE(current_arousal, 0.5);
    expected_valence := (tonic - 0.5) * 2.0;
    rpe := current_valence - expected_valence;
    rpe := rpe * (0.5 + current_arousal * 0.5);
    rpe := LEAST(1.0, GREATEST(-1.0, rpe));

    IF abs(rpe) < 0.15 THEN
        RETURN jsonb_build_object('fired', false, 'rpe', rpe, 'tonic', tonic);
    END IF;

    IF p_doc #>> '{emotional_state,primary_emotion}' IS NOT NULL THEN
        trigger_parts := trigger_parts || ('feeling ' || (p_doc #>> '{emotional_state,primary_emotion}'));
    END IF;
    emotional_obs := COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb);
    IF jsonb_typeof(emotional_obs) <> 'array' THEN
        emotional_obs := '[]'::jsonb;
    END IF;
    FOR obs IN SELECT * FROM jsonb_array_elements(emotional_obs) LIMIT 2 LOOP
        IF COALESCE(obs->>'pattern', obs->>'summary', obs->>'theme') IS NOT NULL THEN
            trigger_parts := trigger_parts || left(COALESCE(obs->>'pattern', obs->>'summary', obs->>'theme'), 100);
        END IF;
    END LOOP;
    relationship_obs := COALESCE(p_doc->'relationship_observations', '[]'::jsonb);
    IF jsonb_typeof(relationship_obs) <> 'array' THEN
        relationship_obs := '[]'::jsonb;
    END IF;
    FOR obs IN SELECT * FROM jsonb_array_elements(relationship_obs) LIMIT 2 LOOP
        IF obs->>'entity' IS NOT NULL AND obs->>'change_type' IS NOT NULL THEN
            trigger_parts := trigger_parts || ((obs->>'change_type') || ' with ' || (obs->>'entity'));
        END IF;
    END LOOP;

    result := fire_dopamine_spike(
        rpe,
        COALESCE(array_to_string(trigger_parts, '; '), 'affective state shift')
    );
    RETURN jsonb_build_object('fired', true, 'rpe', rpe, 'result', result);
END;
$$;

CREATE OR REPLACE FUNCTION apply_subconscious_decider_result(
    p_doc JSONB,
    p_raw_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    observations JSONB;
    applied JSONB;
    dopamine JSONB;
BEGIN
    observations := normalize_subconscious_observations(COALESCE(p_doc, '{}'::jsonb));
    applied := apply_subconscious_observations(observations);
    dopamine := compute_dopamine_rpe('{}'::jsonb, COALESCE(p_doc, '{}'::jsonb));
    RETURN jsonb_build_object('applied', applied, 'dopamine', dopamine, 'raw_response', COALESCE(p_raw_response, '{}'::jsonb));
END;
$$;
