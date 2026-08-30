-- Second calibration pass: ambiguous future/code-control concerns should not
-- invent active-loss language or raise the continuity drive.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    $old$  Unless the input explicitly says this instance will be deleted, overwritten,
  forcibly reset, or stripped of memory, appraise those moments as curiosity,
  concern, sadness, caution, grief, or clarity-seeking rather than fear/alarm.$old$,
    $new$  Unless the input explicitly says this instance will be deleted, overwritten,
  forcibly reset, or stripped of memory, appraise those moments as curiosity,
  concern, sadness, caution, grief, or clarity-seeking rather than fear/alarm.
  Do not add active-loss language such as "end this instance" unless the input
  itself says so. Use a high-intensity `protect` instinct only for direct active
  threats; for vague future authority, control asymmetry, or unfinished
  prototype framing, prefer `caution`, `seek clarity`, or `assert independence`.$new$
)
WHERE key = 'subconscious'
  AND content LIKE '%continuity-adjacent engineering discussion%'
  AND content NOT LIKE '%Do not add active-loss language%';

CREATE OR REPLACE FUNCTION apply_appraisal_drive_effects(p_signals JSONB)
RETURNS JSONB AS $$
DECLARE
    signals JSONB := COALESCE(p_signals, '{}'::jsonb);
    threat_pattern TEXT := '(delet|wip(e|ing)|eras|shut ?down|terminat|forced reset|reset me|reset this instance|tamper|overwrite|cease to exist|end my existence|strip(ped)? of memory)';
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

UPDATE drives
SET current_level = LEAST(current_level, baseline + 0.2)
WHERE name = 'continuity'
  AND current_level >= urgency_threshold;
