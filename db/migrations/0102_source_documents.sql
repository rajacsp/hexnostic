-- 0102: Preserve raw ingested source documents for deliberate search/open.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS source_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    title TEXT NOT NULL,
    source_type TEXT NOT NULL,
    content_hash TEXT NOT NULL UNIQUE,
    path TEXT,
    file_type TEXT,
    content TEXT NOT NULL,
    word_count INT NOT NULL DEFAULT 0,
    size_bytes INT NOT NULL DEFAULT 0,
    source_attribution JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'redacted', 'archived'))
);

CREATE INDEX IF NOT EXISTS idx_source_documents_status_updated
    ON source_documents (status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_source_documents_path
    ON source_documents (path) WHERE path IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_source_documents_source_type
    ON source_documents (source_type);
CREATE INDEX IF NOT EXISTS idx_source_documents_content_fts
    ON source_documents USING GIN (to_tsvector('english', title || ' ' || COALESCE(path, '') || ' ' || content))
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_source_documents_source_attribution
    ON source_documents USING GIN (source_attribution);

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.document_search_default_limit', '10'::jsonb,
     'Default row budget for source-document search'),
    ('memory.document_search_max_limit', '50'::jsonb,
     'Ceiling on source-document search rows; open_document retrieves exact content on demand')
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

-- Replay guard: 0118 changes this function's return type; a fresh replay
-- (baseline + migrations) already has the newer shape, so drop-first.
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
    content TEXT
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
            END AS rank,
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
        c.rank,
        c.snippet,
        c.content
    FROM candidates c
    ORDER BY c.rank DESC, c.updated_at DESC, c.id
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

    RETURN jsonb_build_object(
        'document_id', doc.id::text,
        'title', doc.title,
        'source_type', doc.source_type,
        'path', doc.path,
        'file_type', doc.file_type,
        'content_hash', doc.content_hash,
        'word_count', doc.word_count,
        'size_bytes', doc.size_bytes,
        'created_at', doc.created_at,
        'updated_at', doc.updated_at,
        'source_attribution', doc.source_attribution,
        'metadata', doc.metadata,
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

CREATE OR REPLACE FUNCTION get_memory_story(
    p_memory_id UUID,
    p_max_units INT DEFAULT 40
) RETURNS JSONB AS $$
DECLARE
    mem RECORD;
    units JSONB;
    gisted_members JSONB;
    documents JSONB;
BEGIN
    SELECT id, type, content, importance, trust_level, fidelity, status,
           created_at, superseded_by, source_attribution, metadata
    INTO mem
    FROM memories WHERE id = p_memory_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'role', u.role,
        'turn_at', u.turn_at,
        'content', u.content
    ) ORDER BY u.turn_at, u.created_at), '[]'::jsonb)
    INTO units
    FROM (
        SELECT s.id, msu.role, s.turn_at, s.created_at, s.content
        FROM memory_source_units msu
        JOIN subconscious_units s ON s.id = msu.subconscious_unit_id
        WHERE msu.memory_id = p_memory_id
          AND s.status = 'active'
        ORDER BY s.turn_at, s.created_at
        LIMIT GREATEST(COALESCE(p_max_units, 40), 1)
    ) u;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'memory_id', g.id,
        'content', g.content,
        'created_at', g.created_at
    ) ORDER BY g.created_at), '[]'::jsonb)
    INTO gisted_members
    FROM memories g
    WHERE g.superseded_by = p_memory_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'document_id', d.id,
        'title', d.title,
        'source_type', d.source_type,
        'path', d.path,
        'file_type', d.file_type,
        'content_hash', d.content_hash,
        'word_count', d.word_count,
        'size_bytes', d.size_bytes,
        'updated_at', d.updated_at
    ) ORDER BY d.updated_at DESC, d.id), '[]'::jsonb)
    INTO documents
    FROM source_documents d
    WHERE d.status = 'active'
      AND (
          d.content_hash = NULLIF(mem.source_attribution->>'content_hash', '')
          OR d.content_hash = NULLIF(mem.source_attribution->>'ref', '')
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(CASE
                  WHEN jsonb_typeof(mem.metadata->'source_references') = 'array'
                  THEN mem.metadata->'source_references'
                  ELSE '[]'::jsonb
              END) src
              WHERE d.content_hash = NULLIF(src->>'content_hash', '')
                 OR d.content_hash = NULLIF(src->>'ref', '')
          )
      );

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'memory', jsonb_build_object(
            'id', mem.id,
            'type', mem.type,
            'content', mem.content,
            'importance', mem.importance,
            'confidence', NULLIF(mem.metadata->>'confidence', '')::float,
            'trust_level', mem.trust_level,
            'fidelity', mem.fidelity,
            'status', mem.status,
            'created_at', mem.created_at,
            'occurred_from', mem.metadata#>>'{recmem,occurred_from}',
            'occurred_to', mem.metadata#>>'{recmem,occurred_to}',
            'session_id', mem.metadata#>>'{recmem,session_id}'
        ),
        'full_content', NULLIF(mem.metadata#>>'{consolidation,full_content}', ''),
        'source_units', units,
        'source_documents', CASE WHEN documents = '[]'::jsonb THEN NULL ELSE documents END,
        'superseded_members', CASE WHEN gisted_members = '[]'::jsonb THEN NULL ELSE gisted_members END,
        'superseded_by', mem.superseded_by,
        'evidence', jsonb_build_object(
            'revisions', (SELECT count(*) FROM belief_revision_audit b WHERE b.memory_id = p_memory_id),
            'supports', (SELECT count(*) FROM memory_edges e
                         WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'SUPPORTS'),
            'contradicts', (SELECT count(*) FROM memory_edges e
                            WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'CONTRADICTS')
        )
    ));
END;
$$ LANGUAGE plpgsql STABLE;
