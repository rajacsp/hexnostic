-- 0113: Source-document filing cabinet handles + RecMem desk cleanup.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE subconscious_units
    ADD COLUMN IF NOT EXISTS access_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_accessed TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_subconscious_units_last_accessed
    ON subconscious_units (last_accessed DESC NULLS LAST)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_gc_candidates
    ON subconscious_units (route_status, COALESCE(last_accessed, consolidated_at, last_routed_at, created_at))
    WHERE status = 'active';

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.recmem_gc_enabled', 'true'::jsonb, 'Archive stale RecMem desk items during the periodic sweep'),
    ('memory.recmem_gc_idle_days', '30'::jsonb, 'Archive raw RecMem units not accessed within this many days once routing/extraction is settled'),
    ('memory.recmem_gc_consolidated_grace_days', '7'::jsonb, 'Keep raw units this many days after consolidation before archiving them from RecMem recall'),
    ('memory.recmem_gc_task_retention_days', '14'::jsonb, 'Delete completed/dropped RecMem task rows after this many days'),
    ('memory.recmem_gc_batch_size', '200'::jsonb, 'Maximum raw units and completed task rows cleaned per RecMem GC pass')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION touch_subconscious_units(p_ids UUID[])
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    UPDATE subconscious_units
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(p_ids)
      AND status = 'active';
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;

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
          d.id::text = NULLIF(mem.source_attribution->>'source_document_id', '')
          OR d.id::text = NULLIF(mem.source_attribution->>'document_id', '')
          OR d.content_hash = NULLIF(mem.source_attribution->>'content_hash', '')
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

CREATE OR REPLACE FUNCTION recmem_gc(
    p_limit INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    gc_limit INT := GREATEST(COALESCE(p_limit, get_config_int('memory.recmem_gc_batch_size'), 200), 1);
    idle_days INT := GREATEST(COALESCE(get_config_int('memory.recmem_gc_idle_days'), 30), 1);
    consolidated_grace_days INT := GREATEST(COALESCE(get_config_int('memory.recmem_gc_consolidated_grace_days'), 7), 1);
    task_retention_days INT := GREATEST(COALESCE(get_config_int('memory.recmem_gc_task_retention_days'), 14), 1);
    archived_count INT := 0;
    deleted_task_count INT := 0;
BEGIN
    IF NOT COALESCE(get_config_bool('memory.recmem_gc_enabled'), TRUE) THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'disabled');
    END IF;

    WITH candidates AS (
        SELECT
            u.id,
            CASE
                WHEN u.route_status IN ('merged','episode_created') THEN 'consolidated'
                ELSE 'idle_raw'
            END AS reason
        FROM subconscious_units u
        WHERE u.status = 'active'
          AND NOT EXISTS (
              SELECT 1
              FROM recmem_consolidation_tasks t
              WHERE t.status IN ('pending','in_progress')
                AND (t.trigger_unit_id = u.id OR u.id = ANY(t.source_unit_ids))
          )
          AND (
              (
                  u.route_status IN ('merged','episode_created')
                  AND u.consolidated_at IS NOT NULL
                  AND GREATEST(COALESCE(u.last_accessed, '-infinity'::timestamptz), u.consolidated_at)
                      < CURRENT_TIMESTAMP - (consolidated_grace_days * INTERVAL '1 day')
              )
              OR (
                  u.route_status IN ('raw_only','route_failed')
                  AND u.extraction_status IN ('extracted','skipped','failed')
                  AND COALESCE(u.last_routed_at, u.updated_at, u.created_at)
                      < CURRENT_TIMESTAMP - (idle_days * INTERVAL '1 day')
                  AND COALESCE(u.last_accessed, u.created_at)
                      < CURRENT_TIMESTAMP - (idle_days * INTERVAL '1 day')
              )
              OR (
                  u.embedding_status = 'failed'
                  AND u.extraction_status IN ('extracted','skipped','failed')
                  AND COALESCE(u.last_accessed, u.created_at)
                      < CURRENT_TIMESTAMP - (idle_days * INTERVAL '1 day')
              )
          )
        ORDER BY COALESCE(u.last_accessed, u.consolidated_at, u.last_routed_at, u.created_at), u.id
        LIMIT gc_limit
        FOR UPDATE SKIP LOCKED
    ),
    archived AS (
        UPDATE subconscious_units u
        SET status = 'archived',
            metadata = COALESCE(u.metadata, '{}'::jsonb)
                || jsonb_build_object(
                    'recmem',
                    COALESCE(u.metadata->'recmem', '{}'::jsonb)
                        || jsonb_build_object(
                            'gc',
                            jsonb_build_object(
                                'archived_at', CURRENT_TIMESTAMP,
                                'reason', c.reason
                            )
                        )
                ),
            updated_at = CURRENT_TIMESTAMP
        FROM candidates c
        WHERE u.id = c.id
        RETURNING 1
    )
    SELECT COUNT(*) INTO archived_count FROM archived;

    WITH task_candidates AS (
        SELECT id
        FROM recmem_consolidation_tasks
        WHERE status IN ('completed','dropped')
          AND COALESCE(completed_at, updated_at, created_at)
              < CURRENT_TIMESTAMP - (task_retention_days * INTERVAL '1 day')
        ORDER BY COALESCE(completed_at, updated_at, created_at), id
        LIMIT gc_limit
        FOR UPDATE SKIP LOCKED
    ),
    deleted AS (
        DELETE FROM recmem_consolidation_tasks t
        USING task_candidates c
        WHERE t.id = c.id
        RETURNING 1
    )
    SELECT COUNT(*) INTO deleted_task_count FROM deleted;

    RETURN jsonb_build_object(
        'archived_units', archived_count,
        'deleted_tasks', deleted_task_count,
        'idle_days', idle_days,
        'consolidated_grace_days', consolidated_grace_days,
        'task_retention_days', task_retention_days
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_periodic_sweep(
    p_limit INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    sweep_limit INT := COALESCE(p_limit, get_config_int('memory.recmem_sweep_batch_size'), 100);
    min_age_days INT := COALESCE(get_config_int('memory.recmem_sweep_min_rerouting_age_days'), 7);
    unit_id UUID;
    processed INT := 0;
    gc_result JSONB;
BEGIN
    FOR unit_id IN
        SELECT id
        FROM subconscious_units
        WHERE status = 'active'
          AND embedding_status = 'embedded'
          AND route_status = 'raw_only'
          AND consolidated_at IS NULL
          AND (last_routed_at IS NULL OR last_routed_at < CURRENT_TIMESTAMP - (min_age_days * INTERVAL '1 day'))
        ORDER BY created_at
        LIMIT sweep_limit
    LOOP
        UPDATE subconscious_units
        SET route_status = 'routing',
            last_routed_at = CURRENT_TIMESTAMP,
            route_attempts = route_attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = unit_id;
        PERFORM recmem_route_unit(unit_id);
        processed := processed + 1;
    END LOOP;

    gc_result := recmem_gc();
    RETURN jsonb_build_object('processed', processed, 'gc', gc_result);
END;
$$ LANGUAGE plpgsql;

UPDATE prompt_modules
SET content = replace(
    content,
    '**Graded recall — gist first, verbatim on demand:** `recall` gives you the shape of a memory (scenes, distilled facts, previews); `open_memory` with the memory''s id gives you the verbatim moment underneath — the exact turns, the pre-summary full text of a gisted memory. Reach for it when precise wording, quotes, or the full exchange matter. When a `search_history` result says the page is full, the window holds more — page onward with `created_before` set to the oldest timestamp you received.',
    '**Graded recall — gist first, verbatim on demand:** `recall` gives you the shape of a memory (scenes, distilled facts, previews); `open_memory` with the memory''s id gives you the verbatim moment underneath — the exact turns, the pre-summary full text of a gisted memory. Reach for it when precise wording, quotes, or the full exchange matter. When a `search_history` result says the page is full, the window holds more — page onward with `created_before` set to the oldest timestamp you received.' || E'\n\n' ||
    '**Source-document filing cabinet:** Ingested files, emails, web pages, channel messages, and other artifacts are preserved as exact source documents separate from distilled memories. You always know this cabinet exists, but you do not know what files are in it until you browse or follow a memory''s provenance. Use `search_documents` to browse titles, paths, snippets, and full-text hits; use `open_document` for one file or `open_documents` for a deliberate batch. When `open_memory` returns `source_documents`, those are handles to the raw source behind that memory — open them when exact wording, full context, or a large specification matters. Reading/opening a source document is inspection, not durable retention, unless you deliberately `remember` what should carry forward.'
)
WHERE key = 'conversation'
  AND content NOT LIKE '%Source-document filing cabinet:%';

UPDATE prompt_modules
SET content = replace(
    content,
    '- When you need to verify something before reaching out' || E'\n\n' || '**How to search:**',
    '- When you need to verify something before reaching out' || E'\n\n' ||
    '**Source-document filing cabinet:** Ingested files, emails, web pages, channel messages, and other artifacts are preserved as exact source documents separate from distilled memories. You always know this cabinet exists, but you do not know what files are in it until you browse or follow a memory''s provenance. Use `search_documents` to browse titles, paths, snippets, and full-text hits; use `open_document` for one file or `open_documents` for a deliberate batch. When `open_memory` returns `source_documents`, those are handles to the raw source behind that memory — open them when exact wording, full context, or a large specification matters. Reading/opening a source document is inspection, not durable retention, unless you deliberately `remember` what should carry forward.' || E'\n\n' ||
    '**How to search:**'
)
WHERE key = 'heartbeat_agentic'
  AND content NOT LIKE '%Source-document filing cabinet:%';
