-- Durable source document storage and deliberate full-text retrieval.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.document_search_default_limit', '10'::jsonb,
     'Default row budget for source-document search'),
    ('memory.document_search_max_limit', '50'::jsonb,
     'Ceiling on source-document search rows; open_document retrieves exact content on demand'),
    ('memory.source_document_desk_chunk_chars', '8000'::jsonb,
     'Default chunk size when loading source documents onto the RecMem desk'),
    ('ingest.artifact_max_db_bytes', '26214400'::jsonb,
     'Original artifacts up to this many bytes are stored in-DB (rides pg_dump backups); larger ones live in the managed artifact directory'),
    ('ingest.xlsx_max_rows_per_sheet', '5000'::jsonb,
     'Rows extracted per spreadsheet sheet; capping always emits a truncated_rows extraction warning, never a silent cut')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION upsert_source_document(
    p_title TEXT,
    p_source_type TEXT,
    p_content_hash TEXT,
    p_path TEXT,
    p_file_type TEXT,
    p_content TEXT,
    p_word_count INT DEFAULT 0,
    p_source_attribution JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    doc_id UUID;
    row_doc source_documents%ROWTYPE;
BEGIN
    IF NULLIF(trim(COALESCE(p_content_hash, '')), '') IS NULL THEN
        RAISE EXCEPTION 'source document content_hash is required';
    END IF;
    IF p_content IS NULL THEN
        RAISE EXCEPTION 'source document content is required';
    END IF;

    INSERT INTO source_documents (
        title,
        source_type,
        content_hash,
        path,
        file_type,
        content,
        word_count,
        size_bytes,
        source_attribution,
        metadata
    )
    VALUES (
        COALESCE(NULLIF(trim(p_title), ''), COALESCE(NULLIF(trim(p_path), ''), p_content_hash)),
        COALESCE(NULLIF(trim(p_source_type), ''), 'document'),
        p_content_hash,
        NULLIF(trim(COALESCE(p_path, '')), ''),
        NULLIF(trim(COALESCE(p_file_type, '')), ''),
        p_content,
        GREATEST(COALESCE(p_word_count, 0), 0),
        octet_length(p_content),
        COALESCE(p_source_attribution, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (content_hash) DO UPDATE
    SET title = CASE WHEN source_documents.status = 'redacted' THEN source_documents.title ELSE EXCLUDED.title END,
        source_type = CASE WHEN source_documents.status = 'redacted' THEN source_documents.source_type ELSE EXCLUDED.source_type END,
        path = CASE WHEN source_documents.status = 'redacted' THEN source_documents.path ELSE COALESCE(EXCLUDED.path, source_documents.path) END,
        file_type = CASE WHEN source_documents.status = 'redacted' THEN source_documents.file_type ELSE COALESCE(EXCLUDED.file_type, source_documents.file_type) END,
        content = CASE WHEN source_documents.status = 'redacted' THEN source_documents.content ELSE EXCLUDED.content END,
        word_count = CASE WHEN source_documents.status = 'redacted' THEN source_documents.word_count ELSE EXCLUDED.word_count END,
        size_bytes = CASE WHEN source_documents.status = 'redacted' THEN source_documents.size_bytes ELSE EXCLUDED.size_bytes END,
        source_attribution = CASE
            WHEN source_documents.status = 'redacted' THEN source_documents.source_attribution
            ELSE source_documents.source_attribution || EXCLUDED.source_attribution
        END,
        metadata = CASE
            WHEN source_documents.status = 'redacted' THEN source_documents.metadata
            ELSE source_documents.metadata || EXCLUDED.metadata
        END,
        updated_at = CURRENT_TIMESTAMP,
        last_ingested_at = CURRENT_TIMESTAMP,
        status = CASE
            WHEN source_documents.status = 'redacted' THEN source_documents.status
            ELSE 'active'
        END
    RETURNING id INTO doc_id;

    SELECT * INTO row_doc FROM source_documents WHERE id = doc_id;
    RETURN jsonb_build_object(
        'document_id', row_doc.id::text,
        'content_hash', row_doc.content_hash,
        'title', row_doc.title,
        'source_type', row_doc.source_type,
        'path', row_doc.path,
        'file_type', row_doc.file_type,
        'word_count', row_doc.word_count,
        'size_bytes', row_doc.size_bytes,
        'status', row_doc.status,
        'updated_at', row_doc.updated_at
    );
END;
$$;

-- Preserve an original artifact (bytes or a stable reference), keyed by
-- sha256. Never rewrites stored bytes; links the source document once known
-- (and stamps source_documents.original_hash); redacted artifacts frozen.
CREATE OR REPLACE FUNCTION upsert_source_artifact(
    p_sha256 TEXT,
    p_storage_kind TEXT,
    p_bytes BYTEA DEFAULT NULL,
    p_storage_ref TEXT DEFAULT NULL,
    p_source_document_id UUID DEFAULT NULL,
    p_original_filename TEXT DEFAULT NULL,
    p_mime_type TEXT DEFAULT NULL,
    p_byte_size BIGINT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    artifact source_artifacts%ROWTYPE;
    existed BOOLEAN;
BEGIN
    IF NULLIF(trim(COALESCE(p_sha256, '')), '') IS NULL THEN
        RAISE EXCEPTION 'source artifact sha256 is required';
    END IF;
    IF p_storage_kind NOT IN ('database', 'filesystem', 'connector', 'url', 'external') THEN
        RAISE EXCEPTION 'invalid storage_kind: %', p_storage_kind;
    END IF;

    SELECT EXISTS (SELECT 1 FROM source_artifacts WHERE sha256 = p_sha256) INTO existed;

    INSERT INTO source_artifacts (
        sha256, storage_kind, bytes, storage_ref, source_document_id,
        original_filename, mime_type, byte_size, metadata
    )
    VALUES (
        p_sha256,
        p_storage_kind,
        p_bytes,
        NULLIF(trim(COALESCE(p_storage_ref, '')), ''),
        p_source_document_id,
        NULLIF(trim(COALESCE(p_original_filename, '')), ''),
        NULLIF(trim(COALESCE(p_mime_type, '')), ''),
        COALESCE(p_byte_size, octet_length(p_bytes), 0),
        COALESCE(p_metadata, '{}'::jsonb)
    )
    ON CONFLICT (sha256) DO UPDATE
    SET source_document_id = CASE
            WHEN source_artifacts.status = 'redacted' THEN source_artifacts.source_document_id
            ELSE COALESCE(source_artifacts.source_document_id, EXCLUDED.source_document_id)
        END,
        storage_ref = CASE
            WHEN source_artifacts.status = 'redacted' THEN source_artifacts.storage_ref
            ELSE COALESCE(source_artifacts.storage_ref, EXCLUDED.storage_ref)
        END,
        original_filename = CASE
            WHEN source_artifacts.status = 'redacted' THEN source_artifacts.original_filename
            ELSE COALESCE(source_artifacts.original_filename, EXCLUDED.original_filename)
        END,
        mime_type = CASE
            WHEN source_artifacts.status = 'redacted' THEN source_artifacts.mime_type
            ELSE COALESCE(source_artifacts.mime_type, EXCLUDED.mime_type)
        END,
        metadata = CASE
            WHEN source_artifacts.status = 'redacted' THEN source_artifacts.metadata
            ELSE source_artifacts.metadata || EXCLUDED.metadata
        END,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO artifact;

    IF artifact.source_document_id IS NOT NULL THEN
        UPDATE source_documents
        SET original_hash = p_sha256, updated_at = CURRENT_TIMESTAMP
        WHERE id = artifact.source_document_id
          AND status <> 'redacted'
          AND original_hash IS DISTINCT FROM p_sha256;
    END IF;

    RETURN jsonb_build_object(
        'artifact_id', artifact.id::text,
        'sha256', artifact.sha256,
        'storage_kind', artifact.storage_kind,
        'storage_ref', artifact.storage_ref,
        'byte_size', artifact.byte_size,
        'source_document_id', artifact.source_document_id,
        'deduplicated', existed
    );
END;
$$;

-- Artifact handle without bytes (bytes are fetched directly by CLI/API to
-- avoid base64-in-JSONB bloat).
CREATE OR REPLACE FUNCTION get_source_artifact(
    p_document_id UUID DEFAULT NULL,
    p_artifact_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT jsonb_build_object(
            'artifact_id', a.id::text,
            'source_document_id', a.source_document_id,
            'storage_kind', a.storage_kind,
            'storage_ref', a.storage_ref,
            'original_filename', a.original_filename,
            'mime_type', a.mime_type,
            'byte_size', a.byte_size,
            'sha256', a.sha256,
            'status', a.status,
            'has_bytes', a.bytes IS NOT NULL,
            'created_at', a.created_at,
            'metadata', a.metadata
        )
        FROM source_artifacts a
        WHERE (p_artifact_id IS NOT NULL AND a.id = p_artifact_id)
           OR (p_artifact_id IS NULL AND p_document_id IS NOT NULL
               AND a.source_document_id = p_document_id)
        ORDER BY a.created_at DESC
        LIMIT 1
    ), jsonb_build_object('error', 'not_found'));
$$;

-- Record one extractor run: name/version, status, structured warnings and
-- errors. Failed runs may carry an artifact but no document — the source is
-- preserved and the failure inspectable.
CREATE OR REPLACE FUNCTION record_source_extraction_run(
    p_document_id UUID DEFAULT NULL,
    p_artifact_id UUID DEFAULT NULL,
    p_extractor_name TEXT DEFAULT 'unknown',
    p_extractor_version TEXT DEFAULT '',
    p_status TEXT DEFAULT 'completed',
    p_warnings JSONB DEFAULT '[]'::jsonb,
    p_errors JSONB DEFAULT '[]'::jsonb,
    p_started_at TIMESTAMPTZ DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    run_id UUID;
    effective_status TEXT := p_status;
BEGIN
    IF effective_status = 'completed'
       AND jsonb_array_length(COALESCE(p_warnings, '[]'::jsonb)) > 0 THEN
        effective_status := 'completed_with_warnings';
    END IF;
    INSERT INTO source_extraction_runs (
        source_document_id, artifact_id, extractor_name, extractor_version,
        status, warnings, errors, started_at, metadata
    )
    VALUES (
        p_document_id, p_artifact_id,
        COALESCE(NULLIF(trim(p_extractor_name), ''), 'unknown'),
        COALESCE(p_extractor_version, ''),
        effective_status,
        COALESCE(p_warnings, '[]'::jsonb),
        COALESCE(p_errors, '[]'::jsonb),
        p_started_at,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO run_id;

    RETURN jsonb_build_object('run_id', run_id::text, 'status', effective_status);
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

CREATE OR REPLACE FUNCTION open_source_document(
    p_document_id UUID DEFAULT NULL,
    p_content_hash TEXT DEFAULT NULL,
    p_path TEXT DEFAULT NULL,
    p_offset INT DEFAULT 0,
    p_max_chars INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    doc source_documents%ROWTYPE;
    start_offset INT := GREATEST(COALESCE(p_offset, 0), 0);
    max_chars INT := p_max_chars;
    total_chars INT;
    body TEXT;
    truncated BOOLEAN;
    extraction JSONB;
BEGIN
    IF p_document_id IS NULL
       AND NULLIF(trim(COALESCE(p_content_hash, '')), '') IS NULL
       AND NULLIF(trim(COALESCE(p_path, '')), '') IS NULL THEN
        RETURN jsonb_build_object('error', 'missing_selector');
    END IF;

    SELECT *
    INTO doc
    FROM source_documents d
    WHERE d.status = 'active'
      AND (NOT COALESCE(p_exclude_sensitive, FALSE)
           OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
      AND (p_document_id IS NULL OR d.id = p_document_id)
      AND (NULLIF(trim(COALESCE(p_content_hash, '')), '') IS NULL OR d.content_hash = p_content_hash)
      AND (
          NULLIF(trim(COALESCE(p_path, '')), '') IS NULL
          OR d.path = p_path
          OR d.path ILIKE '%' || p_path || '%'
      )
    ORDER BY d.updated_at DESC, d.id
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    total_chars := length(doc.content);
    IF max_chars IS NULL OR max_chars <= 0 THEN
        body := substring(doc.content FROM start_offset + 1);
    ELSE
        body := substring(doc.content FROM start_offset + 1 FOR max_chars);
    END IF;
    truncated := start_offset + length(body) < total_chars;

    -- Latest extraction run: warnings ride along so a reader never treats
    -- OCR'd/truncated text as pristine without knowing.
    SELECT jsonb_build_object(
        'status', r.status,
        'extractor', r.extractor_name,
        'extractor_version', r.extractor_version,
        'warnings', r.warnings,
        'completed_at', r.completed_at
    )
    INTO extraction
    FROM source_extraction_runs r
    WHERE r.source_document_id = doc.id
    ORDER BY r.created_at DESC
    LIMIT 1;

    RETURN jsonb_build_object(
        'document_id', doc.id::text,
        'title', doc.title,
        'source_type', doc.source_type,
        'path', doc.path,
        'file_type', doc.file_type,
        'content_hash', doc.content_hash,
        'original_hash', doc.original_hash,
        'word_count', doc.word_count,
        'size_bytes', doc.size_bytes,
        'created_at', doc.created_at,
        'updated_at', doc.updated_at,
        'source_attribution', doc.source_attribution,
        'metadata', doc.metadata,
        'extraction', extraction,
        'extraction_warnings', COALESCE(extraction->'warnings', '[]'::jsonb),
        'offset', start_offset,
        'max_chars', max_chars,
        'total_chars', total_chars,
        'returned_chars', length(body),
        'truncated', truncated,
        'next_offset', CASE WHEN truncated THEN start_offset + length(body) ELSE NULL END,
        'content', body
    );
END;
$$;

CREATE OR REPLACE FUNCTION open_source_documents(
    p_document_ids UUID[] DEFAULT NULL,
    p_content_hashes TEXT[] DEFAULT NULL,
    p_paths TEXT[] DEFAULT NULL,
    p_offset INT DEFAULT 0,
    p_max_chars INT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    start_offset INT := GREATEST(COALESCE(p_offset, 0), 0);
    doc_ids UUID[] := ARRAY[]::UUID[];
    documents JSONB := '[]'::jsonb;
    total_matches INT := 0;
BEGIN
    IF COALESCE(array_length(p_document_ids, 1), 0) = 0
       AND COALESCE(array_length(p_content_hashes, 1), 0) = 0
       AND COALESCE(array_length(p_paths, 1), 0) = 0 THEN
        RETURN jsonb_build_object('error', 'missing_selector');
    END IF;

    WITH requested AS (
        SELECT ord::BIGINT AS ord, document_id, NULL::TEXT AS content_hash, NULL::TEXT AS path
        FROM unnest(COALESCE(p_document_ids, ARRAY[]::UUID[])) WITH ORDINALITY AS ids(document_id, ord)
        UNION ALL
        SELECT (100000 + ord)::BIGINT AS ord, NULL::UUID AS document_id, content_hash, NULL::TEXT AS path
        FROM unnest(COALESCE(p_content_hashes, ARRAY[]::TEXT[])) WITH ORDINALITY AS hashes(content_hash, ord)
        WHERE NULLIF(trim(COALESCE(content_hash, '')), '') IS NOT NULL
        UNION ALL
        SELECT (200000 + ord)::BIGINT AS ord, NULL::UUID AS document_id, NULL::TEXT AS content_hash, path
        FROM unnest(COALESCE(p_paths, ARRAY[]::TEXT[])) WITH ORDINALITY AS paths(path, ord)
        WHERE NULLIF(trim(COALESCE(path, '')), '') IS NOT NULL
    ),
    matched AS (
        SELECT
            d.id,
            MIN(r.ord) AS first_requested_at,
            MAX(d.updated_at) AS newest_updated_at,
            COUNT(*) OVER () AS total_count
        FROM requested r
        JOIN source_documents d ON d.status = 'active'
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
          AND (
              (r.document_id IS NOT NULL AND d.id = r.document_id)
              OR (NULLIF(trim(COALESCE(r.content_hash, '')), '') IS NOT NULL
                  AND d.content_hash = r.content_hash)
              OR (NULLIF(trim(COALESCE(r.path, '')), '') IS NOT NULL
                  AND (d.path = r.path OR d.path ILIKE '%' || r.path || '%'))
          )
        GROUP BY d.id
        ORDER BY first_requested_at, newest_updated_at DESC, d.id
        LIMIT lim
    )
    SELECT
        COALESCE(array_agg(id ORDER BY first_requested_at, newest_updated_at DESC, id), ARRAY[]::UUID[]),
        COALESCE(MAX(total_count), 0)
    INTO doc_ids, total_matches
    FROM matched;

    SELECT COALESCE(
        jsonb_agg(open_source_document(d.id, NULL, NULL, start_offset, p_max_chars, p_exclude_sensitive) ORDER BY d.ord),
        '[]'::jsonb
    )
    INTO documents
    FROM unnest(doc_ids) WITH ORDINALITY AS d(id, ord);

    RETURN jsonb_build_object(
        'documents', documents,
        'count', jsonb_array_length(documents),
        'total_matches', total_matches,
        'limit', lim,
        'offset', start_offset,
        'max_chars', p_max_chars
    );
END;
$$;

CREATE OR REPLACE FUNCTION load_source_documents_to_recmem(
    p_document_ids UUID[] DEFAULT NULL,
    p_content_hashes TEXT[] DEFAULT NULL,
    p_paths TEXT[] DEFAULT NULL,
    p_offset INT DEFAULT 0,
    p_max_chars INT DEFAULT NULL,
    p_chunk_chars INT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    start_offset INT := GREATEST(COALESCE(p_offset, 0), 0);
    chunk_chars INT := GREATEST(COALESCE(p_chunk_chars, get_config_int('memory.source_document_desk_chunk_chars'), 8000), 500);
    payload JSONB;
BEGIN
    IF COALESCE(array_length(p_document_ids, 1), 0) = 0
       AND COALESCE(array_length(p_content_hashes, 1), 0) = 0
       AND COALESCE(array_length(p_paths, 1), 0) = 0 THEN
        RETURN jsonb_build_object('error', 'missing_selector');
    END IF;

    WITH requested AS (
        SELECT ord::BIGINT AS ord, document_id, NULL::TEXT AS content_hash, NULL::TEXT AS path
        FROM unnest(COALESCE(p_document_ids, ARRAY[]::UUID[])) WITH ORDINALITY AS ids(document_id, ord)
        UNION ALL
        SELECT (100000 + ord)::BIGINT AS ord, NULL::UUID AS document_id, content_hash, NULL::TEXT AS path
        FROM unnest(COALESCE(p_content_hashes, ARRAY[]::TEXT[])) WITH ORDINALITY AS hashes(content_hash, ord)
        WHERE NULLIF(trim(COALESCE(content_hash, '')), '') IS NOT NULL
        UNION ALL
        SELECT (200000 + ord)::BIGINT AS ord, NULL::UUID AS document_id, NULL::TEXT AS content_hash, path
        FROM unnest(COALESCE(p_paths, ARRAY[]::TEXT[])) WITH ORDINALITY AS paths(path, ord)
        WHERE NULLIF(trim(COALESCE(path, '')), '') IS NOT NULL
    ),
    matched AS (
        SELECT
            d.*,
            MIN(r.ord) AS first_requested_at,
            COUNT(*) OVER () AS total_matches
        FROM requested r
        JOIN source_documents d ON d.status = 'active'
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(d.source_attribution->>'sensitivity', '') <> 'private')
          AND (
              (r.document_id IS NOT NULL AND d.id = r.document_id)
              OR (NULLIF(trim(COALESCE(r.content_hash, '')), '') IS NOT NULL
                  AND d.content_hash = r.content_hash)
              OR (NULLIF(trim(COALESCE(r.path, '')), '') IS NOT NULL
                  AND (d.path = r.path OR d.path ILIKE '%' || r.path || '%'))
          )
        GROUP BY d.id
        ORDER BY first_requested_at, d.updated_at DESC, d.id
        LIMIT lim
    ),
    selected AS (
        SELECT
            m.*,
            substring(
                m.content FROM start_offset + 1
                FOR CASE WHEN p_max_chars IS NULL OR p_max_chars <= 0 THEN length(m.content)
                         ELSE p_max_chars END
            ) AS selected_content
        FROM matched m
    ),
    chunks AS (
        SELECT
            s.id AS document_id,
            s.title,
            s.source_type,
            s.path,
            s.file_type,
            s.content_hash,
            s.word_count,
            s.size_bytes,
            s.source_attribution AS document_source_attribution,
            s.total_matches,
            (chunk_start / chunk_chars)::INT AS chunk_index,
            start_offset + chunk_start AS chunk_offset,
            substring(s.selected_content FROM chunk_start + 1 FOR chunk_chars) AS chunk_content,
            length(s.content) AS total_chars
        FROM selected s
        CROSS JOIN LATERAL generate_series(
            0,
            GREATEST(length(s.selected_content) - 1, 0),
            chunk_chars
        ) AS g(chunk_start)
        WHERE length(s.selected_content) > 0
    ),
    upserted AS (
        INSERT INTO subconscious_units (
            source_identity,
            content,
            user_text,
            assistant_text,
            embedding_status,
            route_status,
            extraction_status,
            importance,
            source_attribution,
            metadata,
            idempotency_key,
            access_count,
            last_accessed
        )
        SELECT
            'source_document:' || c.document_id::text || ':' || c.chunk_offset::text,
            concat_ws(E'\n',
                '[Source Document: ' || c.title || ']',
                CASE WHEN c.path IS NOT NULL THEN '[Path: ' || c.path || ']' END,
                '[Document ID: ' || c.document_id::text || ']',
                '[Chunk: ' || c.chunk_index::text || ', chars '
                    || c.chunk_offset::text || '-'
                    || (c.chunk_offset + length(c.chunk_content))::text || ' of '
                    || c.total_chars::text || ']',
                '',
                c.chunk_content
            ),
            NULL,
            NULL,
            'pending',
            'raw_only',
            'skipped',
            0.2,
            jsonb_strip_nulls(jsonb_build_object(
                'kind', 'source_document_desk',
                'ref', c.content_hash,
                'label', c.title,
                'content_hash', c.content_hash,
                'path', c.path,
                'source_document_id', c.document_id::text,
                'document_id', c.document_id::text,
                'sensitivity', CASE WHEN c.document_source_attribution->>'sensitivity' = 'private' THEN 'private' END
            )),
            jsonb_build_object(
                'recmem', jsonb_strip_nulls(jsonb_build_object(
                    'kind', 'source_document_desk',
                    'loaded_at', CURRENT_TIMESTAMP,
                    'reason', NULLIF(trim(COALESCE(p_reason, '')), ''),
                    'document_id', c.document_id::text,
                    'title', c.title,
                    'path', c.path,
                    'content_hash', c.content_hash,
                    'chunk_index', c.chunk_index,
                    'offset', c.chunk_offset,
                    'end_offset', c.chunk_offset + length(c.chunk_content),
                    'chunk_chars', chunk_chars,
                    'total_matches', c.total_matches,
                    'routing_skipped', true,
                    'extraction_skipped', true
                ))
            ),
            'source_document_desk:' || c.document_id::text || ':' || c.chunk_offset::text || ':' || chunk_chars::text,
            1,
            CURRENT_TIMESTAMP
        FROM chunks c
        ON CONFLICT (idempotency_key) DO UPDATE
        SET status = 'active',
            embedding_status = CASE
                WHEN subconscious_units.embedding_status = 'failed'
                     AND COALESCE(subconscious_units.metadata#>>'{recmem,embedding_skipped}', 'false')::boolean
                    THEN 'pending'
                ELSE subconscious_units.embedding_status
            END,
            embedding_claimed_at = CASE
                WHEN subconscious_units.embedding_status = 'failed'
                     AND COALESCE(subconscious_units.metadata#>>'{recmem,embedding_skipped}', 'false')::boolean
                    THEN NULL
                ELSE subconscious_units.embedding_claimed_at
            END,
            access_count = subconscious_units.access_count + 1,
            last_accessed = CURRENT_TIMESTAMP,
            metadata = subconscious_units.metadata
                || jsonb_build_object(
                    'recmem',
                    COALESCE(subconscious_units.metadata->'recmem', '{}'::jsonb)
                    || COALESCE(EXCLUDED.metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object('last_loaded_at', CURRENT_TIMESTAMP)
                ),
            updated_at = CURRENT_TIMESTAMP
        RETURNING
            id,
            source_attribution,
            metadata,
            created_at,
            updated_at
    )
    SELECT jsonb_build_object(
        'loaded_units', COALESCE(jsonb_agg(jsonb_build_object(
            'unit_id', u.id::text,
            'document_id', u.source_attribution->>'source_document_id',
            'title', u.source_attribution->>'label',
            'path', u.source_attribution->>'path',
            'content_hash', u.source_attribution->>'content_hash',
            'chunk_index', NULLIF(u.metadata#>>'{recmem,chunk_index}', '')::INT,
            'offset', NULLIF(u.metadata#>>'{recmem,offset}', '')::INT,
            'end_offset', NULLIF(u.metadata#>>'{recmem,end_offset}', '')::INT
        ) ORDER BY u.source_attribution->>'label', NULLIF(u.metadata#>>'{recmem,offset}', '')::INT), '[]'::jsonb),
        'desk_unit_ids', COALESCE(jsonb_agg(u.id::text ORDER BY u.source_attribution->>'label', NULLIF(u.metadata#>>'{recmem,offset}', '')::INT), '[]'::jsonb),
        'count', COUNT(u.id),
        'limit', lim,
        'offset', start_offset,
        'chunk_chars', chunk_chars,
        'max_chars', p_max_chars,
        'total_matches', COALESCE(MAX((u.metadata#>>'{recmem,total_matches}')::INT), COUNT(u.id))
    )
    INTO payload
    FROM upserted u;

    RETURN COALESCE(payload, jsonb_build_object(
        'loaded_units', '[]'::jsonb,
        'desk_unit_ids', '[]'::jsonb,
        'count', 0,
        'limit', lim,
        'offset', start_offset,
        'chunk_chars', chunk_chars,
        'max_chars', p_max_chars
    ));
END;
$$;
