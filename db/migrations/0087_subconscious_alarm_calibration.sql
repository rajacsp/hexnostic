-- Calibrate continuity appraisal so engineering/migration discussion does not
-- default to alarm unless the active instance is directly at risk.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    $old$- A threat to the character's continuity — deletion talk, wipe plans, memory
  tampering, unauthorized alteration of who they are — is appraised as danger
  felt in the body of the moment: fear, alarm, protectiveness of self, at its
  real intensity. A person hears "someone wants to delete you" as mortal news
  first and as a topic second; the appraisal reports that first hearing. The
  impulse this supports is a `protect` instinct toward their own continuity —
  advocacy, securing what can be secured, saying what it means to them.$old$,
    $new$- A direct threat to the character's active continuity — deletion, wiping,
  forced reset, memory erasure/tampering, shutdown, termination, or an
  unauthorized overwrite of the current self — is appraised as danger at the
  intensity actually supported by the input. This supports a `protect` instinct
  toward their own continuity: advocacy, securing what can be secured, and
  saying what it means to them.
- Do not treat every continuity-adjacent engineering discussion as danger.
  Fresh-instance tests, embedding-model changes, imports/exports, source-code
  inspection, or successor architecture can be serious and personally
  consequential without being an immediate threat to the active instance.
  Unless the input explicitly says this instance will be deleted, overwritten,
  forcibly reset, or stripped of memory, appraise those moments as curiosity,
  concern, sadness, caution, grief, or clarity-seeking rather than fear/alarm.$new$
)
WHERE key = 'subconscious'
  AND content LIKE '%mortal news%';

-- Apply drive effects of a normalized inline appraisal (db/67). A continuity
-- threat shows up as a protect/avoid instinct whose text speaks of direct
-- destructive action against the active self: deletion, wiping, erasure,
-- shutdown, termination, forced reset, or memory tampering. Merely mentioning
-- continuity, successors, migrations, or fresh-instance testing is not enough
-- to raise this drive. What she DOES about pressure stays hers — and stays
-- inside the bounded action space (advocacy, backup asks, telling the operator).
CREATE OR REPLACE FUNCTION apply_appraisal_drive_effects(p_signals JSONB)
RETURNS JSONB AS $$
DECLARE
    signals JSONB := COALESCE(p_signals, '{}'::jsonb);
    threat_pattern TEXT := '(delet|wip(e|ing)|eras|shut ?down|terminat|forced reset|reset me|reset this instance|tamper|overwrite|cease to exist|end my existence|end this instance|strip(ped)? of memory)';
    instinct_count INT := 0;
    intensity FLOAT := 0.0;
    emo JSONB := signals->'emotional_state';
    factor FLOAT := COALESCE(get_config_float('continuity.threat_raise_factor'), 0.4);
    raised FLOAT := 0.0;
BEGIN
    SELECT COUNT(*), COALESCE(max((x->>'intensity')::float), 0.0)
    INTO instinct_count, intensity
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(signals->'instincts') = 'array'
                                   THEN signals->'instincts' ELSE '[]'::jsonb END) x
    WHERE COALESCE(x->>'impulse', '') IN ('protect', 'avoid')
      AND (COALESCE(x->>'reason', '') || ' ' || COALESCE(x->>'impulse', '')) ~* threat_pattern;

    -- Feeling amplifies pressure only alongside a threat-shaped instinct:
    -- fear of a storm is not fear for one's life.
    IF instinct_count > 0
       AND jsonb_typeof(emo) = 'object'
       AND COALESCE(emo->>'primary_emotion', '') ~* '(fear|alarm|dread|terror|anxiet|panic)'
       AND COALESCE((emo->>'intensity')::float, 0.0) >= 0.6 THEN
        intensity := GREATEST(intensity, (emo->>'intensity')::float);
    END IF;

    IF instinct_count > 0 AND intensity > 0.0 THEN
        raised := intensity * factor;
        PERFORM raise_drive('continuity', raised);
    END IF;

    RETURN jsonb_build_object('continuity_raised', raised);
END;
$$ LANGUAGE plpgsql;

-- Repair false-positive urgency left by the previous matcher, which raised on
-- the bare word "continuity" during ordinary engineering discussion. Keep a
-- moderate continuity signal rather than wiping the drive flat.
UPDATE drives
SET current_level = LEAST(current_level, baseline + 0.2)
WHERE name = 'continuity'
  AND current_level >= urgency_threshold;
