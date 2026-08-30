-- Keep embedding requests within the published embeddinggemma sidecar's
-- documented/request-enforced batch limit.

SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description, updated_at)
VALUES (
    'embedding.max_batch_size',
    '32'::jsonb,
    'Maximum texts sent to the embedding service in one HTTP request; embeddinggemma accepts up to 32',
    CURRENT_TIMESTAMP
)
ON CONFLICT (key) DO UPDATE
SET value = CASE
        WHEN config.value IS NULL OR (config.value #>> '{}')::int <= 0 THEN EXCLUDED.value
        WHEN (config.value #>> '{}')::int > 32 THEN EXCLUDED.value
        ELSE config.value
    END,
    description = EXCLUDED.description,
    updated_at = CURRENT_TIMESTAMP;

DROP FUNCTION IF EXISTS get_embedding(TEXT);
CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
RETURNS vector[] AS $$
	DECLARE
	    service_url TEXT;
	    response http_response;
	    request_body TEXT;
	    embedding_json JSONB;
	    embeddings_json JSONB;
	    embedding_array FLOAT[];
	    cached_embedding vector;
	    model_id TEXT;
	    expected_dim INT;
	    effective_text TEXT;
	    stripped_text TEXT;
	    v_content_hash TEXT;
	    v_alt_hash TEXT;
	    start_ts TIMESTAMPTZ;
	    retry_seconds INT;
	    retry_interval_seconds FLOAT;
	    http_timeout_ms INT;
	    last_error TEXT;
	    result vector[];
	    missing_texts TEXT[] := ARRAY[]::text[];
	    missing_hashes TEXT[] := ARRAY[]::text[];
	    missing_indices INT[] := ARRAY[]::int[];
	    max_batch_size INT;
	    batch_start INT;
	    batch_end INT;
	    batch_texts TEXT[];
	    total INT;
	    i INT;
	    j INT;
	    global_index INT;
	BEGIN
	    PERFORM sync_embedding_dimension_config();
	    PERFORM sync_embedding_service_config();
	    expected_dim := embedding_dimension();
	    total := COALESCE(array_length(text_contents, 1), 0);
	    IF total = 0 THEN
	        RETURN ARRAY[]::vector[];
	    END IF;

	    result := array_fill(NULL::vector, ARRAY[total]);

	    FOR i IN 1..total LOOP
	        v_content_hash := encode(sha256(convert_to(COALESCE(text_contents[i], ''), 'UTF8')), 'hex');
	        SELECT ec.embedding INTO cached_embedding
	        FROM embedding_cache ec
	        WHERE ec.content_hash = v_content_hash;

	        IF FOUND THEN
	            result[i] := cached_embedding;
	            CONTINUE;
	        END IF;

	        IF text_contents[i] ~* '^\s*(search_document|search_query|clustering|classification)\s*:' THEN
	            stripped_text := regexp_replace(
	                text_contents[i],
	                '^\s*(search_document|search_query|clustering|classification)\s*:\s*',
	                '',
	                'i'
	            );
	            v_alt_hash := encode(sha256(convert_to(COALESCE(stripped_text, ''), 'UTF8')), 'hex');
	            IF v_alt_hash <> v_content_hash THEN
	                SELECT ec.embedding INTO cached_embedding
	                FROM embedding_cache ec
	                WHERE ec.content_hash = v_alt_hash;
	                IF FOUND THEN
	                    result[i] := cached_embedding;
	                    CONTINUE;
	                END IF;
	            END IF;
	        END IF;

	        effective_text := ensure_embedding_prefix(text_contents[i], 'search_document');
	        missing_texts := missing_texts || effective_text;
	        missing_hashes := missing_hashes || v_content_hash;
	        missing_indices := missing_indices || i;
	    END LOOP;

	    IF array_length(missing_texts, 1) IS NULL THEN
	        RETURN result;
	    END IF;

	    service_url := (SELECT CASE WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}' ELSE value::text END FROM config WHERE key = 'embedding.service_url');
	    model_id := COALESCE(
	        (SELECT CASE WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}' ELSE value::text END FROM config WHERE key = 'embedding.model_id'),
	        'qwen3-embedding:0.6b-q8_0'
	    );
	    retry_seconds := COALESCE(
	        (SELECT (value #>> '{}')::int FROM config WHERE key = 'embedding.retry_seconds'),
	        30
	    );
	    retry_interval_seconds := COALESCE(
	        (SELECT (value #>> '{}')::float FROM config WHERE key = 'embedding.retry_interval_seconds'),
	        1.0
	    );
	    -- Bound each HTTP attempt above the embedding server's cold model-load
	    -- time. The pgsql-http default (5s) can be shorter than a cold load, so
	    -- the first embed after an idle unload aborts mid-load -- which cancels
	    -- the load -- and never recovers within retry_seconds. 9s rides it through.
	    http_timeout_ms := COALESCE(
	        (SELECT (value #>> '{}')::int FROM config WHERE key = 'embedding.http_timeout_ms'),
	        9000
	    );
	    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', http_timeout_ms::text);
	    max_batch_size := COALESCE(
	        NULLIF((SELECT (value #>> '{}')::int FROM config WHERE key = 'embedding.max_batch_size'), 0),
	        32
	    );
	    IF max_batch_size < 1 THEN
	        max_batch_size := total;
	    END IF;

	    batch_start := 1;
	    WHILE batch_start <= array_length(missing_texts, 1) LOOP
	        batch_end := LEAST(batch_start + max_batch_size - 1, array_length(missing_texts, 1));
	        batch_texts := missing_texts[batch_start:batch_end];
        IF service_url ~ '/api/embed$' THEN
            request_body := json_build_object('model', model_id, 'input', batch_texts, 'dimension', expected_dim)::TEXT;
	        ELSIF service_url ~ '/embeddings$' THEN
	            request_body := json_build_object('input', batch_texts)::TEXT;
	        ELSE
	            request_body := json_build_object('inputs', batch_texts)::TEXT;
	        END IF;
	        start_ts := clock_timestamp();

	        LOOP
	            BEGIN
	                SELECT * INTO response FROM http_post(
	                    service_url,
	                    request_body,
	                    'application/json'
	                );

	                IF response.status = 200 THEN
	                    EXIT;
	                END IF;
	                IF response.status IN (400, 401, 403, 404, 422) THEN
	                    RAISE EXCEPTION 'Embedding service error: % - %', response.status, response.content;
	                END IF;

	                last_error := format('status %s: %s', response.status, left(COALESCE(response.content, ''), 500));
	            EXCEPTION
	                WHEN OTHERS THEN
	                    last_error := SQLERRM;
	            END;

	            IF retry_seconds <= 0 OR clock_timestamp() - start_ts >= (retry_seconds || ' seconds')::interval THEN
	                RAISE EXCEPTION 'Embedding service not available after % seconds: %', retry_seconds, COALESCE(last_error, '<unknown>');
	            END IF;

	            PERFORM pg_sleep(GREATEST(0.0, retry_interval_seconds));
	        END LOOP;

	        embedding_json := response.content::JSONB;
	        IF embedding_json ? 'embeddings' THEN
	            embeddings_json := embedding_json->'embeddings';
	        ELSIF embedding_json ? 'data' THEN
	            SELECT jsonb_agg(entry->'embedding') INTO embeddings_json
	            FROM jsonb_array_elements(embedding_json->'data') entry;
	        ELSIF embedding_json ? 'embedding' THEN
	            embeddings_json := jsonb_build_array(embedding_json->'embedding');
	        ELSIF jsonb_typeof(embedding_json) = 'array' THEN
	            IF jsonb_typeof(embedding_json->0) = 'array' THEN
	                embeddings_json := embedding_json;
	            ELSE
	                embeddings_json := jsonb_build_array(embedding_json);
	            END IF;
	        ELSE
	            RAISE EXCEPTION 'Unexpected embedding response shape: %', left(embedding_json::text, 500);
	        END IF;

	        IF embeddings_json IS NULL OR jsonb_typeof(embeddings_json) <> 'array' THEN
	            RAISE EXCEPTION 'Embedding response missing array payload: %', left(embedding_json::text, 500);
	        END IF;

	        IF jsonb_array_length(embeddings_json) <> array_length(batch_texts, 1) THEN
	            RAISE EXCEPTION 'Embedding response size mismatch: expected %, got %',
	                array_length(batch_texts, 1),
	                jsonb_array_length(embeddings_json);
	        END IF;

	        FOR j IN 1..array_length(batch_texts, 1) LOOP
	            embedding_array := ARRAY(
	                SELECT jsonb_array_elements_text(embeddings_json->(j - 1))::FLOAT
	            );
	            IF array_length(embedding_array, 1) IS NULL OR array_length(embedding_array, 1) != expected_dim THEN
	                RAISE EXCEPTION 'Invalid embedding dimension: expected %, got %', expected_dim, array_length(embedding_array, 1);
	            END IF;

	            global_index := batch_start + j - 1;
	            INSERT INTO embedding_cache (content_hash, embedding)
	            VALUES (missing_hashes[global_index], embedding_array::vector)
	            ON CONFLICT DO NOTHING;

	            result[missing_indices[global_index]] := embedding_array::vector;
	        END LOOP;

	        -- Record embedding usage (fire-and-forget; ignore if api_usage table missing)
	        BEGIN
	            INSERT INTO api_usage (provider, model, operation, input_tokens, source)
	            VALUES (
	                'local-embedding',
	                model_id,
	                'embed',
	                COALESCE(
	                    (embedding_json->>'prompt_eval_count')::int,  -- local embed API
	                    (embedding_json->'usage'->>'total_tokens')::int,  -- OpenAI-compat
	                    array_length(batch_texts, 1) * 50  -- fallback estimate
	                ),
	                'embed'
	            );
	        EXCEPTION WHEN OTHERS THEN
	            -- Silently ignore (table may not exist on first boot)
	            NULL;
	        END;

	        batch_start := batch_end + 1;
	    END LOOP;

	    RETURN result;
	EXCEPTION
	    WHEN OTHERS THEN
	        RAISE EXCEPTION 'Failed to get embeddings: %', SQLERRM;
	END;
$$ LANGUAGE plpgsql;
