SET search_path = public, ag_catalog, "$user";

CREATE INDEX IF NOT EXISTS idx_subconscious_units_content_fts
    ON subconscious_units USING GIN (to_tsvector('english', content))
    WHERE status = 'active';

-- Free lexical recall across raw conversation turns and consolidated memory.
-- This deliberately avoids get_embedding(): it remains available when an
-- embedding provider is offline and is suitable for background review work.
CREATE OR REPLACE FUNCTION search_cross_session_history(
    p_query TEXT,
    p_limit INT DEFAULT 20,
    p_sources TEXT[] DEFAULT ARRAY['turn', 'memory']::TEXT[],
    p_created_after TIMESTAMPTZ DEFAULT NULL,
    p_created_before TIMESTAMPTZ DEFAULT NULL,
    p_exclude_session_id UUID DEFAULT NULL
) RETURNS TABLE (
    source_kind TEXT,
    item_id UUID,
    session_id UUID,
    content TEXT,
    user_text TEXT,
    assistant_text TEXT,
    memory_type TEXT,
    occurred_at TIMESTAMPTZ,
    rank FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    metadata JSONB
) AS $$
BEGIN
    IF NULLIF(trim(COALESCE(p_query, '')), '') IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH query_doc AS (
        SELECT websearch_to_tsquery('english', p_query) AS query
    ),
    turn_hits AS (
        SELECT
            'turn'::TEXT AS source_kind,
            s.id AS item_id,
            s.session_id,
            s.content,
            s.user_text,
            s.assistant_text,
            NULL::TEXT AS memory_type,
            s.turn_at AS occurred_at,
            ts_rank_cd(to_tsvector('english', s.content), q.query, 32)::FLOAT AS rank,
            ARRAY[s.id]::UUID[] AS source_unit_ids,
            s.source_attribution,
            s.metadata
        FROM subconscious_units s
        CROSS JOIN query_doc q
        WHERE 'turn' = ANY(COALESCE(p_sources, ARRAY['turn', 'memory']::TEXT[]))
          AND numnode(q.query) > 0
          AND s.status = 'active'
          AND (p_exclude_session_id IS NULL OR s.session_id IS DISTINCT FROM p_exclude_session_id)
          AND (p_created_after IS NULL OR s.turn_at >= p_created_after)
          AND (p_created_before IS NULL OR s.turn_at < p_created_before)
          AND to_tsvector('english', s.content) @@ q.query
        ORDER BY rank DESC, occurred_at DESC, item_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    ),
    memory_hits AS (
        SELECT
            'memory'::TEXT AS source_kind,
            m.id AS item_id,
            (
                SELECT su.session_id
                FROM memory_source_units msu
                JOIN subconscious_units su ON su.id = msu.subconscious_unit_id
                WHERE msu.memory_id = m.id AND su.session_id IS NOT NULL
                ORDER BY su.turn_at DESC, su.id
                LIMIT 1
            ) AS session_id,
            m.content,
            NULL::TEXT AS user_text,
            NULL::TEXT AS assistant_text,
            m.type::TEXT AS memory_type,
            m.created_at AS occurred_at,
            ts_rank_cd(to_tsvector('english', m.content), q.query, 32)::FLOAT AS rank,
            COALESCE(
                (
                    SELECT array_agg(msu.subconscious_unit_id ORDER BY msu.created_at, msu.subconscious_unit_id)
                    FROM memory_source_units msu
                    WHERE msu.memory_id = m.id
                ),
                '{}'::UUID[]
            ) AS source_unit_ids,
            m.source_attribution,
            m.metadata
        FROM memories m
        CROSS JOIN query_doc q
        WHERE 'memory' = ANY(COALESCE(p_sources, ARRAY['turn', 'memory']::TEXT[]))
          AND numnode(q.query) > 0
          AND m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND (p_created_after IS NULL OR m.created_at >= p_created_after)
          AND (p_created_before IS NULL OR m.created_at < p_created_before)
          AND to_tsvector('english', m.content) @@ q.query
        ORDER BY rank DESC, occurred_at DESC, item_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    )
    SELECT hits.*
    FROM (
        SELECT * FROM turn_hits
        UNION ALL
        SELECT * FROM memory_hits
    ) hits
    ORDER BY hits.rank DESC, hits.occurred_at DESC, hits.source_kind, hits.item_id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
END;
$$ LANGUAGE plpgsql STABLE;
