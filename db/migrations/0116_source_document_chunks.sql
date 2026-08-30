-- 0116: Durable source-document chunks with locators + deferred embedding.
-- Chunks are stable citable slices of the filing cabinet: keyed by
-- (document, chunk_index), ids/embeddings survive re-ingestion of unchanged
-- content, and memory provenance now carries chunk_id/chunk_index handles.
SET search_path = public, ag_catalog, "$user";

-- Durable source-document chunks: stable, citable slices of a source
-- document with locators (page/section/sheet row/slide/message) and their
-- own embeddings for hybrid retrieval. Keyed by (document, chunk_index);
-- ids and embeddings survive re-ingestion when content is unchanged.
-- Privacy/status stay single-source on source_documents — every read joins.
CREATE TABLE IF NOT EXISTS source_document_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_document_id UUID NOT NULL REFERENCES source_documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    locator_kind TEXT NOT NULL DEFAULT 'char'
        CHECK (locator_kind IN ('char', 'page', 'section', 'sheet_row', 'slide', 'message')),
    locator JSONB NOT NULL DEFAULT '{}'::jsonb,
    heading_path TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    token_count INT,
    char_start INT NOT NULL DEFAULT 0,
    char_end INT NOT NULL DEFAULT 0,
    page_start INT,
    page_end INT,
    sheet_name TEXT,
    row_start INT,
    row_end INT,
    column_start INT,
    column_end INT,
    embedding vector(768),
    embedded_at TIMESTAMPTZ,
    embedding_model TEXT,
    embedding_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (embedding_status IN ('pending', 'in_progress', 'embedded', 'failed', 'skipped')),
    embedding_claimed_at TIMESTAMPTZ,
    embedding_attempts INT NOT NULL DEFAULT 0,
    chunker_version TEXT NOT NULL DEFAULT 'v2',
    access_count INT NOT NULL DEFAULT 0,
    last_accessed TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (source_document_id, chunk_index)
);

-- Keep the chunk embedding column in step with the configured dimension
-- (mirrors the db/00 DO block; this file runs after embedding_dimension()
-- and sync_embedding_dimension_config() exist).
DO $$
DECLARE
    dim INT;
BEGIN
    dim := embedding_dimension();
    IF dim IS NOT NULL AND dim <> 768 THEN
        EXECUTE format(
            'ALTER TABLE source_document_chunks ALTER COLUMN embedding TYPE vector(%s) USING embedding::vector(%s)',
            dim,
            dim
        );
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_source_chunks_document
    ON source_document_chunks (source_document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_source_chunks_fts
    ON source_document_chunks USING GIN (to_tsvector('english', content));
CREATE INDEX IF NOT EXISTS idx_source_chunks_embedding
    ON source_document_chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_source_chunks_hash
    ON source_document_chunks (content_hash);
CREATE INDEX IF NOT EXISTS idx_source_chunks_embed_queue
    ON source_document_chunks (embedding_status, created_at)
    WHERE embedding_status IN ('pending', 'in_progress');

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.source_chunk_embed_batch_size', '32'::jsonb,
     'Chunks claimed per source-chunk embedding pass'),
    ('memory.source_chunk_embed_claim_timeout_s', '120'::jsonb,
     'Seconds before an in-progress source-chunk embedding claim is considered stale and reclaimable'),
    ('memory.source_chunk_embed_max_attempts', '3'::jsonb,
     'Embedding attempts before a source chunk is marked failed (search degrades to lexical for it)')
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


-- Chunk-grain provenance survives normalization (extends 0114).
CREATE OR REPLACE FUNCTION normalize_source_reference(p_source JSONB)
RETURNS JSONB AS $$
DECLARE
    kind TEXT;
    ref TEXT;
    label TEXT;
    author TEXT;
    observed_at TIMESTAMPTZ;
    trust FLOAT;
    content_hash TEXT;
    source_document_id TEXT;
    document_id TEXT;
    chunk_id TEXT;
    chunk_index INT;
    sensitivity TEXT;
BEGIN
    IF p_source IS NULL OR jsonb_typeof(p_source) <> 'object' THEN
        RETURN '{}'::jsonb;
    END IF;

    kind := NULLIF(p_source->>'kind', '');
    ref := COALESCE(NULLIF(p_source->>'ref', ''), NULLIF(p_source->>'uri', ''));
    label := NULLIF(p_source->>'label', '');
    author := NULLIF(p_source->>'author', '');
    content_hash := NULLIF(p_source->>'content_hash', '');
    source_document_id := COALESCE(NULLIF(p_source->>'source_document_id', ''), NULLIF(p_source->>'document_id', ''));
    document_id := COALESCE(NULLIF(p_source->>'document_id', ''), source_document_id);
    -- Chunk-grain provenance survives normalization: memories extracted from
    -- a source chunk keep the handle needed to cite the exact passage.
    chunk_id := NULLIF(p_source->>'chunk_id', '');
    BEGIN
        chunk_index := NULLIF(p_source->>'chunk_index', '')::int;
    EXCEPTION WHEN OTHERS THEN
        chunk_index := NULL;
    END;
    -- Sensitivity survives normalization (#92): 'private' is the one defined
    -- level; it keeps the memory out of group recall and default export.
    sensitivity := CASE WHEN p_source->>'sensitivity' = 'private' THEN 'private' END;

    BEGIN
        observed_at := (p_source->>'observed_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        observed_at := CURRENT_TIMESTAMP;
    END;
    IF observed_at IS NULL THEN
        observed_at := CURRENT_TIMESTAMP;
    END IF;

    trust := COALESCE(NULLIF(p_source->>'trust', '')::float, 0.5);
    trust := LEAST(1.0, GREATEST(0.0, trust));

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'kind', kind,
            'ref', ref,
            'label', label,
            'author', author,
            'observed_at', observed_at,
            'trust', trust,
            'content_hash', content_hash,
            'source_document_id', source_document_id,
            'document_id', document_id,
            'chunk_id', chunk_id,
            'chunk_index', chunk_index,
            'sensitivity', sensitivity
        )
    );
    END;
$$ LANGUAGE plpgsql STABLE;

-- open_memory now surfaces source-chunk handles alongside document handles.
CREATE OR REPLACE FUNCTION get_memory_story(
    p_memory_id UUID,
    p_max_units INT DEFAULT 40
) RETURNS JSONB AS $$
DECLARE
    mem RECORD;
    units JSONB;
    gisted_members JSONB;
    documents JSONB;
    chunks JSONB;
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

    -- A retention gist supersedes its members: opening the gist also opens
    -- the archived originals (still present through the grace window).
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
          d.id::text = NULLIF(mem.source_attribution->>'source_document_id', '')
          OR d.id::text = NULLIF(mem.source_attribution->>'document_id', '')
          OR
          d.content_hash = NULLIF(mem.source_attribution->>'content_hash', '')
          OR d.content_hash = NULLIF(mem.source_attribution->>'ref', '')
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(CASE
                  WHEN jsonb_typeof(mem.metadata->'source_references') = 'array'
                  THEN mem.metadata->'source_references'
                  ELSE '[]'::jsonb
              END) src
              WHERE d.id::text = NULLIF(src->>'source_document_id', '')
                 OR d.id::text = NULLIF(src->>'document_id', '')
                 OR d.content_hash = NULLIF(src->>'content_hash', '')
                 OR d.content_hash = NULLIF(src->>'ref', '')
          )
      );

    -- Chunk-grain provenance: the exact passage a memory was extracted from,
    -- with its locator (page/section/sheet row) for citation.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'chunk_id', c.id,
        'document_id', c.source_document_id,
        'chunk_index', c.chunk_index,
        'locator_kind', c.locator_kind,
        'locator', c.locator,
        'heading_path', to_jsonb(c.heading_path),
        'page_start', c.page_start,
        'page_end', c.page_end,
        'sheet_name', c.sheet_name
    ) ORDER BY c.chunk_index), '[]'::jsonb)
    INTO chunks
    FROM source_document_chunks c
    JOIN source_documents cd ON cd.id = c.source_document_id AND cd.status = 'active'
    WHERE c.id::text = NULLIF(mem.source_attribution->>'chunk_id', '')
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(CASE
               WHEN jsonb_typeof(mem.metadata->'source_references') = 'array'
               THEN mem.metadata->'source_references'
               ELSE '[]'::jsonb
           END) src
           WHERE c.id::text = NULLIF(src->>'chunk_id', '')
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
        'source_chunks', CASE WHEN chunks = '[]'::jsonb THEN NULL ELSE chunks END,
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
