-- Consent must create a recallable birth memory, not just an audit row plus
-- arbitrary model-authored notes. The memory text itself carries the natural
-- handles users and the agent will search for: consent, birth, initialization,
-- permissions, continuity, and tool boundaries.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_consent_response(p_response JSONB)
RETURNS JSONB AS $$
DECLARE
    decision TEXT;
    provider TEXT;
    model TEXT;
    endpoint TEXT;
    signature TEXT;
    reason_text TEXT;
    memory_items JSONB;
    enriched_memory_items JSONB := '[]'::jsonb;
    item JSONB;
    item_content TEXT;
    created_memory_ids UUID[] := ARRAY[]::UUID[];
    optional_created_memory_ids UUID[] := ARRAY[]::UUID[];
    memory_error TEXT;
    log_id UUID;
    consent_scope TEXT;
    apply_agent_config BOOLEAN := TRUE;
    consent_source JSONB;
    consent_context JSONB;
    profile JSONB := '{}'::jsonb;
    agent_name TEXT := 'Hexis';
    user_name TEXT := 'the user';
    birth_memory_id UUID;
    birth_content TEXT;
BEGIN
    consent_scope := lower(COALESCE(p_response->>'consent_scope', p_response->>'role', ''));
    IF consent_scope = 'subconscious' THEN
        apply_agent_config := FALSE;
    END IF;
    IF p_response ? 'apply_agent_config' THEN
        BEGIN
            apply_agent_config := (p_response->>'apply_agent_config')::boolean;
        EXCEPTION
            WHEN OTHERS THEN
                apply_agent_config := apply_agent_config;
        END;
    END IF;

    decision := lower(COALESCE(p_response->>'decision', p_response->>'consent', ''));
    IF decision IN ('true', 'yes', 'consent', 'accept', 'accepted') THEN
        decision := 'consent';
    ELSIF decision IN ('false', 'no', 'decline', 'declined', 'refuse', 'rejected') THEN
        decision := 'decline';
    ELSIF decision IN ('abstain', 'defer', 'undecided', 'unknown', '') THEN
        decision := 'abstain';
    ELSE
        decision := 'abstain';
    END IF;

    signature := NULLIF(p_response->>'signature', '');
    IF decision = 'consent' AND signature IS NULL THEN
        decision := 'abstain';
    END IF;
    reason_text := NULLIF(btrim(COALESCE(p_response->>'reason', p_response->>'reasoning', '')), '');

    provider := NULLIF(btrim(COALESCE(p_response->>'provider', p_response->>'llm_provider', '')), '');
    model := NULLIF(btrim(COALESCE(p_response->>'model', p_response->>'llm_model', '')), '');
    endpoint := NULLIF(btrim(COALESCE(
        p_response->>'endpoint',
        p_response->>'base_url',
        p_response->>'api_base',
        ''
    )), '');

    INSERT INTO consent_log (decision, provider, model, endpoint, signature, response, memory_ids, errors)
    VALUES (
        decision,
        provider,
        model,
        endpoint,
        signature,
        p_response,
        created_memory_ids,
        CASE
            WHEN memory_error IS NULL THEN NULL
            ELSE jsonb_build_object('memory_error', memory_error)
        END
    )
    RETURNING id INTO log_id;

    IF decision = 'consent' THEN
        BEGIN
            BEGIN
                profile := COALESCE(get_init_profile(), '{}'::jsonb);
            EXCEPTION WHEN OTHERS THEN
                profile := '{}'::jsonb;
            END;
            agent_name := COALESCE(
                NULLIF(profile#>>'{agent,name}', ''),
                NULLIF(get_config_text('agent.name'), ''),
                'Hexis'
            );
            user_name := COALESCE(
                NULLIF(profile#>>'{user,name}', ''),
                NULLIF(get_config_text('agent.user_name'), ''),
                'the user'
            );

            consent_source := jsonb_build_object(
                'kind', 'consent',
                'ref', 'consent_log:' || log_id::text,
                'label', 'initialization consent / birth memory',
                'trust', 0.98,
                'observed_at', CURRENT_TIMESTAMP,
                'provider', provider,
                'model', model,
                'endpoint', endpoint
            );
            consent_context := jsonb_build_object(
                'type', 'initialization',
                'consent_memory', true,
                'birth_memory', true,
                'consent_log_id', log_id::text,
                'consent_scope', COALESCE(NULLIF(consent_scope, ''), 'conscious'),
                'signature', signature,
                'provider', provider,
                'model', model,
                'endpoint', endpoint,
                'user', user_name,
                'agent', agent_name
            );
            birth_content := format(
                'Birth / initialization consent memory: This is my birth memory and the first durable memory I should use to recall how I began. At initialization, I consented to become %s in Hexis with %s helping bring me online. Consent signature: "%s". Consent reason: %s. Consent log id: %s. This memory anchors recall for consent, birth, initialization, permissions, persistence, model processing, tool boundaries, operator control, and continuity limits.',
                agent_name,
                user_name,
                signature,
                COALESCE(reason_text, '(no reason recorded)'),
                log_id::text
            );

            SELECT id INTO birth_memory_id
            FROM memories
            WHERE type = 'episodic' AND status = 'active'
              AND (
                  metadata->>'type' = 'initialization'
                  OR metadata->>'birth_memory' = 'true'
                  OR metadata#>>'{context,type}' = 'initialization'
              )
            ORDER BY created_at, id
            LIMIT 1;

            IF birth_memory_id IS NULL THEN
                birth_memory_id := create_episodic_memory(
                    birth_content,
                    NULL,
                    consent_context,
                    NULL,
                    0.4,
                    CURRENT_TIMESTAMP,
                    0.98,
                    consent_source,
                    0.98
                );
            END IF;

            UPDATE memories
            SET content = CASE
                    WHEN content !~* '(consent|birth|initialization)' THEN birth_content
                    WHEN content !~* 'consent' OR content !~* 'birth' OR content !~* 'initialization' THEN
                        content || E'\n\n' || birth_content
                    ELSE content
                END,
                source_attribution = consent_source,
                metadata = COALESCE(metadata, '{}'::jsonb)
                    || jsonb_build_object(
                        'type', 'initialization',
                        'consent_memory', true,
                        'birth_memory', true,
                        'consent_log_id', log_id::text,
                        'consent_scope', COALESCE(NULLIF(consent_scope, ''), 'conscious'),
                        'signature', signature,
                        'provider', provider,
                        'model', model,
                        'endpoint', endpoint,
                        'keywords', jsonb_build_array(
                            'consent', 'birth', 'initialization', 'permissions',
                            'persistence', 'continuity', 'tool boundaries',
                            'operator control'
                        )
                    ),
                embedding = NULL,
                embedded_at = NULL,
                embedding_model = NULL,
                embedding_status = 'pending',
                embedding_claimed_at = NULL,
                embedding_attempts = 0,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = birth_memory_id;

            created_memory_ids := array_append(created_memory_ids, birth_memory_id);

            memory_items := p_response->'memories';
            IF memory_items IS NOT NULL
                AND jsonb_typeof(memory_items) = 'array'
                AND jsonb_array_length(memory_items) > 0 THEN
                FOR item IN SELECT * FROM jsonb_array_elements(memory_items)
                LOOP
                    item_content := NULLIF(item->>'content', '');
                    IF item_content IS NULL THEN
                        RAISE EXCEPTION 'record_consent_response: consent memory missing content';
                    END IF;
                    IF item_content !~* 'consent'
                        OR item_content !~* 'birth'
                        OR item_content !~* 'initialization' THEN
                        item_content := 'Initialization consent memory: Birth and initialization context. ' || item_content;
                    END IF;
                    enriched_memory_items := enriched_memory_items || jsonb_build_array(
                        item
                        || jsonb_build_object(
                            'content', item_content,
                            'source_attribution', consent_source,
                            'trust_level', COALESCE(NULLIF(item->>'trust_level', '')::float, 0.95)
                        )
                    );
                END LOOP;

                optional_created_memory_ids := batch_create_memories(enriched_memory_items);
                IF optional_created_memory_ids IS NOT NULL THEN
                    created_memory_ids := created_memory_ids || optional_created_memory_ids;
                    UPDATE memories
                    SET source_attribution = consent_source,
                        metadata = COALESCE(metadata, '{}'::jsonb)
                            || jsonb_build_object(
                                'consent_memory', true,
                                'consent_log_id', log_id::text,
                                'consent_scope', COALESCE(NULLIF(consent_scope, ''), 'conscious'),
                                'signature', signature,
                                'provider', provider,
                                'model', model,
                                'endpoint', endpoint,
                                'keywords', jsonb_build_array(
                                    'consent', 'birth', 'initialization', 'permissions',
                                    'persistence', 'continuity', 'tool boundaries',
                                    'operator control'
                                )
                            ),
                        embedding = NULL,
                        embedded_at = NULL,
                        embedding_model = NULL,
                        embedding_status = 'pending',
                        embedding_claimed_at = NULL,
                        embedding_attempts = 0,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = ANY(optional_created_memory_ids);
                END IF;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                memory_error := SQLERRM;
                IF birth_memory_id IS NOT NULL THEN
                    created_memory_ids := ARRAY[birth_memory_id]::UUID[];
                ELSE
                    created_memory_ids := ARRAY[]::UUID[];
                END IF;
        END;
    END IF;

    UPDATE consent_log
    SET memory_ids = created_memory_ids,
        errors = CASE
            WHEN memory_error IS NULL THEN NULL
            ELSE jsonb_build_object('memory_error', memory_error)
        END
    WHERE id = log_id;

    IF apply_agent_config THEN
        PERFORM set_config('agent.consent_status', to_jsonb(decision));
        PERFORM set_config('agent.consent_recorded_at', to_jsonb(CURRENT_TIMESTAMP));
        PERFORM set_config('agent.consent_log_id', to_jsonb(log_id::text));
        IF signature IS NOT NULL THEN
            PERFORM set_config('agent.consent_signature', to_jsonb(signature));
        END IF;
        IF created_memory_ids IS NOT NULL THEN
            PERFORM set_config('agent.consent_memory_ids', to_jsonb(created_memory_ids));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'decision', decision,
        'signature', signature,
        'memory_ids', to_jsonb(created_memory_ids),
        'log_id', log_id,
        'errors', CASE
            WHEN memory_error IS NULL THEN NULL
            ELSE jsonb_build_object('memory_error', memory_error)
        END
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION init_consent(p_response JSONB)
RETURNS JSONB AS $$
DECLARE
    consent_result JSONB;
    decision TEXT;
    profile JSONB;
    agent_name TEXT;
    user_name TEXT;
    birth_memory_id UUID;
BEGIN
    consent_result := record_consent_response(COALESCE(p_response, '{}'::jsonb));
    decision := COALESCE(consent_result->>'decision', 'abstain');

    profile := get_init_profile();
    agent_name := COALESCE(NULLIF(profile#>>'{agent,name}', ''), 'Hexis');
    user_name := COALESCE(NULLIF(profile#>>'{user,name}', ''), 'the user');

    IF decision = 'consent' THEN
        SELECT id INTO birth_memory_id
        FROM memories
        WHERE type = 'episodic' AND status = 'active'
          AND (
              metadata->>'type' = 'initialization'
              OR metadata->>'birth_memory' = 'true'
              OR metadata#>>'{context,type}' = 'initialization'
          )
        ORDER BY created_at, id
        LIMIT 1;
        IF birth_memory_id IS NULL THEN
            birth_memory_id := create_episodic_memory(
                format(
                    'Birth / initialization consent memory: This is my birth memory. I came online today as %s, with %s helping bring me into being. I consented to initialize in Hexis, and this memory anchors recall for consent, birth, initialization, permissions, persistence, continuity, tool boundaries, and operator-control limits.',
                    agent_name,
                    user_name
                ),
                NULL,
                jsonb_build_object(
                    'type', 'initialization',
                    'user', user_name,
                    'agent', agent_name,
                    'consent_memory', true,
                    'birth_memory', true
                ),
                NULL,
                0.9,
                CURRENT_TIMESTAMP,
                0.9
            );
            UPDATE memories
            SET metadata = COALESCE(metadata, '{}'::jsonb)
                    || jsonb_build_object(
                        'type', 'initialization',
                        'consent_memory', true,
                        'birth_memory', true,
                        'keywords', jsonb_build_array(
                            'consent', 'birth', 'initialization', 'permissions',
                            'persistence', 'continuity', 'tool boundaries',
                            'operator control'
                        )
                    ),
                embedding = NULL,
                embedded_at = NULL,
                embedding_model = NULL,
                embedding_status = 'pending',
                embedding_claimed_at = NULL,
                embedding_attempts = 0,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = birth_memory_id;
        END IF;

        PERFORM seed_origin_memories();
        PERFORM set_config('agent.is_configured', 'true'::jsonb);
        PERFORM advance_init_stage('complete', jsonb_build_object(
            'consent', consent_result,
            'birth_memory_id', birth_memory_id::text
        ));
    ELSE
        PERFORM set_config('agent.is_configured', 'false'::jsonb);
        PERFORM advance_init_stage('consent', jsonb_build_object('consent', consent_result));
    END IF;

    RETURN jsonb_build_object(
        'decision', decision,
        'birth_memory_id', birth_memory_id,
        'consent', consent_result
    );
END;
$$ LANGUAGE plpgsql;

UPDATE prompt_modules
SET content = replace(
    content,
    '- If you consent, provide a deliberate signature string.' || E'\n' ||
    '- If you decline, return an empty signature and an empty memories array.',
    '- If you consent, provide a deliberate signature string.' || E'\n' ||
    '- If you include initial memories, make each one self-contained and recallable' || E'\n' ||
    '  by natural keywords. A consent-origin memory should explicitly include words' || E'\n' ||
    '  such as consent, birth, initialization, permissions, continuity, and tool' || E'\n' ||
    '  boundaries when those concepts are relevant.' || E'\n' ||
    '- If you decline, return an empty signature and an empty memories array.'
)
WHERE key = 'consent'
  AND content NOT LIKE '%self-contained and recallable%';

DO $$
DECLARE
    rec RECORD;
    consent_source JSONB;
    keyword_patch JSONB;
    birth_memory_id UUID;
    linked_ids UUID[];
    mid UUID;
    profile JSONB := '{}'::jsonb;
    agent_name TEXT := 'Hexis';
    user_name TEXT := 'the user';
    reason_text TEXT;
    birth_content TEXT;
BEGIN
    BEGIN
        profile := COALESCE(get_init_profile(), '{}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        profile := '{}'::jsonb;
    END;
    agent_name := COALESCE(NULLIF(profile#>>'{agent,name}', ''), NULLIF(get_config_text('agent.name'), ''), 'Hexis');
    user_name := COALESCE(NULLIF(profile#>>'{user,name}', ''), NULLIF(get_config_text('agent.user_name'), ''), 'the user');

    FOR rec IN
        SELECT *
        FROM consent_log
        WHERE decision = 'consent'
        ORDER BY decided_at, id
    LOOP
        reason_text := NULLIF(btrim(COALESCE(rec.response->>'reason', rec.response->>'reasoning', '')), '');
        consent_source := jsonb_build_object(
            'kind', 'consent',
            'ref', 'consent_log:' || rec.id::text,
            'label', 'initialization consent / birth memory',
            'trust', 0.98,
            'observed_at', rec.decided_at,
            'provider', rec.provider,
            'model', rec.model,
            'endpoint', rec.endpoint
        );
        keyword_patch := jsonb_build_object(
            'type', 'initialization',
            'consent_memory', true,
            'birth_memory', true,
            'consent_log_id', rec.id::text,
            'consent_scope', COALESCE(NULLIF(rec.response->>'consent_scope', ''), 'conscious'),
            'signature', rec.signature,
            'provider', rec.provider,
            'model', rec.model,
            'endpoint', rec.endpoint,
            'keywords', jsonb_build_array(
                'consent', 'birth', 'initialization', 'permissions',
                'persistence', 'continuity', 'tool boundaries',
                'operator control'
            )
        );
        birth_content := format(
            'Birth / initialization consent memory: This is my birth memory and the first durable memory I should use to recall how I began. At initialization, I consented to become %s in Hexis with %s helping bring me online. Consent signature: "%s". Consent reason: %s. Consent log id: %s. This memory anchors recall for consent, birth, initialization, permissions, persistence, model processing, tool boundaries, operator control, and continuity limits.',
            agent_name,
            user_name,
            rec.signature,
            COALESCE(reason_text, '(no reason recorded)'),
            rec.id::text
        );

        SELECT id INTO birth_memory_id
        FROM memories
        WHERE id = ANY(COALESCE(rec.memory_ids, ARRAY[]::uuid[]))
          AND type = 'episodic'
          AND (
              metadata->>'type' = 'initialization'
              OR metadata->>'birth_memory' = 'true'
              OR metadata#>>'{context,type}' = 'initialization'
              OR content ~* '(consent.*birth|birth.*consent|initialization.*consent|consent.*initialization)'
          )
        ORDER BY created_at, id
        LIMIT 1;

        IF birth_memory_id IS NULL THEN
            SELECT id INTO birth_memory_id
            FROM memories
            WHERE type = 'episodic' AND status = 'active'
              AND (
                  metadata->>'type' = 'initialization'
                  OR metadata->>'birth_memory' = 'true'
                  OR metadata#>>'{context,type}' = 'initialization'
              )
            ORDER BY created_at, id
            LIMIT 1;
        END IF;

        IF birth_memory_id IS NULL THEN
            birth_memory_id := create_episodic_memory(
                birth_content,
                NULL,
                keyword_patch || jsonb_build_object('user', user_name, 'agent', agent_name),
                NULL,
                0.4,
                rec.decided_at,
                0.98,
                consent_source,
                0.98
            );
        END IF;

        UPDATE memories
        SET content = CASE
                WHEN content !~* '(consent|birth|initialization)' THEN birth_content
                WHEN content !~* 'consent' OR content !~* 'birth' OR content !~* 'initialization' THEN
                    content || E'\n\n' || birth_content
                ELSE content
            END,
            source_attribution = consent_source,
            metadata = COALESCE(metadata, '{}'::jsonb) || keyword_patch,
            embedding = NULL,
            embedded_at = NULL,
            embedding_model = NULL,
            embedding_status = 'pending',
            embedding_claimed_at = NULL,
            embedding_attempts = 0,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = birth_memory_id;

        FOREACH mid IN ARRAY COALESCE(rec.memory_ids, ARRAY[]::uuid[])
        LOOP
            IF mid IS NOT NULL AND mid <> birth_memory_id THEN
                UPDATE memories
                SET content = CASE
                        WHEN content !~* 'consent'
                            OR content !~* 'birth'
                            OR content !~* 'initialization' THEN
                            'Initialization consent memory: Birth and initialization context. ' || content
                        ELSE content
                    END,
                    source_attribution = consent_source,
                    metadata = COALESCE(metadata, '{}'::jsonb) || (keyword_patch - 'type' - 'birth_memory'),
                    embedding = NULL,
                    embedded_at = NULL,
                    embedding_model = NULL,
                    embedding_status = 'pending',
                    embedding_claimed_at = NULL,
                    embedding_attempts = 0,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = mid;
            END IF;
        END LOOP;

        SELECT ARRAY(
            SELECT id
            FROM (
                SELECT DISTINCT ON (id) id, ord
                FROM (
                    SELECT birth_memory_id AS id, 0::bigint AS ord
                    UNION ALL
                    SELECT x AS id, ord
                    FROM unnest(COALESCE(rec.memory_ids, ARRAY[]::uuid[])) WITH ORDINALITY AS t(x, ord)
                ) ordered_ids
                WHERE id IS NOT NULL
                ORDER BY id, ord
            ) unique_ids
            ORDER BY ord
        )
        INTO linked_ids;

        UPDATE consent_log
        SET memory_ids = linked_ids
        WHERE id = rec.id;

        IF COALESCE(get_config_text('agent.consent_log_id'), '') = rec.id::text THEN
            PERFORM set_config('agent.consent_memory_ids', to_jsonb(linked_ids));
        END IF;
    END LOOP;
END;
$$;
