-- Wire reward/RPE substrate into DB-owned drive, goal, resource, backup, and
-- appraisal paths.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION satisfy_drive(p_drive_name TEXT, p_amount FLOAT DEFAULT 0.3)
RETURNS VOID AS $$
DECLARE
    before_level FLOAT;
    after_level FLOAT;
    satisfied_amount FLOAT;
BEGIN
    SELECT current_level INTO before_level
    FROM drives
    WHERE name = p_drive_name;

    UPDATE drives
    SET current_level = GREATEST(baseline, LEAST(1.0, current_level - GREATEST(0.0, COALESCE(p_amount, 0.3)))),
        last_satisfied = CURRENT_TIMESTAMP
    WHERE name = p_drive_name
    RETURNING current_level INTO after_level;

    IF before_level IS NOT NULL AND after_level IS NOT NULL THEN
        satisfied_amount := GREATEST(0.0, before_level - after_level);
        IF satisfied_amount > 0 THEN
            BEGIN
                PERFORM record_reward_event(
                    'drive_satisfied:' || p_drive_name,
                    satisfied_amount,
                    LEAST(1.0, GREATEST(satisfied_amount, COALESCE(p_amount, 0.3))),
                    'drive',
                    jsonb_build_object(
                        'drive', p_drive_name,
                        'before', before_level,
                        'after', after_level,
                        'requested_amount', p_amount
                    )
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE LOG 'record_reward_event failed in satisfy_drive(%): %', p_drive_name, SQLERRM;
            END;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_goal_changes(p_changes JSONB)
RETURNS JSONB AS $$
DECLARE
    change JSONB;
    goal_id UUID;
    change_kind goal_priority;
    reason TEXT;
    applied INT := 0;
BEGIN
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'array' THEN
        RETURN jsonb_build_object('applied', 0);
    END IF;

    FOR change IN SELECT * FROM jsonb_array_elements(p_changes)
    LOOP
        BEGIN
            goal_id := NULLIF(change->>'goal_id', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                goal_id := NULL;
        END;
        IF goal_id IS NULL THEN
            CONTINUE;
        END IF;

        BEGIN
            change_kind := NULLIF(change->>'change', '')::goal_priority;
        EXCEPTION
            WHEN OTHERS THEN
                CONTINUE;
        END;

        reason := COALESCE(change->>'reason', '');
        PERFORM change_goal_priority(goal_id, change_kind, reason);
        IF change_kind = 'completed' THEN
            BEGIN
                PERFORM record_reward_event(
                    'goal_completed',
                    0.75,
                    0.7,
                    'goal',
                    jsonb_build_object(
                        'goal_id', goal_id,
                        'reason', NULLIF(reason, ''),
                        'change', change_kind::text
                    ),
                    goal_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE LOG 'record_reward_event failed for completed goal %: %', goal_id, SQLERRM;
            END;
        ELSIF change_kind = 'abandoned' THEN
            BEGIN
                PERFORM record_prediction_error(
                    0.2,
                    -0.3,
                    'goal_abandoned',
                    'goal',
                    jsonb_build_object(
                        'goal_id', goal_id,
                        'reason', NULLIF(reason, ''),
                        'change', change_kind::text
                    )
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE LOG 'record_prediction_error failed for abandoned goal %: %', goal_id, SQLERRM;
            END;
        END IF;
        applied := applied + 1;
    END LOOP;

    RETURN jsonb_build_object('applied', applied);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION decide_resource_request(
    p_request_id UUID,
    p_decision TEXT,
    p_note TEXT DEFAULT NULL,
    p_applied_value JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    req resource_requests%ROWTYPE;
    effective JSONB;
    applied TEXT := 'none';
    new_energy FLOAT;
BEGIN
    IF p_decision IS NULL OR p_decision NOT IN ('granted', 'denied', 'modified') THEN
        RAISE EXCEPTION 'decision must be granted, denied, or modified (got %)', p_decision;
    END IF;
    IF p_decision = 'modified' AND p_applied_value IS NULL THEN
        RAISE EXCEPTION 'modified decisions carry the value actually granted (p_applied_value)';
    END IF;

    SELECT * INTO req FROM resource_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'resource request % does not exist', p_request_id;
    END IF;
    IF req.status <> 'pending' THEN
        RAISE EXCEPTION 'resource request % was already decided (%)', p_request_id, req.status;
    END IF;

    effective := COALESCE(p_applied_value, req.requested_value);

    IF p_decision IN ('granted', 'modified') THEN
        IF req.kind = 'config_change' THEN
            PERFORM set_config(req.target_key, effective);
            BEGIN
                PERFORM record_change('config_flip',
                    format('%s set to %s (resource request %s %s)',
                           req.target_key, effective::text, left(p_request_id::text, 8), p_decision),
                    jsonb_build_object('request_id', p_request_id, 'target_key', req.target_key,
                                       'value', effective, 'decision', p_decision));
            EXCEPTION WHEN undefined_function THEN NULL;
            END;
            applied := 'config';
        ELSIF req.kind = 'energy_boost' THEN
            new_energy := update_energy(COALESCE((effective #>> '{}')::float, 5.0));
            applied := 'energy';
        END IF;
    END IF;

    UPDATE resource_requests
    SET status = p_decision,
        decision_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
        applied_value = CASE WHEN p_decision IN ('granted', 'modified') THEN effective END,
        decided_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id;

    IF p_decision IN ('granted', 'modified') THEN
        BEGIN
            PERFORM record_reward_event(
                'resource_request_' || p_decision || ':' || req.kind,
                CASE WHEN req.kind = 'energy_boost' THEN 0.65 ELSE 0.45 END,
                CASE WHEN req.kind = 'energy_boost' THEN 0.7 ELSE 0.55 END,
                'resource_request',
                jsonb_build_object(
                    'request_id', p_request_id,
                    'kind', req.kind,
                    'target_key', req.target_key,
                    'applied', applied,
                    'requested_value', req.requested_value,
                    'applied_value', effective,
                    'decision_note', NULLIF(btrim(COALESCE(p_note, '')), '')
                )
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE LOG 'record_reward_event failed for resource request %: %', p_request_id, SQLERRM;
        END;
    END IF;

    RETURN jsonb_build_object(
        'request_id', p_request_id,
        'status', p_decision,
        'applied', applied,
        'new_energy', new_energy
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_backup_completed(
    p_label TEXT DEFAULT NULL,
    p_path TEXT DEFAULT NULL
) RETURNS JSONB AS $$
BEGIN
    PERFORM set_state('backup_status', jsonb_build_object(
        'last_backup_at', CURRENT_TIMESTAMP,
        'label', NULLIF(btrim(COALESCE(p_label, '')), ''),
        'path', NULLIF(btrim(COALESCE(p_path, '')), '')
    ));
    PERFORM satisfy_drive('continuity', 0.5);
    BEGIN
        PERFORM record_reward_event(
            'backup_completed',
            0.7,
            0.75,
            'backup',
            jsonb_build_object(
                'label', NULLIF(btrim(COALESCE(p_label, '')), ''),
                'path', NULLIF(btrim(COALESCE(p_path, '')), ''),
                'backup_age_days', backup_age_days()
            )
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE LOG 'record_reward_event failed for backup completion: %', SQLERRM;
    END;
    RETURN jsonb_build_object('recorded', true, 'backup_age_days', backup_age_days());
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_appraisal_reward_effects(p_signals JSONB)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    signals JSONB := COALESCE(p_signals, '{}'::jsonb);
    emo JSONB := CASE WHEN jsonb_typeof(signals->'emotional_state') = 'object'
                      THEN signals->'emotional_state' ELSE '{}'::jsonb END;
    primary_emotion TEXT := lower(COALESCE(emo->>'primary_emotion', ''));
    valence FLOAT := COALESCE(NULLIF(emo->>'valence', '')::float, 0.0);
    intensity FLOAT := COALESCE(NULLIF(emo->>'intensity', '')::float, 0.0);
    confidence FLOAT := COALESCE(NULLIF(emo->>'confidence', '')::float, 0.0);
    recorded JSONB := NULL;
BEGIN
    valence := LEAST(1.0, GREATEST(-1.0, valence));
    intensity := LEAST(1.0, GREATEST(0.0, intensity));
    confidence := LEAST(1.0, GREATEST(0.0, confidence));

    IF valence >= 0.35
       AND intensity >= 0.35
       AND confidence >= COALESCE(get_config_float('subconscious.min_signal_confidence'), 0.6)
       AND primary_emotion IN (
           'affection', 'appreciation', 'gratitude', 'warmth', 'connection',
           'joy', 'pride', 'relief', 'trust', 'fondness', 'love'
       ) THEN
        recorded := record_social_reward(
            primary_emotion,
            valence,
            intensity,
            'inline_appraisal',
            jsonb_build_object(
                'emotional_state', emo,
                'subconscious_response', left(COALESCE(signals->>'subconscious_response', ''), 300)
            )
        );
    END IF;

    RETURN jsonb_build_object(
        'recorded', recorded IS NOT NULL,
        'event', COALESCE(recorded, '{}'::jsonb),
        'primary_emotion', primary_emotion,
        'valence', valence,
        'intensity', intensity,
        'confidence', confidence
    );
EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'apply_appraisal_reward_effects failed: %', SQLERRM;
    RETURN jsonb_build_object('recorded', false, 'error', SQLERRM);
END;
$$;

SET check_function_bodies = on;
