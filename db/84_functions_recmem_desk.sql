-- RecMem desk semantics: list, open (scroll), pin, clear, and chunk-grain
-- loading. The desk is the set of active subconscious_units rows tagged
-- metadata.recmem.kind = 'source_document_desk' — mid-term working material
-- that is searchable (search_history sources=['desk']), GC'd when idle,
-- pin-protected while actively needed, and always cheap to reload from the
-- filing cabinet. Clearing archives; it never deletes, and the source
-- documents always survive.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.recmem_desk_list_default_limit', '20'::jsonb,
     'Default rows for list_recmem_desk'),
    ('memory.recmem_desk_open_default_chars', '4000'::jsonb,
     'Default window size when opening a desk item')
ON CONFLICT (key) DO NOTHING;

-- Load selected durable chunks onto the desk (one desk unit per chunk).
-- Idempotent per chunk; re-loading bumps access and refreshes state.
CREATE OR REPLACE FUNCTION load_source_chunks_to_recmem(
    p_chunk_ids UUID[] DEFAULT NULL,
    p_document_id UUID DEFAULT NULL,
    p_chunk_start INT DEFAULT NULL,
    p_chunk_end INT DEFAULT NULL,
    p_page_start INT DEFAULT NULL,
    p_page_end INT DEFAULT NULL,
    p_limit INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_loaded_by TEXT DEFAULT NULL,
    p_workspace TEXT DEFAULT NULL,
    p_pin BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    payload JSONB;
BEGIN
    IF COALESCE(array_length(p_chunk_ids, 1), 0) = 0 AND p_document_id IS NULL THEN
        RETURN jsonb_build_object('error', 'missing_selector');
    END IF;

    WITH matched AS (
        SELECT c.*, d.title AS doc_title, d.path AS doc_path,
               d.content_hash AS doc_content_hash,
               d.source_attribution AS doc_attribution
        FROM source_document_chunks c
        JOIN source_documents d ON d.id = c.source_document_id
        LEFT JOIN unnest(COALESCE(p_chunk_ids, ARRAY[]::UUID[])) AS ids(chunk_id)
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
              )
          )
        ORDER BY c.source_document_id, c.chunk_index
        LIMIT lim
    ),
    upserted AS (
        INSERT INTO subconscious_units (
            source_identity,
            session_id,
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
            last_accessed,
            pinned_at,
            pinned_by
        )
        SELECT
            'source_chunk:' || m.id::text,
            p_session_id,
            concat_ws(E'\n',
                '[Source Document: ' || m.doc_title || ']',
                CASE WHEN m.doc_path IS NOT NULL THEN '[Path: ' || m.doc_path || ']' END,
                '[Document ID: ' || m.source_document_id::text || ']',
                '[Chunk ' || m.chunk_index::text || ' (' || m.locator_kind || ')'
                    || CASE WHEN m.page_start IS NOT NULL
                            THEN ', pages ' || m.page_start::text || '-' || COALESCE(m.page_end, m.page_start)::text
                            ELSE '' END
                    || CASE WHEN m.sheet_name IS NOT NULL
                            THEN ', sheet ' || m.sheet_name
                            ELSE '' END
                    || ']',
                '',
                m.content
            ),
            NULL,
            NULL,
            'pending',
            'raw_only',
            'skipped',
            0.2,
            jsonb_strip_nulls(jsonb_build_object(
                'kind', 'source_document_desk',
                'ref', m.doc_content_hash,
                'label', m.doc_title,
                'content_hash', m.doc_content_hash,
                'path', m.doc_path,
                'source_document_id', m.source_document_id::text,
                'document_id', m.source_document_id::text,
                'chunk_id', m.id::text,
                'sensitivity', CASE WHEN m.doc_attribution->>'sensitivity' = 'private' THEN 'private' END
            )),
            jsonb_build_object(
                'recmem', jsonb_strip_nulls(jsonb_build_object(
                    'kind', 'source_document_desk',
                    'loaded_at', CURRENT_TIMESTAMP,
                    'reason', NULLIF(trim(COALESCE(p_reason, '')), ''),
                    'loaded_by', NULLIF(trim(COALESCE(p_loaded_by, '')), ''),
                    'workspace', NULLIF(trim(COALESCE(p_workspace, '')), ''),
                    'document_id', m.source_document_id::text,
                    'title', m.doc_title,
                    'path', m.doc_path,
                    'content_hash', m.doc_content_hash,
                    'chunk_id', m.id::text,
                    'chunk_index', m.chunk_index,
                    'locator', m.locator,
                    'locator_kind', m.locator_kind,
                    'offset', m.char_start,
                    'end_offset', m.char_end,
                    'routing_skipped', true,
                    'extraction_skipped', true
                ))
            ),
            'source_chunk_desk:' || m.id::text,
            1,
            CURRENT_TIMESTAMP,
            CASE WHEN COALESCE(p_pin, FALSE) THEN CURRENT_TIMESTAMP END,
            CASE WHEN COALESCE(p_pin, FALSE) THEN NULLIF(trim(COALESCE(p_loaded_by, '')), '') END
        FROM matched m
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
            session_id = COALESCE(EXCLUDED.session_id, subconscious_units.session_id),
            -- Re-loading may pin, but never silently unpins.
            pinned_at = COALESCE(subconscious_units.pinned_at, EXCLUDED.pinned_at),
            pinned_by = COALESCE(subconscious_units.pinned_by, EXCLUDED.pinned_by),
            metadata = subconscious_units.metadata
                || jsonb_build_object(
                    'recmem',
                    COALESCE(subconscious_units.metadata->'recmem', '{}'::jsonb)
                    || COALESCE(EXCLUDED.metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object('last_loaded_at', CURRENT_TIMESTAMP)
                ),
            updated_at = CURRENT_TIMESTAMP
        RETURNING id, source_attribution, metadata, pinned_at
    )
    SELECT jsonb_build_object(
        'loaded_units', COALESCE(jsonb_agg(jsonb_build_object(
            'unit_id', u.id::text,
            'document_id', u.source_attribution->>'document_id',
            'chunk_id', u.source_attribution->>'chunk_id',
            'chunk_index', NULLIF(u.metadata#>>'{recmem,chunk_index}', '')::INT,
            'title', u.source_attribution->>'label',
            'locator', u.metadata#>'{recmem,locator}',
            'pinned', u.pinned_at IS NOT NULL
        ) ORDER BY NULLIF(u.metadata#>>'{recmem,chunk_index}', '')::INT), '[]'::jsonb),
        'desk_unit_ids', COALESCE(jsonb_agg(u.id::text
            ORDER BY NULLIF(u.metadata#>>'{recmem,chunk_index}', '')::INT), '[]'::jsonb),
        'count', COUNT(u.id),
        'limit', lim
    )
    INTO payload
    FROM upserted u;

    RETURN COALESCE(payload, jsonb_build_object(
        'loaded_units', '[]'::jsonb,
        'desk_unit_ids', '[]'::jsonb,
        'count', 0,
        'limit', lim
    ));
END;
$$;

-- What is on the desk right now: handles + provenance + pin state.
CREATE OR REPLACE FUNCTION list_recmem_desk(
    p_limit INT DEFAULT NULL,
    p_offset INT DEFAULT 0,
    p_document_id UUID DEFAULT NULL,
    p_pinned_only BOOLEAN DEFAULT FALSE,
    p_session_id UUID DEFAULT NULL,
    p_workspace TEXT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    desk_unit_id UUID,
    document_id TEXT,
    chunk_id TEXT,
    chunk_index INT,
    title TEXT,
    path TEXT,
    locator JSONB,
    reason TEXT,
    loaded_by TEXT,
    workspace TEXT,
    session_id UUID,
    pinned BOOLEAN,
    pinned_at TIMESTAMPTZ,
    loaded_at TIMESTAMPTZ,
    access_count INT,
    last_accessed TIMESTAMPTZ,
    char_count INT,
    snippet TEXT,
    total_count BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    lim INT := LEAST(GREATEST(COALESCE(
        p_limit, get_config_int('memory.recmem_desk_list_default_limit'), 20), 1), 200);
    offs INT := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.metadata #>> '{recmem,document_id}',
        u.metadata #>> '{recmem,chunk_id}',
        NULLIF(u.metadata #>> '{recmem,chunk_index}', '')::INT,
        COALESCE(u.metadata #>> '{recmem,title}', u.source_attribution->>'label'),
        u.metadata #>> '{recmem,path}',
        COALESCE(u.metadata #> '{recmem,locator}', jsonb_strip_nulls(jsonb_build_object(
            'kind', 'char',
            'char_start', NULLIF(u.metadata #>> '{recmem,offset}', '')::INT,
            'char_end', NULLIF(u.metadata #>> '{recmem,end_offset}', '')::INT
        ))),
        u.metadata #>> '{recmem,reason}',
        u.metadata #>> '{recmem,loaded_by}',
        u.metadata #>> '{recmem,workspace}',
        u.session_id,
        u.pinned_at IS NOT NULL,
        u.pinned_at,
        COALESCE((u.metadata #>> '{recmem,loaded_at}')::timestamptz, u.created_at),
        u.access_count,
        u.last_accessed,
        length(u.content),
        left(u.content, 300),
        COUNT(*) OVER ()
    FROM subconscious_units u
    WHERE u.status = 'active'
      AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
      AND (NOT COALESCE(p_exclude_sensitive, FALSE)
           OR COALESCE(u.source_attribution->>'sensitivity', '') <> 'private')
      AND (p_document_id IS NULL
           OR u.metadata #>> '{recmem,document_id}' = p_document_id::text)
      AND (NOT COALESCE(p_pinned_only, FALSE) OR u.pinned_at IS NOT NULL)
      AND (p_session_id IS NULL OR u.session_id = p_session_id)
      AND (NULLIF(trim(COALESCE(p_workspace, '')), '') IS NULL
           OR u.metadata #>> '{recmem,workspace}' = p_workspace)
    ORDER BY u.pinned_at IS NOT NULL DESC,
             COALESCE(u.last_accessed, u.created_at) DESC,
             u.id
    OFFSET offs
    LIMIT lim;
END;
$$;

-- Open one desk item with offset windowing (the scroll surface) and touch
-- it. prev/next ids walk the same document's desk items in chunk order.
CREATE OR REPLACE FUNCTION open_recmem_desk_item(
    p_unit_id UUID,
    p_offset INT DEFAULT 0,
    p_max_chars INT DEFAULT NULL,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    unit subconscious_units%ROWTYPE;
    start_offset INT := GREATEST(COALESCE(p_offset, 0), 0);
    max_chars INT := COALESCE(p_max_chars,
                              get_config_int('memory.recmem_desk_open_default_chars'), 4000);
    total_chars INT;
    body TEXT;
    truncated BOOLEAN;
    doc_ref TEXT;
    order_key INT;
    prev_id UUID;
    next_id UUID;
BEGIN
    SELECT * INTO unit
    FROM subconscious_units u
    WHERE u.id = p_unit_id
      AND u.status = 'active'
      AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
      AND (NOT COALESCE(p_exclude_sensitive, FALSE)
           OR COALESCE(u.source_attribution->>'sensitivity', '') <> 'private');
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'error', 'not_found',
            'hint', 'list_desk shows current desk items; the source may have been cleared or archived — reload it from the filing cabinet'
        );
    END IF;

    total_chars := length(unit.content);
    IF max_chars IS NULL OR max_chars <= 0 THEN
        body := substring(unit.content FROM start_offset + 1);
    ELSE
        body := substring(unit.content FROM start_offset + 1 FOR max_chars);
    END IF;
    truncated := start_offset + length(body) < total_chars;

    UPDATE subconscious_units
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = unit.id;

    doc_ref := unit.metadata #>> '{recmem,document_id}';
    order_key := COALESCE(NULLIF(unit.metadata #>> '{recmem,chunk_index}', '')::INT,
                          NULLIF(unit.metadata #>> '{recmem,offset}', '')::INT, 0);

    IF doc_ref IS NOT NULL THEN
        SELECT u.id INTO prev_id
        FROM subconscious_units u
        WHERE u.status = 'active'
          AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
          AND u.metadata #>> '{recmem,document_id}' = doc_ref
          AND u.id <> unit.id
          AND COALESCE(NULLIF(u.metadata #>> '{recmem,chunk_index}', '')::INT,
                       NULLIF(u.metadata #>> '{recmem,offset}', '')::INT, 0) < order_key
        ORDER BY COALESCE(NULLIF(u.metadata #>> '{recmem,chunk_index}', '')::INT,
                          NULLIF(u.metadata #>> '{recmem,offset}', '')::INT, 0) DESC
        LIMIT 1;

        SELECT u.id INTO next_id
        FROM subconscious_units u
        WHERE u.status = 'active'
          AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
          AND u.metadata #>> '{recmem,document_id}' = doc_ref
          AND u.id <> unit.id
          AND COALESCE(NULLIF(u.metadata #>> '{recmem,chunk_index}', '')::INT,
                       NULLIF(u.metadata #>> '{recmem,offset}', '')::INT, 0) > order_key
        ORDER BY COALESCE(NULLIF(u.metadata #>> '{recmem,chunk_index}', '')::INT,
                          NULLIF(u.metadata #>> '{recmem,offset}', '')::INT, 0)
        LIMIT 1;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'desk_unit_id', unit.id::text,
        'document_id', doc_ref,
        'chunk_id', unit.metadata #>> '{recmem,chunk_id}',
        'chunk_index', NULLIF(unit.metadata #>> '{recmem,chunk_index}', '')::INT,
        'title', COALESCE(unit.metadata #>> '{recmem,title}', unit.source_attribution->>'label'),
        'path', unit.metadata #>> '{recmem,path}',
        'locator', unit.metadata #> '{recmem,locator}',
        'reason', unit.metadata #>> '{recmem,reason}',
        'pinned', unit.pinned_at IS NOT NULL,
        'offset', start_offset,
        'max_chars', max_chars,
        'total_chars', total_chars,
        'returned_chars', length(body),
        'truncated', truncated,
        'next_offset', CASE WHEN truncated THEN start_offset + length(body) ELSE NULL END,
        'prev_desk_unit_id', prev_id::text,
        'next_desk_unit_id', next_id::text,
        'content', body
    ));
END;
$$;

-- Pin/unpin a desk item. Pinned items survive idle GC (but never redaction).
CREATE OR REPLACE FUNCTION pin_recmem_desk_item(
    p_unit_id UUID,
    p_pinned BOOLEAN DEFAULT TRUE,
    p_pinned_by TEXT DEFAULT NULL,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    unit_pinned_at TIMESTAMPTZ;
BEGIN
    UPDATE subconscious_units u
    SET pinned_at = CASE WHEN COALESCE(p_pinned, TRUE) THEN CURRENT_TIMESTAMP END,
        pinned_by = CASE WHEN COALESCE(p_pinned, TRUE)
                         THEN NULLIF(trim(COALESCE(p_pinned_by, '')), '') END,
        metadata = COALESCE(u.metadata, '{}'::jsonb)
            || jsonb_build_object(
                'recmem',
                COALESCE(u.metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object(
                        'pin_events',
                        COALESCE(u.metadata #> '{recmem,pin_events}', '[]'::jsonb)
                            || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                'pinned', COALESCE(p_pinned, TRUE),
                                'at', CURRENT_TIMESTAMP,
                                'by', NULLIF(trim(COALESCE(p_pinned_by, '')), ''),
                                'note', NULLIF(trim(COALESCE(p_note, '')), '')
                            )))
                    )
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE u.id = p_unit_id
      AND u.status = 'active'
      AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
    RETURNING u.pinned_at INTO unit_pinned_at;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'error', 'not_found',
            'hint', 'list_desk shows current desk items; only active desk material can be pinned'
        );
    END IF;

    RETURN jsonb_build_object(
        'desk_unit_id', p_unit_id::text,
        'pinned', unit_pinned_at IS NOT NULL,
        'pinned_at', unit_pinned_at
    );
END;
$$;

-- Clear desk items: ARCHIVES matching active desk units (never deletes;
-- sources stay in the filing cabinet). Requires an explicit selector or
-- p_all = TRUE; pinned items are kept unless p_include_pinned.
CREATE OR REPLACE FUNCTION clear_recmem_desk(
    p_unit_ids UUID[] DEFAULT NULL,
    p_document_id UUID DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_workspace TEXT DEFAULT NULL,
    p_all BOOLEAN DEFAULT FALSE,
    p_include_pinned BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    cleared_count INT := 0;
    kept_pinned_count INT := 0;
BEGIN
    IF COALESCE(array_length(p_unit_ids, 1), 0) = 0
       AND p_document_id IS NULL
       AND p_session_id IS NULL
       AND NULLIF(trim(COALESCE(p_workspace, '')), '') IS NULL
       AND NOT COALESCE(p_all, FALSE) THEN
        RETURN jsonb_build_object(
            'error', 'missing_selector',
            'hint', 'pass desk unit ids, a document/session/workspace filter, or p_all => true'
        );
    END IF;

    WITH scoped AS (
        SELECT u.id, u.pinned_at
        FROM subconscious_units u
        WHERE u.status = 'active'
          AND u.metadata #>> '{recmem,kind}' = 'source_document_desk'
          AND (COALESCE(array_length(p_unit_ids, 1), 0) = 0 OR u.id = ANY(p_unit_ids))
          AND (p_document_id IS NULL
               OR u.metadata #>> '{recmem,document_id}' = p_document_id::text)
          AND (p_session_id IS NULL OR u.session_id = p_session_id)
          AND (NULLIF(trim(COALESCE(p_workspace, '')), '') IS NULL
               OR u.metadata #>> '{recmem,workspace}' = p_workspace)
        FOR UPDATE SKIP LOCKED
    ),
    cleared AS (
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
                                'reason', 'cleared'
                            )
                        )
                ),
            updated_at = CURRENT_TIMESTAMP
        FROM scoped s
        WHERE u.id = s.id
          AND (s.pinned_at IS NULL OR COALESCE(p_include_pinned, FALSE))
        RETURNING 1
    )
    SELECT
        (SELECT COUNT(*) FROM cleared),
        (SELECT COUNT(*) FROM scoped s
         WHERE s.pinned_at IS NOT NULL AND NOT COALESCE(p_include_pinned, FALSE))
    INTO cleared_count, kept_pinned_count;

    RETURN jsonb_build_object(
        'cleared', cleared_count,
        'kept_pinned', kept_pinned_count
    );
END;
$$;

-- Thin desk-facing wrapper over touch_subconscious_units.
CREATE OR REPLACE FUNCTION touch_recmem_desk_item(
    p_unit_ids UUID[]
) RETURNS INT
LANGUAGE sql
AS $$
    SELECT touch_subconscious_units(p_unit_ids);
$$;
