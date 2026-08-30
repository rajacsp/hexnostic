-- Hexis schema: helper functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION age_in_days(ts TIMESTAMPTZ) 
RETURNS FLOAT
LANGUAGE sql
STABLE
AS $$
    SELECT EXTRACT(EPOCH FROM (NOW() - ts)) / 86400.0;
$$;
CREATE OR REPLACE FUNCTION calculate_relevance(
    p_importance FLOAT,
    p_decay_rate FLOAT,
    p_created_at TIMESTAMPTZ,
    p_last_accessed TIMESTAMPTZ
) RETURNS FLOAT
LANGUAGE sql
STABLE
AS $$
    SELECT p_importance * EXP(
        -p_decay_rate * LEAST(
            age_in_days(p_created_at),
            COALESCE(age_in_days(p_last_accessed), age_in_days(p_created_at)) * 0.5
        )
    );
$$;
-- Memory strength in (0, 1] for the compression-native substrate
-- (docs/memory_retention_design.md §2). Encoded/grown importance decayed by the
-- time SINCE LAST REINFORCEMENT -- recall/attention resets the clock, so
-- reinforcement moves strength UP; an un-reinforced memory decays from creation
-- and fades. Generalizes calculate_relevance; STRENGTH IS COMPUTED ON READ,
-- never stored or mass-written. (The rehearsal "ceiling raise" is already
-- supplied by update_memory_importance on access; reinforcement_count is tracked
-- on the row for telemetry / later phases, not double-counted here.)
CREATE OR REPLACE FUNCTION calculate_strength(
    p_importance FLOAT,
    p_decay_rate FLOAT,
    p_created_at TIMESTAMPTZ,
    p_last_reinforced TIMESTAMPTZ
) RETURNS FLOAT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(0.0, LEAST(1.0,
        COALESCE(p_importance, 0.5) * EXP(
            -GREATEST(COALESCE(p_decay_rate, 0.01), 0.0)
            * GREATEST(COALESCE(age_in_days(p_last_reinforced), age_in_days(p_created_at)), 0.0)
        )
    ));
$$;
-- Current FELT emotional intensity in [0, encoded] (docs/memory_retention_design.md §8/§9).
-- Distinct from the immutable encoded PEAK (emotional_context.intensity) that drives
-- persistence/protection. Asymmetric + computed-on-read:
--   * base decays by AGE (created_at, never reset by recall) toward a floor -> a positive
--     memory keeps a permanent EMBER (floor > 0); a negative one heals toward CALM (floor 0);
--   * a transient RE-KINDLE keyed to last_reinforced recency stirs it back up on recall,
--     bounded by the encoded peak; negative re-kindle is weighted down so rumination can't
--     hold a wound hot while the base keeps healing.
CREATE OR REPLACE FUNCTION current_emotional_intensity(
    p_encoded_intensity FLOAT,
    p_valence FLOAT,
    p_created_at TIMESTAMPTZ,
    p_last_reinforced TIMESTAMPTZ
) RETURNS FLOAT
LANGUAGE sql STABLE
AS $$
    WITH p AS (
        SELECT
            GREATEST(0.0, LEAST(1.0, COALESCE(p_encoded_intensity, 0.0))) AS enc,
            COALESCE(p_valence, 0.0) AS val,
            COALESCE(get_config_float('memory.intensity_ember_factor'), 0.5) AS ember,
            COALESCE(get_config_float('memory.intensity_decay_rate'), 0.02) AS drate,
            COALESCE(get_config_float('memory.intensity_rekindle_rate'), 0.5) AS rrate,
            COALESCE(get_config_float('memory.intensity_negative_rekindle_weight'), 0.4) AS nrw
    ),
    b AS (
        SELECT enc, val, rrate, nrw,
               (GREATEST(0.0, val) * enc * ember) AS floor,
               (GREATEST(0.0, val) * enc * ember)
                 + (enc - GREATEST(0.0, val) * enc * ember)
                   * EXP(GREATEST(-700.0, -drate * GREATEST(age_in_days(p_created_at), 0.0))) AS base
        FROM p
    )
    SELECT LEAST(b.enc, GREATEST(b.floor,
        b.base
        + (CASE WHEN b.val >= 0 THEN 1.0 ELSE b.nrw END)
          * (b.enc - b.base)
          * EXP(GREATEST(-700.0, -b.rrate * GREATEST(age_in_days(COALESCE(p_last_reinforced, p_created_at)), 0.0)))
    ))
    FROM b;
$$;
CREATE OR REPLACE FUNCTION sync_embedding_service_config()
RETURNS VOID AS $$
DECLARE
    configured_url TEXT;
    configured_model TEXT;
    current_url TEXT;
    current_model TEXT;
BEGIN
    configured_url := NULLIF(current_setting('app.embedding_service_url', true), '');
    IF configured_url IS NOT NULL THEN
        SELECT value #>> '{}' INTO current_url
        FROM config
        WHERE key = 'embedding.service_url';
        IF current_url IS DISTINCT FROM configured_url THEN
            INSERT INTO config (key, value, description, updated_at)
            VALUES ('embedding.service_url', to_jsonb(configured_url), 'URL of the embedding service', CURRENT_TIMESTAMP)
            ON CONFLICT (key) DO UPDATE
                SET value = EXCLUDED.value,
                    description = EXCLUDED.description,
                    updated_at = CURRENT_TIMESTAMP;
        END IF;
    END IF;

    configured_model := NULLIF(current_setting('app.embedding_model_id', true), '');
    IF configured_model IS NOT NULL THEN
        SELECT value #>> '{}' INTO current_model
        FROM config
        WHERE key = 'embedding.model_id';
        IF current_model IS DISTINCT FROM configured_model THEN
            INSERT INTO config (key, value, description, updated_at)
            VALUES ('embedding.model_id', to_jsonb(configured_model), 'Embedding model id for local / custom embedding services', CURRENT_TIMESTAMP)
            ON CONFLICT (key) DO UPDATE
                SET value = EXCLUDED.value,
                    description = EXCLUDED.description,
                    updated_at = CURRENT_TIMESTAMP;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION ensure_embedding_prefix(
    p_text TEXT,
    p_prefix TEXT DEFAULT 'search_document'
) RETURNS TEXT AS $$
DECLARE
    normalized_prefix TEXT;
BEGIN
    IF p_text IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_text ~* '^\s*(search_document|search_query|clustering|classification)\s*:' THEN
        RETURN ltrim(p_text);
    END IF;
    normalized_prefix := NULLIF(btrim(p_prefix), '');
    IF normalized_prefix IS NULL THEN
        RETURN p_text;
    END IF;
    RETURN normalized_prefix || ': ' || p_text;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
DROP FUNCTION IF EXISTS get_embeddings(TEXT[]);
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

CREATE OR REPLACE FUNCTION prefetch_embeddings(text_contents TEXT[])
RETURNS INT AS $$
DECLARE
    embeddings vector[];
BEGIN
    embeddings := get_embedding(text_contents);
    RETURN COALESCE(array_length(embeddings, 1), 0);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_embedding_service_health()
RETURNS BOOLEAN AS $$
DECLARE
    service_url TEXT;
    health_url TEXT;
    response http_response;
BEGIN
    PERFORM sync_embedding_service_config();
    service_url := (SELECT CASE WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}' ELSE value::text END FROM config WHERE key = 'embedding.service_url');
    IF service_url ~ '/api/embed$' THEN
        health_url := regexp_replace(service_url, '/api/embed$', '/api/tags');
    ELSE
        health_url := regexp_replace(service_url, '^(https?://[^/]+).*$', '\1/health');
    END IF;

    SELECT * INTO response FROM http_get(health_url);

    RETURN response.status = 200;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
