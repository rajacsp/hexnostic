-- Keep newly written async-embedding memories recallable through lexical search
-- before the embedding worker has vectorized them.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION recall_hybrid(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_vector_weight FLOAT DEFAULT 0.6,
    p_fts_weight FLOAT DEFAULT 0.4
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB
) AS $$
DECLARE
    fts_query tsquery;
BEGIN
    BEGIN
        fts_query := websearch_to_tsquery('english', p_query_text);
    EXCEPTION WHEN OTHERS THEN
        fts_query := plainto_tsquery('english', p_query_text);
    END;

    RETURN QUERY
    WITH
    vector_hits AS (
        SELECT fr.memory_id, fr.content, fr.memory_type, fr.score AS vector_score, fr.source
        FROM fast_recall(p_query_text, p_limit * 2) fr
    ),
    fts_hits AS (
        SELECT
            m.id AS memory_id,
            m.content,
            m.type AS memory_type,
            ts_rank_cd(to_tsvector('english', m.content), fts_query)::float AS fts_score,
            'fts'::text AS source
        FROM memories m
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND to_tsvector('english', m.content) @@ fts_query
        ORDER BY fts_score DESC
        LIMIT p_limit * 2
    ),
    merged AS (
        SELECT
            COALESCE(v.memory_id, f.memory_id) AS mem_id,
            COALESCE(v.content, f.content) AS mem_content,
            COALESCE(v.memory_type, f.memory_type) AS mem_type,
            CASE
                WHEN v.memory_id IS NULL AND f.memory_id IS NOT NULL THEN
                    LEAST(1.0, GREATEST(0.35, COALESCE(f.fts_score, 0.0) + p_fts_weight))
                ELSE
                    COALESCE(v.vector_score, 0.0) * p_vector_weight
                    + COALESCE(f.fts_score, 0.0) * p_fts_weight
            END AS combined_score,
            CASE
                WHEN v.memory_id IS NOT NULL AND f.memory_id IS NOT NULL THEN 'hybrid'
                WHEN v.memory_id IS NOT NULL THEN v.source
                ELSE 'fts'
            END AS hit_source
        FROM vector_hits v
        FULL OUTER JOIN fts_hits f ON v.memory_id = f.memory_id
    )
    SELECT
        mg.mem_id,
        mg.mem_content,
        mg.mem_type,
        mg.combined_score,
        mg.hit_source,
        m.importance,
        m.trust_level,
        m.source_attribution
    FROM merged mg
    JOIN memories m ON m.id = mg.mem_id
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
    ORDER BY mg.combined_score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
