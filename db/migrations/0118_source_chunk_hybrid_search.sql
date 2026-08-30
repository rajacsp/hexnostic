-- 0118: Hybrid chunk retrieval + evolved document search.
-- search_source_chunks fuses full-text and vector similarity with weighted
-- recency/trust/desk components and inspectable rank_components;
-- open_source_chunks opens exact passages with scroll handles; document
-- search now aggregates best-passage rank and appends hybrid columns.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
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

-- The return type gained hybrid columns (rank_components, best chunk handle,
-- extraction warnings); DROP by exact input signature so live DBs upgrade.
DROP FUNCTION IF EXISTS search_source_documents(TEXT, INT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, INT, INT, BOOLEAN);

CREATE OR REPLACE FUNCTION search_source_documents(
    p_query TEXT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_source_path TEXT DEFAULT NULL,
    p_source_type TEXT DEFAULT NULL,
    p_created_after TIMESTAMPTZ DEFAULT NULL,
    p_created_before TIMESTAMPTZ DEFAULT NULL,
    p_include_content BOOLEAN DEFAULT FALSE,
    p_offset INT DEFAULT 0,
    p_snippet_chars INT DEFAULT 500,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    document_id UUID,
    title TEXT,
    source_type TEXT,
    path TEXT,
    file_type TEXT,
    content_hash TEXT,
    word_count INT,
    size_bytes INT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    rank FLOAT,
    snippet TEXT,
    content TEXT,
    rank_components JSONB,
    best_chunk_id UUID,
    best_chunk_locator JSONB,
    extraction_warnings JSONB
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
            get_config_int('memory.document_search_default_limit'),
            10
        ), 1),
        GREATEST(COALESCE(get_config_int('memory.document_search_max_limit'), 50), 1)
    );
    offs INT := GREATEST(COALESCE(p_offset, 0), 0);
    snippet_limit INT := GREATEST(COALESCE(p_snippet_chars, 500), 80);
BEGIN
    IF browse_mode
       AND NULLIF(trim(COALESCE(p_source_path, '')), '') IS NULL
       AND NULLIF(trim(COALESCE(p_source_type, '')), '') IS NULL
       AND p_created_after IS NULL
       AND p_created_before IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH query_doc AS (
        SELECT CASE WHEN browse_mode THEN NULL ELSE websearch_to_tsquery('english', query_text) END AS q
    ),
    -- Hybrid chunk hits (lexical ⟗ vector, weighted components) aggregated
    -- per document: a document ranks by its best passage as well as its
    -- whole-text match, and carries that passage's handle for citation.
    chunk_hits AS (
        SELECT
            s.document_id AS ch_document_id,
            MAX(s.rank) AS best_chunk_rank,
            (array_agg(s.chunk_id ORDER BY s.rank DESC))[1] AS ch_best_chunk_id,
            (array_agg(s.locator ORDER BY s.rank DESC))[1] AS ch_best_chunk_locator,
            (array_agg(s.rank_components ORDER BY s.rank DESC))[1] AS ch_best_components
        FROM search_source_chunks(
            p_query, GREATEST(lim * 3, 30), NULL, p_source_path, p_source_type,
            NULL, NULL, NULL, NULL, p_created_after, p_created_before,
            p_exclude_sensitive, 0, 120, NULL
        ) s
        WHERE NOT browse_mode
        GROUP BY s.document_id
    ),
    candidates AS (
        SELECT
            d.id,
            d.title,
            d.source_type,
            d.path,
            d.file_type,
            d.content_hash,
            d.word_count,
            d.size_bytes,
            d.created_at,
            d.updated_at,
            CASE
                WHEN browse_mode OR numnode(q.q) = 0 THEN 0.0
                ELSE ts_rank_cd(
                    to_tsvector('english', d.title || ' ' || COALESCE(d.path, '') || ' ' || d.content),
                    q.q,
                    32
                )::FLOAT
            END AS doc_rank,
            CASE
                WHEN p_include_content THEN d.content
                WHEN NOT browse_mode AND numnode(q.q) > 0 THEN left(
                    ts_headline(
                        'english',
                        d.content,
                        q.q,
                        'StartSel='''', StopSel='''', MaxWords=45, MinWords=12, ShortWord=3, MaxFragments=2, FragmentDelimiter=" ... "'
                    ),
                    snippet_limit
                )
                ELSE left(d.content, snippet_limit)
            END AS snippet,
            CASE WHEN p_include_content THEN d.content ELSE NULL::TEXT END AS content
        FROM source_documents d
        CROSS JOIN query_doc q
        WHERE d.status = 'active'
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
          AND (p_created_after IS NULL OR d.created_at >= p_created_after)
          AND (p_created_before IS NULL OR d.created_at < p_created_before)
          AND (NULLIF(trim(COALESCE(p_source_type, '')), '') IS NULL OR d.source_type = p_source_type)
          AND (
              NULLIF(trim(COALESCE(p_source_path, '')), '') IS NULL
              OR d.path ILIKE '%' || p_source_path || '%'
          )
          AND (
              browse_mode
              OR (
                  numnode(q.q) > 0
                  AND to_tsvector('english', d.title || ' ' || COALESCE(d.path, '') || ' ' || d.content) @@ q.q
              )
              OR d.title ILIKE '%' || query_text || '%'
              OR COALESCE(d.path, '') ILIKE '%' || query_text || '%'
              OR EXISTS (SELECT 1 FROM chunk_hits ch WHERE ch.ch_document_id = d.id)
          )
    )
    SELECT
        c.id,
        c.title,
        c.source_type,
        c.path,
        c.file_type,
        c.content_hash,
        c.word_count,
        c.size_bytes,
        c.created_at,
        c.updated_at,
        GREATEST(c.doc_rank, COALESCE(ch.best_chunk_rank, 0.0)) AS rank,
        c.snippet,
        c.content,
        jsonb_strip_nulls(jsonb_build_object(
            'doc_lexical', c.doc_rank,
            'best_chunk_rank', ch.best_chunk_rank,
            'best_chunk', ch.ch_best_components
        )) AS rank_components,
        ch.ch_best_chunk_id AS best_chunk_id,
        ch.ch_best_chunk_locator AS best_chunk_locator,
        COALESCE((
            SELECT r.warnings
            FROM source_extraction_runs r
            WHERE r.source_document_id = c.id
            ORDER BY r.created_at DESC
            LIMIT 1
        ), '[]'::jsonb) AS extraction_warnings
    FROM candidates c
    LEFT JOIN chunk_hits ch ON ch.ch_document_id = c.id
    ORDER BY GREATEST(c.doc_rank, COALESCE(ch.best_chunk_rank, 0.0)) DESC, c.updated_at DESC, c.id
    OFFSET offs
    LIMIT lim;
END;
$$;
