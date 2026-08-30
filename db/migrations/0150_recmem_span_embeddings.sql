-- RecMem span embeddings: long units are embedded as searchable child spans.
-- The parent vector is an average centroid for compatibility/routing only;
-- recall ranks subconscious units by their best matching span.

SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS subconscious_unit_embedding_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    unit_id UUID NOT NULL REFERENCES subconscious_units(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    token_count INT,
    char_start INT NOT NULL DEFAULT 0,
    char_end INT NOT NULL DEFAULT 0,
    embedding vector(768),
    embedded_at TIMESTAMPTZ,
    embedding_model TEXT,
    embedding_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (embedding_status IN ('pending', 'in_progress', 'embedded', 'failed')),
    embedding_claimed_at TIMESTAMPTZ,
    embedding_attempts INT NOT NULL DEFAULT 0,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (unit_id, chunk_index)
);

DO $$
DECLARE
    dim INT;
BEGIN
    dim := embedding_dimension();
    IF dim IS NOT NULL AND dim <> 768 THEN
        EXECUTE format(
            'ALTER TABLE subconscious_unit_embedding_chunks ALTER COLUMN embedding TYPE vector(%s) USING embedding::vector(%s)',
            dim,
            dim
        );
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_subconscious_unit_chunks_unit
    ON subconscious_unit_embedding_chunks (unit_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_subconscious_unit_chunks_fts
    ON subconscious_unit_embedding_chunks USING GIN (to_tsvector('english', content));
CREATE INDEX IF NOT EXISTS idx_subconscious_unit_chunks_embedding
    ON subconscious_unit_embedding_chunks USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subconscious_unit_chunks_embed_queue
    ON subconscious_unit_embedding_chunks (embedding_status, created_at)
    WHERE embedding_status IN ('pending', 'in_progress');

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.recmem_embedding_chunk_chars', '1800'::jsonb,
     'Maximum characters per RecMem embedding chunk; every chunk is embedded and parent vectors are averaged only as a coarse compatibility signal'),
    ('memory.recmem_embedding_chunk_overlap_chars', '120'::jsonb,
     'Character overlap between RecMem embedding chunks')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

CREATE OR REPLACE FUNCTION ensure_recmem_embedding_chunks(
    p_unit_id UUID,
    p_chunk_chars INT DEFAULT NULL,
    p_overlap_chars INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    unit_row subconscious_units%ROWTYPE;
    chunk_chars INT := GREATEST(COALESCE(p_chunk_chars, get_config_int('memory.recmem_embedding_chunk_chars'), 1800), 500);
    overlap_chars INT := GREATEST(COALESCE(p_overlap_chars, get_config_int('memory.recmem_embedding_chunk_overlap_chars'), 120), 0);
    step_chars INT;
    chunk_count INT := 0;
    existing_count INT := 0;
    unchanged_count INT := 0;
    trimmed_count INT := 0;
BEGIN
    SELECT * INTO unit_row
    FROM subconscious_units
    WHERE id = p_unit_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'unit_not_found', 'unit_id', p_unit_id);
    END IF;

    overlap_chars := LEAST(overlap_chars, chunk_chars / 2);
    step_chars := GREATEST(chunk_chars - overlap_chars, 1);

    WITH source AS (
        SELECT COALESCE(unit_row.content, '') AS content
    ),
    starts AS (
        SELECT generate_series(0, GREATEST(length(content) - 1, 0), step_chars) AS char_start,
               content
        FROM source
        WHERE length(content) > 0
    ),
    incoming AS MATERIALIZED (
        SELECT
            (row_number() OVER (ORDER BY char_start) - 1)::int AS chunk_index,
            substring(content FROM char_start + 1 FOR chunk_chars) AS chunk_content,
            char_start,
            LEAST(char_start + chunk_chars, length(content)) AS char_end
        FROM starts
    ),
    shaped AS MATERIALIZED (
        SELECT
            chunk_index,
            chunk_content,
            encode(sha256(convert_to(chunk_content, 'UTF8')), 'hex') AS content_hash,
            GREATEST(1, length(chunk_content) / 4) AS token_count,
            char_start,
            char_end
        FROM incoming
    ),
    pre AS (
        SELECT count(*) AS existing_total,
               count(*) FILTER (WHERE c.content_hash = s.content_hash) AS unchanged_total
        FROM shaped s
        JOIN subconscious_unit_embedding_chunks c
          ON c.unit_id = p_unit_id AND c.chunk_index = s.chunk_index
    ),
    upserted AS (
        INSERT INTO subconscious_unit_embedding_chunks (
            unit_id,
            chunk_index,
            content,
            content_hash,
            token_count,
            char_start,
            char_end
        )
        SELECT
            p_unit_id,
            chunk_index,
            chunk_content,
            content_hash,
            token_count,
            char_start,
            char_end
        FROM shaped
        ON CONFLICT (unit_id, chunk_index) DO UPDATE SET
            content = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.content
                ELSE EXCLUDED.content
            END,
            content_hash = EXCLUDED.content_hash,
            token_count = EXCLUDED.token_count,
            char_start = EXCLUDED.char_start,
            char_end = EXCLUDED.char_end,
            embedding = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedding
                ELSE NULL
            END,
            embedded_at = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedded_at
                ELSE NULL
            END,
            embedding_model = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedding_model
                ELSE NULL
            END,
            embedding_status = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedding_status
                ELSE 'pending'
            END,
            embedding_attempts = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedding_attempts
                ELSE 0
            END,
            embedding_claimed_at = CASE
                WHEN subconscious_unit_embedding_chunks.content_hash = EXCLUDED.content_hash
                    THEN subconscious_unit_embedding_chunks.embedding_claimed_at
                ELSE NULL
            END,
            updated_at = CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT count(*), COALESCE(pre.existing_total, 0), COALESCE(pre.unchanged_total, 0)
    INTO chunk_count, existing_count, unchanged_count
    FROM shaped
    CROSS JOIN pre
    GROUP BY pre.existing_total, pre.unchanged_total;

    chunk_count := COALESCE(chunk_count, 0);
    existing_count := COALESCE(existing_count, 0);
    unchanged_count := COALESCE(unchanged_count, 0);

    DELETE FROM subconscious_unit_embedding_chunks
    WHERE unit_id = p_unit_id
      AND chunk_index >= chunk_count;
    GET DIAGNOSTICS trimmed_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'unit_id', p_unit_id,
        'count', chunk_count,
        'inserted', chunk_count - existing_count,
        'unchanged', unchanged_count,
        'reembedded', existing_count - unchanged_count,
        'trimmed', trimmed_count,
        'chunk_chars', chunk_chars,
        'overlap_chars', overlap_chars
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claim_recmem_embedding_chunks(
    p_unit_id UUID,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.recmem_embed_claim_timeout_s'), 120);
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT c.id
        FROM subconscious_unit_embedding_chunks c
        WHERE c.unit_id = p_unit_id
          AND (
              c.embedding_status = 'pending'
              OR (
                  c.embedding_status = 'in_progress'
                  AND c.embedding_claimed_at < CURRENT_TIMESTAMP - (timeout_s * INTERVAL '1 second')
              )
          )
        ORDER BY c.chunk_index
        FOR UPDATE SKIP LOCKED
    ),
    claimed AS (
        UPDATE subconscious_unit_embedding_chunks c
        SET embedding_status = 'in_progress',
            embedding_claimed_at = CURRENT_TIMESTAMP,
            embedding_attempts = c.embedding_attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate cand
        WHERE c.id = cand.id
        RETURNING c.id, c.unit_id, c.chunk_index, c.content, c.char_start, c.char_end, c.embedding_attempts
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'chunk_id', id,
        'unit_id', unit_id,
        'chunk_index', chunk_index,
        'content', content,
        'char_start', char_start,
        'char_end', char_end,
        'attempts', embedding_attempts
    ) ORDER BY chunk_index), '[]'::jsonb)
    INTO payload
    FROM claimed;

    RETURN payload;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_recmem_embedding_chunk(
    p_chunk_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.recmem_embed_max_attempts'), 3);
    final_status TEXT;
BEGIN
    UPDATE subconscious_unit_embedding_chunks
    SET embedding_status = CASE WHEN embedding_attempts >= max_attempts THEN 'failed' ELSE 'pending' END,
        embedding_claimed_at = NULL,
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'embedding_error',
                jsonb_build_object('error', p_error, 'at', CURRENT_TIMESTAMP)
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_chunk_id
    RETURNING embedding_status INTO final_status;

    RETURN jsonb_build_object('chunk_id', p_chunk_id, 'embedding_status', final_status);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION finalize_recmem_unit_embedding(
    p_unit_id UUID
) RETURNS JSONB AS $$
DECLARE
    total_chunks INT;
    embedded_chunks INT;
    failed_chunks INT;
    centroid vector;
BEGIN
    SELECT
        COUNT(*)::int,
        COUNT(*) FILTER (WHERE embedding_status = 'embedded' AND embedding IS NOT NULL)::int,
        COUNT(*) FILTER (WHERE embedding_status = 'failed')::int
    INTO total_chunks, embedded_chunks, failed_chunks
    FROM subconscious_unit_embedding_chunks
    WHERE unit_id = p_unit_id;

    IF COALESCE(total_chunks, 0) = 0 THEN
        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'waiting', 'reason', 'no_chunks');
    END IF;

    IF COALESCE(failed_chunks, 0) > 0 THEN
        RETURN jsonb_build_object(
            'unit_id', p_unit_id,
            'status', 'waiting',
            'reason', 'failed_chunks',
            'chunks', jsonb_build_object('total', total_chunks, 'embedded', embedded_chunks, 'failed', failed_chunks)
        );
    END IF;

    IF embedded_chunks < total_chunks THEN
        RETURN jsonb_build_object(
            'unit_id', p_unit_id,
            'status', 'waiting',
            'reason', 'pending_chunks',
            'chunks', jsonb_build_object('total', total_chunks, 'embedded', embedded_chunks, 'failed', failed_chunks)
        );
    END IF;

    SELECT avg(embedding)
    INTO centroid
    FROM subconscious_unit_embedding_chunks
    WHERE unit_id = p_unit_id
      AND embedding_status = 'embedded'
      AND embedding IS NOT NULL;

    UPDATE subconscious_units
    SET embedding = centroid,
        embedded_at = CURRENT_TIMESTAMP,
        embedding_status = 'embedded',
        embedding_claimed_at = NULL,
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'recmem',
                COALESCE(metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object(
                        'embedding_chunks',
                        jsonb_build_object(
                            'count', total_chunks,
                            'embedded', embedded_chunks,
                            'finalized_at', CURRENT_TIMESTAMP,
                            'parent_embedding', 'average_chunk_centroid'
                        )
                    )
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_unit_id
      AND status = 'active';

    RETURN jsonb_build_object(
        'unit_id', p_unit_id,
        'status', 'embedded',
        'chunks', jsonb_build_object('total', total_chunks, 'embedded', embedded_chunks)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_subconscious_vector_hits(
    p_query_embedding vector,
    p_limit INT DEFAULT 10,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    p_zero_vec vector DEFAULT NULL
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    fidelity FLOAT,
    strength FLOAT,
    emotional_intensity FLOAT,
    confidence FLOAT,
    retrieval_source TEXT
) AS $$
DECLARE
    zero_vec vector := COALESCE(p_zero_vec, array_fill(0.0::float, ARRAY[embedding_dimension()])::vector);
BEGIN
    RETURN QUERY
    WITH chunk_best AS (
        SELECT DISTINCT ON (s.id)
            s.id AS item_id,
            CASE
                WHEN length(s.content) > length(c.content) + 200 THEN
                    concat_ws(E'\n',
                        '[Matching RecMem span: chunk ' || c.chunk_index::text
                            || ', chars ' || c.char_start::text || '-' || c.char_end::text
                            || ' of unit ' || s.id::text || ']',
                        '',
                        c.content
                    )
                ELSE s.content
            END AS content,
            (1 - (c.embedding <=> p_query_embedding))::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            COALESCE(s.source_attribution, '{}'::jsonb)
                || jsonb_build_object(
                    'recmem_embedding_chunk',
                    jsonb_build_object(
                        'chunk_id', c.id::text,
                        'unit_id', s.id::text,
                        'chunk_index', c.chunk_index,
                        'char_start', c.char_start,
                        'char_end', c.char_end,
                        'chunk_count', chunk_stats.chunk_count
                    )
                ) AS source_attribution,
            s.created_at,
            s.trust_level,
            'chunk_vector'::text AS retrieval_source
        FROM subconscious_unit_embedding_chunks c
        JOIN subconscious_units s ON s.id = c.unit_id
        CROSS JOIN LATERAL (
            SELECT COUNT(*)::int AS chunk_count
            FROM subconscious_unit_embedding_chunks all_chunks
            WHERE all_chunks.unit_id = s.id
        ) chunk_stats
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND c.embedding_status = 'embedded'
          AND c.embedding IS NOT NULL
          AND c.embedding <> zero_vec
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
        ORDER BY s.id, c.embedding <=> p_query_embedding, c.chunk_index
    ),
    parent_hits AS (
        SELECT
            s.id AS item_id,
            s.content,
            (1 - (s.embedding <=> p_query_embedding))::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            'vector'::text AS retrieval_source
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
          AND s.embedding <> zero_vec
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
    ),
    best AS (
        SELECT DISTINCT ON (candidate_rows.item_id)
            candidate_rows.item_id,
            candidate_rows.content,
            candidate_rows.score,
            candidate_rows.source_unit_ids,
            candidate_rows.source_attribution,
            candidate_rows.created_at,
            candidate_rows.trust_level,
            candidate_rows.retrieval_source
        FROM (
            SELECT * FROM chunk_best
            UNION ALL
            SELECT * FROM parent_hits
        ) candidate_rows
        ORDER BY candidate_rows.item_id, candidate_rows.score DESC, candidate_rows.retrieval_source
    )
    SELECT
        'subconscious'::text AS tier,
        b.item_id,
        b.content,
        NULL::text AS memory_type,
        b.score,
        b.source_unit_ids,
        b.source_attribution,
        b.created_at,
        b.trust_level,
        1.0::float AS fidelity,
        1.0::float AS strength,
        NULL::float AS emotional_intensity,
        NULL::float AS confidence,
        b.retrieval_source
    FROM best b
    ORDER BY b.score DESC, b.created_at DESC
    LIMIT GREATEST(COALESCE(p_limit, 10), 0);
END;
$$ LANGUAGE plpgsql STABLE;

DO $$
DECLARE
    fn_def TEXT;
    start_pos INT;
    end_pos INT;
    new_block TEXT := $new$
WITH raw_hits AS (
        SELECT *
        FROM recmem_subconscious_vector_hits(
            query_embedding,
            GREATEST(COALESCE(p_k_sub, 10), 0),
            p_exclude_sensitive,
            zero_vec
        )
    ),
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.recmem_recall_context(text, integer, integer, integer, uuid, boolean, integer)'::regprocedure
    )
    INTO fn_def;

    start_pos := position('WITH raw_hits AS (' IN fn_def);
    end_pos := position('recent_unembedded AS (' IN fn_def);

    IF start_pos = 0 OR end_pos = 0 OR end_pos <= start_pos THEN
        RAISE EXCEPTION '0150 could not locate recmem_recall_context raw_hits markers';
    END IF;

    fn_def := substring(fn_def FROM 1 FOR start_pos - 1)
        || new_block
        || substring(fn_def FROM end_pos);
    EXECUTE fn_def;
END;
$$;

UPDATE subconscious_units
SET embedding_status = 'pending',
    embedding_claimed_at = NULL,
    embedding_attempts = 0,
    route_status = CASE
        WHEN route_status IN ('raw_only', 'route_failed') THEN 'unrouted'
        ELSE route_status
    END,
    last_routed_at = CASE
        WHEN route_status IN ('raw_only', 'route_failed') THEN NULL
        ELSE last_routed_at
    END,
    metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{recmem,embedding_retry_reset}',
        jsonb_build_object(
            'at', CURRENT_TIMESTAMP,
            'reason', 'span_level_recmem_embeddings'
        ),
        true
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'active'
  AND embedding_status = 'embedded'
  AND length(content) > GREATEST(COALESCE(get_config_int('memory.recmem_embedding_chunk_chars'), 1800), 500)
  AND NOT EXISTS (
      SELECT 1
      FROM subconscious_unit_embedding_chunks c
      WHERE c.unit_id = subconscious_units.id
  );
