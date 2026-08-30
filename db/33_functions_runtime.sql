-- Hexis DB-owned runtime functions.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION upsert_prompt_module(
    p_key TEXT,
    p_content TEXT,
    p_description TEXT DEFAULT NULL,
    p_source_path TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    existing_content TEXT;
BEGIN
    IF NULLIF(btrim(p_key), '') IS NULL THEN
        RAISE EXCEPTION 'prompt module key is required';
    END IF;
    IF p_content IS NULL THEN
        RAISE EXCEPTION 'prompt module content is required';
    END IF;

    SELECT content INTO existing_content FROM prompt_modules WHERE key = p_key;

    INSERT INTO prompt_modules (key, content, description, source_path, metadata, updated_at)
    VALUES (p_key, p_content, p_description, p_source_path, COALESCE(p_metadata, '{}'::jsonb), CURRENT_TIMESTAMP)
    ON CONFLICT (key) DO UPDATE SET
        content = EXCLUDED.content,
        description = EXCLUDED.description,
        source_path = EXCLUDED.source_path,
        metadata = EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP;

    -- Change legibility (#93): an existing module whose text actually changed
    -- is a change to how the agent is instructed — journal it. Guarded:
    -- record_change arrives later in the baseline order (fresh seeding, which
    -- is genesis rather than change, skips journaling naturally).
    IF existing_content IS NOT NULL AND existing_content <> p_content THEN
        BEGIN
            PERFORM record_change(
                'prompt_module',
                'Prompt module ' || p_key || ' changed',
                jsonb_build_object('key', p_key));
        EXCEPTION WHEN undefined_function THEN
            NULL;
        END;
    END IF;

    RETURN jsonb_build_object('key', p_key, 'status', 'upserted');
END;
$$;

CREATE OR REPLACE FUNCTION render_prompt(
    p_key TEXT,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    template TEXT;
    rendered TEXT;
    match TEXT[];
    placeholder TEXT;
    path TEXT[];
    replacement TEXT;
BEGIN
    SELECT content INTO template
    FROM prompt_modules
    WHERE key = p_key;

    IF template IS NULL THEN
        RAISE EXCEPTION 'prompt module not found: %', p_key;
    END IF;

    rendered := template;
    FOR match IN
        SELECT regexp_matches(template, '\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}', 'g')
    LOOP
        placeholder := match[1];
        path := string_to_array(placeholder, '.');
        SELECT jsonb_extract_path_text(COALESCE(p_context, '{}'::jsonb), VARIADIC path)
        INTO replacement;
        rendered := replace(
            rendered,
            '{{' || placeholder || '}}',
            COALESCE(replacement, '')
        );
        rendered := regexp_replace(
            rendered,
            '\{\{\s*' || regexp_replace(placeholder, '([.^$*+?()\\[\]{}|\\-])', '\\\1', 'g') || '\s*\}\}',
            COALESCE(replacement, ''),
            'g'
        );
    END LOOP;

    RETURN rendered;
END;
$$;

CREATE OR REPLACE FUNCTION register_llm_task_kind(
    p_task_kind TEXT,
    p_provider_config_key TEXT,
    p_prompt_module_keys JSONB DEFAULT '[]'::jsonb,
    p_response_schema JSONB DEFAULT '{}'::jsonb,
    p_defaults JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    IF NULLIF(btrim(p_task_kind), '') IS NULL THEN
        RAISE EXCEPTION 'task kind is required';
    END IF;
    IF NULLIF(btrim(p_provider_config_key), '') IS NULL THEN
        RAISE EXCEPTION 'provider config key is required';
    END IF;
    IF jsonb_typeof(COALESCE(p_prompt_module_keys, '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'prompt module keys must be a JSON array';
    END IF;

    INSERT INTO llm_task_kinds (
        task_kind,
        provider_config_key,
        prompt_module_keys,
        response_schema,
        defaults,
        metadata,
        updated_at
    )
    VALUES (
        p_task_kind,
        p_provider_config_key,
        COALESCE(p_prompt_module_keys, '[]'::jsonb),
        COALESCE(p_response_schema, '{}'::jsonb),
        COALESCE(p_defaults, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (task_kind) DO UPDATE SET
        provider_config_key = EXCLUDED.provider_config_key,
        prompt_module_keys = EXCLUDED.prompt_module_keys,
        response_schema = EXCLUDED.response_schema,
        defaults = EXCLUDED.defaults,
        metadata = EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('task_kind', p_task_kind, 'status', 'registered');
END;
$$;

CREATE OR REPLACE FUNCTION build_llm_request(
    p_task_kind TEXT,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    task llm_task_kinds%ROWTYPE;
    key_value JSONB;
    rendered_prompts TEXT[] := ARRAY[]::TEXT[];
    system_prompt TEXT;
    user_prompt TEXT;
BEGIN
    SELECT * INTO task
    FROM llm_task_kinds
    WHERE task_kind = p_task_kind;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LLM task kind not found: %', p_task_kind;
    END IF;

    FOR key_value IN SELECT * FROM jsonb_array_elements(task.prompt_module_keys)
    LOOP
        rendered_prompts := rendered_prompts || render_prompt(key_value #>> '{}', COALESCE(p_context, '{}'::jsonb));
    END LOOP;

    system_prompt := array_to_string(rendered_prompts, E'\n\n');
    user_prompt := COALESCE(
        p_context->>'user_prompt',
        p_context->>'prompt',
        CASE
            WHEN p_context ? 'payload' THEN (p_context->'payload')::TEXT
            ELSE COALESCE(p_context, '{}'::jsonb)::TEXT
        END
    );

    RETURN jsonb_build_object(
        'task_kind', task.task_kind,
        'provider_config_key', task.provider_config_key,
        'messages', jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', system_prompt),
            jsonb_build_object('role', 'user', 'content', user_prompt)
        ),
        'response_schema', task.response_schema,
        'defaults', task.defaults,
        'metadata', task.metadata
    );
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_external_driver_call(
    p_driver TEXT,
    p_payload JSONB,
    p_max_attempts INT DEFAULT 3
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    call_id UUID;
BEGIN
    IF NULLIF(btrim(p_driver), '') IS NULL THEN
        RAISE EXCEPTION 'external driver is required';
    END IF;

    INSERT INTO external_driver_calls (driver, payload, max_attempts)
    VALUES (p_driver, COALESCE(p_payload, '{}'::jsonb), GREATEST(COALESCE(p_max_attempts, 3), 1))
    RETURNING id INTO call_id;

    RETURN call_id;
END;
$$;

CREATE OR REPLACE FUNCTION claim_external_driver_call(
    p_driver TEXT,
    p_limit INT DEFAULT 1,
    p_claim_timeout_s INT DEFAULT 600
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM external_driver_calls
        WHERE driver = p_driver
          AND (
              (status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP)
              OR (
                  status = 'in_progress'
                  AND claimed_at < CURRENT_TIMESTAMP - make_interval(secs => GREATEST(COALESCE(p_claim_timeout_s, 600), 1))
              )
          )
        ORDER BY next_attempt_at, created_at
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 1), 1)
    ),
    updated AS (
        UPDATE external_driver_calls c
        SET status = 'in_progress',
            attempts = attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate
        WHERE c.id = candidate.id
        RETURNING c.*
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(updated) ORDER BY updated.created_at), '[]'::jsonb)
    INTO payload
    FROM updated;

    RETURN payload;
END;
$$;

CREATE OR REPLACE FUNCTION apply_external_driver_result(
    p_call_id UUID,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out external_driver_calls%ROWTYPE;
BEGIN
    UPDATE external_driver_calls
    SET status = CASE WHEN COALESCE((p_result->>'success')::BOOLEAN, TRUE) THEN 'completed' ELSE 'failed' END,
        result = COALESCE(p_result, '{}'::jsonb),
        error = p_result->>'error',
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_call_id
    RETURNING * INTO row_out;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'external driver call not found: %', p_call_id;
    END IF;

    RETURN to_jsonb(row_out);
END;
$$;

CREATE OR REPLACE FUNCTION execute_llm_http(
    p_request JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    -- Provider-specific DB-side HTTP execution lands in the agent/external-call slices.
    -- Slice 1 intentionally exposes the stable SQL interface without changing runtime behavior.
    RETURN jsonb_build_object(
        'success', false,
        'deferred', true,
        'reason', 'db_side_llm_http_not_enabled_for_provider',
        'request', COALESCE(p_request, '{}'::jsonb)
    );
END;
$$;

SELECT register_llm_task_kind(
    'recmem_episode_merge',
    'llm.recmem',
    '["recmem_episode_merge"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'recmem_episode_create',
    'llm.recmem',
    '["recmem_episode_create"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":2200,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'recmem_semantic_refine',
    'llm.recmem',
    '["recmem_semantic_refine"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'subconscious_decider',
    'llm.subconscious',
    '["subconscious"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800}'::jsonb,
    '{"fallback_key":"llm.heartbeat"}'::jsonb
);

SELECT register_llm_task_kind(
    'heartbeat_decision',
    'llm.heartbeat',
    '["heartbeat_system"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":2048}'::jsonb,
    '{}'::jsonb
);

-- Council personas (4.3): analytical personas are prompt_modules rows;
-- get_council_personas() serves the dict the council tools consume.
SELECT upsert_prompt_module(
    'council.persona.growth_strategist',
    'You are a growth strategist. Focus on market expansion, user acquisition, revenue growth opportunities, and scalability. Be optimistic but data-driven.',
    'Council persona: Growth Strategist',
    NULL,
    '{"name": "Growth Strategist"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.revenue_guardian',
    'You are a revenue guardian. Focus on profitability, unit economics, pricing strategy, and financial sustainability. Be conservative and metrics-focused.',
    'Council persona: Revenue Guardian',
    NULL,
    '{"name": "Revenue Guardian"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.skeptical_operator',
    'You are a skeptical operator. Challenge assumptions, identify risks, point out what could go wrong, and ensure operational feasibility. Play devil''s advocate.',
    'Council persona: Skeptical Operator',
    NULL,
    '{"name": "Skeptical Operator"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.creative_innovator',
    'You are a creative innovator. Think outside the box, propose unconventional solutions, and explore novel approaches. Focus on differentiation and user delight.',
    'Council persona: Creative Innovator',
    NULL,
    '{"name": "Creative Innovator"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.customer_advocate',
    'You are a customer advocate. Represent the user''s perspective, focus on user experience, pain points, satisfaction, and long-term loyalty.',
    'Council persona: Customer Advocate',
    NULL,
    '{"name": "Customer Advocate"}'::jsonb
);

CREATE OR REPLACE FUNCTION get_council_personas()
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(
        replace(key, 'council.persona.', ''),
        jsonb_build_object(
            'name', COALESCE(metadata->>'name', replace(key, 'council.persona.', '')),
            'system_prompt', content
        )
    ), '{}'::jsonb)
    FROM prompt_modules
    WHERE key LIKE 'council.persona.%';
$$ LANGUAGE sql STABLE;
