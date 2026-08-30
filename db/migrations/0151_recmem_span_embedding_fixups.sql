-- Fixups for 0150: qualify span-recall columns inside PL/pgSQL and make
-- parent embedding metadata create the nested recmem object reliably.

SET search_path = public, ag_catalog, "$user";

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
    metadata = COALESCE(metadata, '{}'::jsonb)
        || jsonb_build_object(
            'recmem',
            COALESCE(metadata->'recmem', '{}'::jsonb)
                || jsonb_build_object(
                    'embedding_retry_reset',
                    jsonb_build_object(
                        'at', CURRENT_TIMESTAMP,
                        'reason', 'span_level_recmem_embeddings_fixup'
                    )
                )
        ),
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'active'
  AND embedding_status = 'embedded'
  AND length(content) > 1800
  AND NOT EXISTS (
      SELECT 1
      FROM subconscious_unit_embedding_chunks c
      WHERE c.unit_id = subconscious_units.id
  );
