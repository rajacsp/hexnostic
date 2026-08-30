-- Tighten consent-memory recall handles after the first live backfill. A memory
-- linked from consent_log must carry the core natural-language search handles
-- in its embedded content, not only in metadata.
SET search_path = public, ag_catalog, "$user";

DO $$
DECLARE
    fn TEXT;
    old_fragment TEXT := E'IF item_content !~* ''(consent|birth|initialization|permission|continuity)'' THEN\n                        item_content := ''Initialization consent memory: '' || item_content;\n                    END IF;';
    new_fragment TEXT := E'IF item_content !~* ''consent''\n                        OR item_content !~* ''birth''\n                        OR item_content !~* ''initialization'' THEN\n                        item_content := ''Initialization consent memory: Birth and initialization context. '' || item_content;\n                    END IF;';
BEGIN
    SELECT pg_get_functiondef('record_consent_response(jsonb)'::regprocedure) INTO fn;
    IF fn LIKE '%Initialization consent memory: Birth and initialization context.%' THEN
        RETURN;
    END IF;

    fn := replace(fn, old_fragment, new_fragment);
    IF fn NOT LIKE '%Initialization consent memory: Birth and initialization context.%' THEN
        RAISE EXCEPTION 'Could not patch record_consent_response consent-memory prefix rule';
    END IF;
    EXECUTE fn;
END;
$$;

DO $$
DECLARE
    rec RECORD;
    birth_memory_id UUID;
    linked_ids UUID[];
    mid UUID;
BEGIN
    FOR rec IN
        SELECT *
        FROM consent_log
        WHERE decision = 'consent'
        ORDER BY decided_at, id
    LOOP
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
            CONTINUE;
        END IF;

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
                    metadata = COALESCE(metadata, '{}'::jsonb)
                        || jsonb_build_object(
                            'consent_memory', true,
                            'consent_log_id', rec.id::text,
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
                WHERE id = mid
                  AND (
                      content !~* 'consent'
                      OR content !~* 'birth'
                      OR content !~* 'initialization'
                  );
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
