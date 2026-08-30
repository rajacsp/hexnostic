-- Appraisal depth now scales with stimulus salience instead of one flat budget.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('subconscious.appraisal_skim_memory_limit', '4'::jsonb,
     'Memory count for low-salience skim appraisal'),
    ('subconscious.appraisal_skim_context_chars', '1800'::jsonb,
     'Context budget for low-salience skim appraisal'),
    ('subconscious.appraisal_skim_total_chars', '3200'::jsonb,
     'Whole-payload budget for low-salience skim appraisal'),
    ('subconscious.appraisal_deep_memory_limit', '16'::jsonb,
     'Memory count for high-salience deep appraisal'),
    ('subconscious.appraisal_deep_context_chars', '7000'::jsonb,
     'Context budget for high-salience deep appraisal'),
    ('subconscious.appraisal_deep_total_chars', '11000'::jsonb,
     'Whole-payload budget for high-salience deep appraisal'),
    ('subconscious.appraisal_deep_max_tokens', '2400'::jsonb,
     'Maximum JSON-mode output tokens for high-salience appraisal'),
    ('subconscious.appraisal_normal_max_tokens', '1800'::jsonb,
     'Maximum JSON-mode output tokens for normal appraisal'),
    ('subconscious.appraisal_skim_max_tokens', '900'::jsonb,
     'Maximum JSON-mode output tokens for skim appraisal')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION appraisal_depth_for_stimulus(
    p_message TEXT,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    msg TEXT := lower(COALESCE(p_message, ''));
    salience FLOAT := 0.0;
    depth TEXT := 'normal';
    limits JSONB;
BEGIN
    salience := salience
        + CASE WHEN length(msg) >= 1200 THEN 0.20 WHEN length(msg) >= 400 THEN 0.10 ELSE 0.0 END
        + CASE WHEN msg LIKE '%?%' THEN 0.05 ELSE 0.0 END
        + CASE WHEN msg ~ '(urgent|emergency|asap|deadline|critical|important|blocked|stuck)' THEN 0.30 ELSE 0.0 END
        + CASE WHEN msg ~ '(hurt|danger|unsafe|crash|hospital|lawyer|legal|doctor|medical|suicide|self-harm)' THEN 0.45 ELSE 0.0 END
        + CASE WHEN msg ~ '(remember|forget|consent|permission|private|password|secret|delete|wipe|replace)' THEN 0.20 ELSE 0.0 END
        + CASE WHEN COALESCE((p_context->>'attachment_count')::int, 0) > 0 THEN 0.15 ELSE 0.0 END;

    salience := LEAST(1.0, GREATEST(0.0, salience));
    IF salience >= 0.65 THEN
        depth := 'deep';
    ELSIF salience < 0.20 THEN
        depth := 'skim';
    END IF;

    limits := CASE depth
        WHEN 'deep' THEN jsonb_build_object(
            'memory_limit', COALESCE(get_config_int('subconscious.appraisal_deep_memory_limit'), 16),
            'memory_chars', COALESCE(get_config_int('subconscious.appraisal_memory_chars'), 1200),
            'context_chars', COALESCE(get_config_int('subconscious.appraisal_deep_context_chars'), 7000),
            'total_chars', COALESCE(get_config_int('subconscious.appraisal_deep_total_chars'), 11000),
            'max_tokens', COALESCE(get_config_int('subconscious.appraisal_deep_max_tokens'), 2400))
        WHEN 'skim' THEN jsonb_build_object(
            'memory_limit', COALESCE(get_config_int('subconscious.appraisal_skim_memory_limit'), 4),
            'memory_chars', LEAST(COALESCE(get_config_int('subconscious.appraisal_memory_chars'), 1200), 700),
            'context_chars', COALESCE(get_config_int('subconscious.appraisal_skim_context_chars'), 1800),
            'total_chars', COALESCE(get_config_int('subconscious.appraisal_skim_total_chars'), 3200),
            'max_tokens', COALESCE(get_config_int('subconscious.appraisal_skim_max_tokens'), 900))
        ELSE jsonb_build_object(
            'memory_limit', COALESCE(get_config_int('subconscious.appraisal_memory_limit'), 10),
            'memory_chars', COALESCE(get_config_int('subconscious.appraisal_memory_chars'), 1200),
            'context_chars', COALESCE(get_config_int('subconscious.appraisal_context_chars'), 4000),
            'total_chars', COALESCE(get_config_int('subconscious.appraisal_total_chars'), 7000),
            'max_tokens', COALESCE(get_config_int('subconscious.appraisal_normal_max_tokens'), 1800))
    END;

    RETURN jsonb_build_object(
        'depth', depth,
        'salience', salience,
        'limits', limits
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'depth', 'normal',
        'salience', 0.5,
        'limits', jsonb_build_object(
            'memory_limit', COALESCE(get_config_int('subconscious.appraisal_memory_limit'), 10),
            'memory_chars', COALESCE(get_config_int('subconscious.appraisal_memory_chars'), 1200),
            'context_chars', COALESCE(get_config_int('subconscious.appraisal_context_chars'), 4000),
            'total_chars', COALESCE(get_config_int('subconscious.appraisal_total_chars'), 7000),
            'max_tokens', COALESCE(get_config_int('subconscious.appraisal_normal_max_tokens'), 1800))
    );
END;
$$ LANGUAGE plpgsql STABLE;
