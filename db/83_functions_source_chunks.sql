-- Durable source-document chunks: stable, citable slices of the filing
-- cabinet. Chunks carry locators (page, section, sheet row, slide, message)
-- so retrieval can cite exactly where a passage came from, and embeddings so
-- retrieval can be hybrid (lexical + vector). Chunk rows are keyed by
-- (source_document_id, chunk_index) and keep their UUID + embedding when
-- re-ingestion produces identical content.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.source_chunk_embed_batch_size', '32'::jsonb,
     'Chunks claimed per source-chunk embedding pass'),
    ('memory.source_chunk_embed_claim_timeout_s', '120'::jsonb,
     'Seconds before an in-progress source-chunk embedding claim is considered stale and reclaimable'),
    ('memory.source_chunk_embed_max_attempts', '3'::jsonb,
     'Embedding attempts before a source chunk is marked failed (search degrades to lexical for it)'),
    ('memory.source_chunk_search_default_limit', '10'::jsonb,
     'Default row budget for source-chunk search'),
    ('memory.source_chunk_search_max_limit', '50'::jsonb,
     'Ceiling on source-chunk search rows'),
    ('retrieval.chunk_weight_lexical', '0.4'::jsonb,
     'Hybrid chunk search: weight of the normalized full-text score'),
    ('retrieval.chunk_weight_vector', '0.6'::jsonb,
     'Hybrid chunk search: weight of the embedding cosine similarity'),
    ('retrieval.chunk_weight_recency', '0.1'::jsonb,
     'Hybrid chunk search: weight of exponential document recency'),
    ('retrieval.chunk_weight_trust', '0.1'::jsonb,
     'Hybrid chunk search: weight of the source trust level'),
    ('retrieval.chunk_weight_desk', '0.05'::jsonb,
     'Hybrid chunk search: bonus weight for chunks already on the RecMem desk'),
    ('retrieval.chunk_recency_half_life_days', '30'::jsonb,
     'Hybrid chunk search: document-age half life for the recency component')
ON CONFLICT (key) DO NOTHING;

-- Upsert the full chunk set for one document. Keep-if-unchanged semantics:
-- a chunk whose content_hash matches the stored row keeps its id, embedding,
-- and access stats; changed content resets the embedding lifecycle; trailing
-- rows beyond the new chunk count are deleted. Redacted documents are frozen.
CREATE OR REPLACE FUNCTION upsert_source_document_chunks(
    p_document_id UUID,
    p_chunks JSONB,
    p_chunker_version TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    doc_status TEXT;
    version TEXT := COALESCE(NULLIF(p_chunker_version, ''), 'v2');
    n_chunks INT;
    existing_count INT := 0;
    unchanged_count INT := 0;
    trimmed_count INT := 0;
    chunk_ids JSONB;
BEGIN
    IF p_document_id IS NULL THEN
        RETURN jsonb_build_object('error', 'missing_document_id');
    END IF;
    SELECT status INTO doc_status FROM source_documents WHERE id = p_document_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found', 'document_id', p_document_id);
    END IF;
    IF doc_status = 'redacted' THEN
        -- Redacted documents never rehydrate — not even their chunks.
        RETURN jsonb_build_object('error', 'document_redacted', 'document_id', p_document_id);
    END IF;
    IF p_chunks IS NULL OR jsonb_typeof(p_chunks) <> 'array' THEN
        RETURN jsonb_build_object('error', 'invalid_chunks_payload');
    END IF;

    n_chunks := jsonb_array_length(p_chunks);

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_chunks) c
        WHERE c->>'content' IS NULL OR NULLIF(c->>'chunk_index', '') IS NULL
    ) THEN
        RAISE EXCEPTION 'upsert_source_document_chunks: every chunk requires chunk_index and content';
    END IF;

    -- One snapshot: `pre` counts existing/unchanged rows before the upsert
    -- sub-statement rewrites them (data-modifying CTEs share the snapshot).
    WITH incoming AS MATERIALIZED (
        SELECT
            (c->>'chunk_index')::int AS chunk_index,
            COALESCE(NULLIF(c->>'locator_kind', ''), 'char') AS locator_kind,
            COALESCE(c->'locator', '{}'::jsonb) AS locator,
            COALESCE(
                (SELECT array_agg(x) FROM jsonb_array_elements_text(
                    CASE WHEN jsonb_typeof(c->'heading_path') = 'array'
                         THEN c->'heading_path' ELSE '[]'::jsonb END) x),
                ARRAY[]::text[]
            ) AS heading_path,
            c->>'content' AS content,
            encode(sha256(convert_to(c->>'content', 'UTF8')), 'hex') AS content_hash,
            COALESCE(NULLIF(c->>'token_count', '')::int,
                     GREATEST(1, length(c->>'content') / 4)) AS token_count,
            COALESCE(NULLIF(c->>'char_start', '')::int, 0) AS char_start,
            COALESCE(NULLIF(c->>'char_end', '')::int, 0) AS char_end,
            NULLIF(c->>'page_start', '')::int AS page_start,
            NULLIF(c->>'page_end', '')::int AS page_end,
            NULLIF(c->>'sheet_name', '') AS sheet_name,
            NULLIF(c->>'row_start', '')::int AS row_start,
            NULLIF(c->>'row_end', '')::int AS row_end,
            NULLIF(c->>'column_start', '')::int AS column_start,
            NULLIF(c->>'column_end', '')::int AS column_end,
            COALESCE(c->'metadata', '{}'::jsonb) AS metadata
        FROM jsonb_array_elements(p_chunks) AS c
    ),
    pre AS (
        SELECT count(*) AS existing_total,
               count(*) FILTER (WHERE s.content_hash = i.content_hash) AS unchanged_total
        FROM incoming i
        JOIN source_document_chunks s
          ON s.source_document_id = p_document_id AND s.chunk_index = i.chunk_index
    ),
    upserted AS (
        INSERT INTO source_document_chunks (
            source_document_id, chunk_index, locator_kind, locator, heading_path,
            content, content_hash, token_count, char_start, char_end,
            page_start, page_end, sheet_name, row_start, row_end,
            column_start, column_end, chunker_version, metadata
        )
        SELECT
            p_document_id, i.chunk_index, i.locator_kind, i.locator, i.heading_path,
            i.content, i.content_hash, i.token_count, i.char_start, i.char_end,
            i.page_start, i.page_end, i.sheet_name, i.row_start, i.row_end,
            i.column_start, i.column_end, version, i.metadata
        FROM incoming i
        ON CONFLICT (source_document_id, chunk_index) DO UPDATE SET
        locator_kind = EXCLUDED.locator_kind,
        locator = EXCLUDED.locator,
        heading_path = EXCLUDED.heading_path,
        token_count = EXCLUDED.token_count,
        char_start = EXCLUDED.char_start,
        char_end = EXCLUDED.char_end,
        page_start = EXCLUDED.page_start,
        page_end = EXCLUDED.page_end,
        sheet_name = EXCLUDED.sheet_name,
        row_start = EXCLUDED.row_start,
        row_end = EXCLUDED.row_end,
        column_start = EXCLUDED.column_start,
        column_end = EXCLUDED.column_end,
        chunker_version = EXCLUDED.chunker_version,
        metadata = source_document_chunks.metadata || EXCLUDED.metadata,
        -- Content change resets the embedding lifecycle; identical content
        -- keeps the stored embedding (and its id, via the conflict target).
        content = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                       THEN source_document_chunks.content ELSE EXCLUDED.content END,
        embedding = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                         THEN source_document_chunks.embedding ELSE NULL END,
        embedded_at = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                           THEN source_document_chunks.embedded_at ELSE NULL END,
        embedding_model = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                               THEN source_document_chunks.embedding_model ELSE NULL END,
        embedding_status = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                                THEN source_document_chunks.embedding_status ELSE 'pending' END,
        embedding_attempts = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                                  THEN source_document_chunks.embedding_attempts ELSE 0 END,
        embedding_claimed_at = CASE WHEN source_document_chunks.content_hash = EXCLUDED.content_hash
                                    THEN source_document_chunks.embedding_claimed_at ELSE NULL END,
        content_hash = EXCLUDED.content_hash,
        updated_at = CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT pre.existing_total, pre.unchanged_total
    INTO existing_count, unchanged_count
    FROM pre;

    DELETE FROM source_document_chunks
    WHERE source_document_id = p_document_id
      AND chunk_index >= n_chunks;
    GET DIAGNOSTICS trimmed_count = ROW_COUNT;

    SELECT COALESCE(jsonb_agg(id ORDER BY chunk_index), '[]'::jsonb)
    INTO chunk_ids
    FROM source_document_chunks
    WHERE source_document_id = p_document_id;

    RETURN jsonb_build_object(
        'document_id', p_document_id,
        'chunk_ids', chunk_ids,
        'count', n_chunks,
        'inserted', n_chunks - existing_count,
        'unchanged', unchanged_count,
        're_embedded', existing_count - unchanged_count,
        'trimmed', trimmed_count,
        'chunker_version', version
    );
END;
$$ LANGUAGE plpgsql;

-- Claim a batch of chunks awaiting embedding (mirrors the RecMem embed
-- queue: SKIP LOCKED claim, stale in-progress reclaim, attempt counting).
CREATE OR REPLACE FUNCTION claim_source_chunks_unembedded_batch(
    p_limit INT DEFAULT 32,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.source_chunk_embed_claim_timeout_s'), 120);
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT c.id
        FROM source_document_chunks c
        JOIN source_documents d ON d.id = c.source_document_id
        WHERE d.status = 'active'
          AND (
              c.embedding_status = 'pending'
              OR (
                  c.embedding_status = 'in_progress'
                  AND c.embedding_claimed_at < CURRENT_TIMESTAMP - (timeout_s * INTERVAL '1 second')
              )
          )
        ORDER BY c.created_at
        FOR UPDATE OF c SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 32), 1)
    ),
    claimed AS (
        UPDATE source_document_chunks c
        SET embedding_status = 'in_progress',
            embedding_claimed_at = CURRENT_TIMESTAMP,
            embedding_attempts = c.embedding_attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate cand
        WHERE c.id = cand.id
        RETURNING c.id, c.content, c.embedding_attempts
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'chunk_id', id,
        'content', content,
        'attempts', embedding_attempts
    )), '[]'::jsonb)
    INTO payload
    FROM claimed;

    RETURN payload;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_source_chunk_embedding(
    p_chunk_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.source_chunk_embed_max_attempts'), 3);
    final_status TEXT;
BEGIN
    UPDATE source_document_chunks
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

-- Hybrid passage search over durable chunks: full-text ⟗ vector, fused with
-- config-weighted recency, source trust, and desk-priority components. Every
-- row carries DB-generated rank_components so retrieval is debuggable. When
-- the embedding service is unreachable the vector leg drops out and
-- rank_components.degraded says so — lexical-only, never an error.
CREATE OR REPLACE FUNCTION search_source_chunks(
    p_query TEXT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_document_id UUID DEFAULT NULL,
    p_source_path TEXT DEFAULT NULL,
    p_source_type TEXT DEFAULT NULL,
    p_locator_kind TEXT DEFAULT NULL,
    p_sheet_name TEXT DEFAULT NULL,
    p_page_start INT DEFAULT NULL,
    p_page_end INT DEFAULT NULL,
    p_created_after TIMESTAMPTZ DEFAULT NULL,
    p_created_before TIMESTAMPTZ DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    p_offset INT DEFAULT 0,
    p_snippet_chars INT DEFAULT 300,
    p_weights JSONB DEFAULT NULL
) RETURNS TABLE (
    chunk_id UUID,
    document_id UUID,
    chunk_index INT,
    title TEXT,
    path TEXT,
    source_type TEXT,
    locator_kind TEXT,
    locator JSONB,
    heading_path TEXT[],
    page_start INT,
    page_end INT,
    sheet_name TEXT,
    snippet TEXT,
    content_hash TEXT,
    sensitivity TEXT,
    trust FLOAT,
    last_accessed TIMESTAMPTZ,
    rank FLOAT,
    rank_components JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    query_text TEXT := NULLIF(trim(COALESCE(p_query, '')), '');
    browse_mode BOOLEAN := NULLIF(trim(COALESCE(p_query, '')), '') IS NULL
        OR trim(COALESCE(p_query, '')) = '*';
    lim INT := LEAST(
        GREATEST(COALESCE(
            p_limit,
            get_config_int('memory.source_chunk_search_default_limit'),
            10
        ), 1),
        GREATEST(COALESCE(get_config_int('memory.source_chunk_search_max_limit'), 50), 1)
    );
    offs INT := GREATEST(COALESCE(p_offset, 0), 0);
    snippet_limit INT := GREATEST(COALESCE(p_snippet_chars, 300), 80);
    w_lexical FLOAT := COALESCE((p_weights->>'lexical')::float,
                                get_config_float('retrieval.chunk_weight_lexical'), 0.4);
    w_vector FLOAT := COALESCE((p_weights->>'vector')::float,
                               get_config_float('retrieval.chunk_weight_vector'), 0.6);
    w_recency FLOAT := COALESCE((p_weights->>'recency')::float,
                                get_config_float('retrieval.chunk_weight_recency'), 0.1);
    w_trust FLOAT := COALESCE((p_weights->>'trust')::float,
                              get_config_float('retrieval.chunk_weight_trust'), 0.1);
    w_desk FLOAT := COALESCE((p_weights->>'desk')::float,
                             get_config_float('retrieval.chunk_weight_desk'), 0.05);
    half_life FLOAT := GREATEST(COALESCE(get_config_float('retrieval.chunk_recency_half_life_days'), 30), 0.1);
    fts_query tsquery;
    q_emb vector;
    degraded TEXT := NULL;
    weights_doc JSONB;
BEGIN
    -- Browse mode requires a scope filter (never dump the whole cabinet).
    IF browse_mode
       AND p_document_id IS NULL
       AND NULLIF(trim(COALESCE(p_source_path, '')), '') IS NULL
       AND NULLIF(trim(COALESCE(p_source_type, '')), '') IS NULL
       AND NULLIF(trim(COALESCE(p_locator_kind, '')), '') IS NULL
       AND NULLIF(trim(COALESCE(p_sheet_name, '')), '') IS NULL
       AND p_page_start IS NULL AND p_page_end IS NULL
       AND p_created_after IS NULL AND p_created_before IS NULL THEN
        RETURN;
    END IF;

    IF NOT browse_mode THEN
        BEGIN
            fts_query := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            fts_query := plainto_tsquery('english', query_text);
        END;
        -- Vector leg is best-effort: an unreachable embedding service
        -- degrades to lexical-only with an explicit marker.
        BEGIN
            q_emb := (get_embedding(ARRAY[ensure_embedding_prefix(query_text, 'search_query')]))[1];
        EXCEPTION WHEN OTHERS THEN
            q_emb := NULL;
        END;
        IF q_emb IS NULL THEN
            degraded := 'embedding_unavailable';
        END IF;
    END IF;

    weights_doc := jsonb_build_object(
        'lexical', w_lexical, 'vector', w_vector, 'recency', w_recency,
        'trust', w_trust, 'desk', w_desk
    );

    RETURN QUERY
    WITH filtered AS (
        SELECT
            c.id AS c_chunk_id,
            c.source_document_id AS c_document_id,
            c.chunk_index AS c_chunk_index,
            d.title AS c_title,
            d.path AS c_path,
            d.source_type AS c_source_type,
            c.locator_kind AS c_locator_kind,
            c.locator AS c_locator,
            c.heading_path AS c_heading_path,
            c.page_start AS c_page_start,
            c.page_end AS c_page_end,
            c.sheet_name AS c_sheet_name,
            c.content AS c_content,
            c.content_hash AS c_content_hash,
            NULLIF(d.source_attribution->>'sensitivity', '') AS c_sensitivity,
            COALESCE(NULLIF(d.source_attribution->>'trust', '')::float, 0.5) AS c_trust,
            c.last_accessed AS c_last_accessed,
            c.embedding AS c_embedding,
            c.embedding_status AS c_embedding_status,
            d.updated_at AS c_doc_updated_at
        FROM source_document_chunks c
        JOIN source_documents d ON d.id = c.source_document_id
        WHERE d.status = 'active'
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
          AND (p_document_id IS NULL OR c.source_document_id = p_document_id)
          AND (NULLIF(trim(COALESCE(p_source_path, '')), '') IS NULL
               OR d.path ILIKE '%' || p_source_path || '%')
          AND (NULLIF(trim(COALESCE(p_source_type, '')), '') IS NULL
               OR d.source_type = p_source_type)
          AND (NULLIF(trim(COALESCE(p_locator_kind, '')), '') IS NULL
               OR c.locator_kind = p_locator_kind)
          AND (NULLIF(trim(COALESCE(p_sheet_name, '')), '') IS NULL
               OR c.sheet_name = p_sheet_name)
          AND (p_page_start IS NULL
               OR (c.page_end IS NOT NULL AND c.page_end >= p_page_start))
          AND (p_page_end IS NULL
               OR (c.page_start IS NOT NULL AND c.page_start <= p_page_end))
          AND (p_created_after IS NULL OR d.created_at >= p_created_after)
          AND (p_created_before IS NULL OR d.created_at < p_created_before)
    ),
    vector_hits AS (
        SELECT f.c_chunk_id AS v_id,
               (1.0 - (f.c_embedding <=> q_emb))::float AS vector_score
        FROM filtered f
        WHERE NOT browse_mode
          AND q_emb IS NOT NULL
          AND f.c_embedding_status = 'embedded'
          AND f.c_embedding IS NOT NULL
        ORDER BY f.c_embedding <=> q_emb
        LIMIT lim * 2
    ),
    fts_hits AS (
        SELECT f.c_chunk_id AS t_id,
               ts_rank_cd(to_tsvector('english', f.c_content), fts_query, 32)::float AS raw_fts
        FROM filtered f
        WHERE NOT browse_mode
          AND numnode(fts_query) > 0
          AND to_tsvector('english', f.c_content) @@ fts_query
        ORDER BY raw_fts DESC
        LIMIT lim * 2
    ),
    fts_norm AS (
        SELECT t_id, raw_fts,
               (raw_fts / NULLIF(MAX(raw_fts) OVER (), 0))::float AS lexical_score
        FROM fts_hits
    ),
    merged AS (
        SELECT
            COALESCE(v.v_id, t.t_id) AS m_id,
            v.vector_score,
            t.lexical_score,
            t.raw_fts
        FROM vector_hits v
        FULL OUTER JOIN fts_norm t ON v.v_id = t.t_id
    ),
    browse_rows AS (
        SELECT f.c_chunk_id AS m_id,
               NULL::float AS vector_score,
               NULL::float AS lexical_score,
               NULL::float AS raw_fts
        FROM filtered f
        WHERE browse_mode
        ORDER BY f.c_doc_updated_at DESC, f.c_document_id, f.c_chunk_index
        LIMIT lim * 2 + offs
    ),
    scored AS (
        SELECT
            f.*,
            m.vector_score,
            m.lexical_score,
            m.raw_fts,
            exp(-GREATEST(extract(epoch FROM (CURRENT_TIMESTAMP - f.c_doc_updated_at)) / 86400.0, 0) * ln(2) / half_life)::float AS recency_score,
            EXISTS (
                SELECT 1 FROM subconscious_units u
                WHERE u.status = 'active'
                  AND u.metadata #>> '{recmem,chunk_id}' = f.c_chunk_id::text
            ) AS on_desk
        FROM (
            SELECT * FROM merged
            UNION ALL
            SELECT m_id, vector_score, lexical_score, raw_fts FROM browse_rows
        ) m
        JOIN filtered f ON f.c_chunk_id = m.m_id
    )
    SELECT
        s.c_chunk_id,
        s.c_document_id,
        s.c_chunk_index,
        s.c_title,
        s.c_path,
        s.c_source_type,
        s.c_locator_kind,
        s.c_locator,
        s.c_heading_path,
        s.c_page_start,
        s.c_page_end,
        s.c_sheet_name,
        CASE
            WHEN NOT browse_mode AND s.raw_fts IS NOT NULL AND numnode(fts_query) > 0 THEN left(
                ts_headline(
                    'english', s.c_content, fts_query,
                    'StartSel='''', StopSel='''', MaxWords=45, MinWords=12, ShortWord=3, MaxFragments=2, FragmentDelimiter=" ... "'
                ),
                snippet_limit
            )
            ELSE left(s.c_content, snippet_limit)
        END AS snippet,
        s.c_content_hash,
        s.c_sensitivity,
        s.c_trust,
        s.c_last_accessed,
        CASE WHEN browse_mode THEN 0.0 ELSE (
            w_vector * COALESCE(s.vector_score, 0.0)
            + w_lexical * COALESCE(s.lexical_score, 0.0)
            + w_recency * s.recency_score
            + w_trust * s.c_trust
            + w_desk * CASE WHEN s.on_desk THEN 1.0 ELSE 0.0 END
        ) END AS rank,
        jsonb_strip_nulls(jsonb_build_object(
            'lexical', s.lexical_score,
            'vector', s.vector_score,
            'recency', s.recency_score,
            'trust', s.c_trust,
            'desk', CASE WHEN s.on_desk THEN 1.0 ELSE 0.0 END,
            'weights', weights_doc,
            'degraded', degraded
        )) AS rank_components
    FROM scored s
    ORDER BY 18 DESC, s.c_doc_updated_at DESC, s.c_document_id, s.c_chunk_index
    OFFSET offs
    LIMIT lim;
END;
$$;

-- Open exact chunks — by id list, by document + chunk range, or by document
-- + page range. Returns full content with prev/next handles for scrolling
-- and bumps access stats (opening is a deliberate, audited act).
CREATE OR REPLACE FUNCTION open_source_chunks(
    p_chunk_ids UUID[] DEFAULT NULL,
    p_document_id UUID DEFAULT NULL,
    p_chunk_start INT DEFAULT NULL,
    p_chunk_end INT DEFAULT NULL,
    p_page_start INT DEFAULT NULL,
    p_page_end INT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    chunk_rows JSONB;
    matched_ids UUID[];
    total_matches INT := 0;
BEGIN
    IF COALESCE(array_length(p_chunk_ids, 1), 0) = 0 AND p_document_id IS NULL THEN
        RETURN jsonb_build_object('error', 'missing_selector');
    END IF;

    WITH requested AS (
        SELECT c.id, c.chunk_index,
               CASE WHEN ids.ord IS NULL THEN 1000000 + c.chunk_index ELSE ids.ord END AS ord
        FROM source_document_chunks c
        JOIN source_documents d ON d.id = c.source_document_id
        LEFT JOIN unnest(COALESCE(p_chunk_ids, ARRAY[]::UUID[])) WITH ORDINALITY AS ids(chunk_id, ord)
               ON ids.chunk_id = c.id
        WHERE d.status = 'active'
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
          AND (
              ids.chunk_id IS NOT NULL
              OR (
                  p_document_id IS NOT NULL
                  AND c.source_document_id = p_document_id
                  AND (p_chunk_start IS NULL OR c.chunk_index >= p_chunk_start)
                  AND (p_chunk_end IS NULL OR c.chunk_index <= p_chunk_end)
                  AND (p_page_start IS NULL
                       OR (c.page_end IS NOT NULL AND c.page_end >= p_page_start))
                  AND (p_page_end IS NULL
                       OR (c.page_start IS NOT NULL AND c.page_start <= p_page_end))
                  -- A bare document id is a valid "open the whole thing" ask,
                  -- capped by lim like every other selector.
              )
          )
    ),
    counted AS (SELECT COUNT(*) AS total FROM requested),
    limited AS (
        SELECT id FROM requested ORDER BY ord LIMIT lim
    )
    SELECT array_agg(id), (SELECT total FROM counted)
    INTO matched_ids, total_matches
    FROM limited;

    IF matched_ids IS NULL OR array_length(matched_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    -- Opening feeds recency signals (and future GC/retention decisions).
    UPDATE source_document_chunks
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = ANY(matched_ids);

    SELECT jsonb_agg(jsonb_build_object(
        'chunk_id', c.id::text,
        'document_id', c.source_document_id::text,
        'chunk_index', c.chunk_index,
        'title', d.title,
        'path', d.path,
        'source_type', d.source_type,
        'locator_kind', c.locator_kind,
        'locator', c.locator,
        'heading_path', to_jsonb(c.heading_path),
        'page_start', c.page_start,
        'page_end', c.page_end,
        'sheet_name', c.sheet_name,
        'char_start', c.char_start,
        'char_end', c.char_end,
        'content', c.content,
        'content_hash', c.content_hash,
        'prev_chunk_id', (
            SELECT p.id::text FROM source_document_chunks p
            WHERE p.source_document_id = c.source_document_id AND p.chunk_index < c.chunk_index
            ORDER BY p.chunk_index DESC LIMIT 1
        ),
        'next_chunk_id', (
            SELECT n.id::text FROM source_document_chunks n
            WHERE n.source_document_id = c.source_document_id AND n.chunk_index > c.chunk_index
            ORDER BY n.chunk_index LIMIT 1
        )
    ) ORDER BY ord.ordinality)
    INTO chunk_rows
    FROM unnest(matched_ids) WITH ORDINALITY AS ord(chunk_id, ordinality)
    JOIN source_document_chunks c ON c.id = ord.chunk_id
    JOIN source_documents d ON d.id = c.source_document_id;

    RETURN jsonb_build_object(
        'chunks', COALESCE(chunk_rows, '[]'::jsonb),
        'count', COALESCE(jsonb_array_length(chunk_rows), 0),
        'total_matches', total_matches,
        'limit', lim
    );
END;
$$;

-- Documents that need (re)chunking: active docs with no chunks at all, or —
-- when a chunker version is given — chunks produced by an older chunker.
-- Returns handles only; the backfill runner fetches content per document.
CREATE OR REPLACE FUNCTION source_chunk_backfill_candidates(
    p_limit INT DEFAULT 20,
    p_chunker_version TEXT DEFAULT NULL
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(row_doc), '[]'::jsonb)
    FROM (
        SELECT jsonb_build_object(
            'document_id', d.id,
            'title', d.title,
            'path', d.path,
            'file_type', d.file_type,
            'content_hash', d.content_hash,
            'word_count', d.word_count
        ) AS row_doc
        FROM source_documents d
        WHERE d.status = 'active'
          AND (
              NOT EXISTS (
                  SELECT 1 FROM source_document_chunks c
                  WHERE c.source_document_id = d.id
              )
              OR (
                  p_chunker_version IS NOT NULL
                  AND EXISTS (
                      SELECT 1 FROM source_document_chunks c
                      WHERE c.source_document_id = d.id
                        AND c.chunker_version IS DISTINCT FROM p_chunker_version
                  )
              )
          )
        ORDER BY d.last_ingested_at DESC
        LIMIT GREATEST(COALESCE(p_limit, 20), 1)
    ) sub;
$$ LANGUAGE sql STABLE;
