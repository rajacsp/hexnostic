-- 0117: Original source artifacts + extraction-run tracking.
-- Bytes (or a stable reference) are preserved BEFORE extraction, keyed by
-- sha256; extractor runs record structured warnings (OCR, truncation,
-- unsupported features) surfaced by open_source_document.
SET search_path = public, ag_catalog, "$user";

-- Original source artifacts: the exact bytes (or a stable reference) a
-- source document was extracted from, preserved BEFORE extraction so a
-- failed parse never loses the source and a better extractor can re-run
-- later. Bytes live in-DB up to ingest.artifact_max_db_bytes (rides
-- pg_dump backups); larger artifacts live in a content-addressed managed
-- directory with the hash recorded here.
CREATE TABLE IF NOT EXISTS source_artifacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_document_id UUID REFERENCES source_documents(id) ON DELETE SET NULL,
    storage_kind TEXT NOT NULL
        CHECK (storage_kind IN ('database', 'filesystem', 'connector', 'url', 'external')),
    storage_ref TEXT,
    bytes BYTEA,
    original_filename TEXT,
    mime_type TEXT,
    byte_size BIGINT NOT NULL DEFAULT 0,
    sha256 TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'redacted', 'archived')),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_source_artifacts_doc
    ON source_artifacts (source_document_id) WHERE source_document_id IS NOT NULL;

-- The artifact hash a document's normalized content was extracted from.
ALTER TABLE source_documents ADD COLUMN IF NOT EXISTS original_hash TEXT;

-- Extraction runs: which extractor produced a document's normalized text,
-- with structured warnings (OCR used, rows truncated, unsupported features)
-- and errors. Failed runs may carry an artifact but no document.
CREATE TABLE IF NOT EXISTS source_extraction_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_document_id UUID REFERENCES source_documents(id) ON DELETE CASCADE,
    artifact_id UUID REFERENCES source_artifacts(id) ON DELETE SET NULL,
    extractor_name TEXT NOT NULL,
    extractor_version TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL
        CHECK (status IN ('completed', 'completed_with_warnings', 'failed')),
    warnings JSONB NOT NULL DEFAULT '[]'::jsonb,
    errors JSONB NOT NULL DEFAULT '[]'::jsonb,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_source_extraction_runs_doc
    ON source_extraction_runs (source_document_id, created_at DESC)
    WHERE source_document_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_source_extraction_runs_artifact
    ON source_extraction_runs (artifact_id, created_at DESC)
    WHERE artifact_id IS NOT NULL;

INSERT INTO config_defaults (key, value, description) VALUES
    ('ingest.artifact_max_db_bytes', '26214400'::jsonb,
     'Original artifacts up to this many bytes are stored in-DB (rides pg_dump backups); larger ones live in the managed artifact directory'),
    ('ingest.xlsx_max_rows_per_sheet', '5000'::jsonb,
     'Rows extracted per spreadsheet sheet; capping always emits a truncated_rows extraction warning, never a silent cut')
ON CONFLICT (key) DO NOTHING;

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

-- open_source_document now surfaces the latest extraction run + warnings.
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
