-- Durable memories now use the same asynchronous embedding lifecycle as
-- RecMem/source chunks: creation is durable immediately, vectorization is
-- claimed and retried by maintenance.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE memories
    ALTER COLUMN embedding DROP NOT NULL;

ALTER TABLE memories
    ADD COLUMN IF NOT EXISTS embedded_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS embedding_model TEXT,
    ADD COLUMN IF NOT EXISTS embedding_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (embedding_status IN ('pending', 'in_progress', 'embedded', 'failed', 'skipped')),
    ADD COLUMN IF NOT EXISTS embedding_claimed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS embedding_attempts INT NOT NULL DEFAULT 0;

WITH z AS (
    SELECT array_fill(0.0::float, ARRAY[embedding_dimension()])::vector AS zero_vec
)
UPDATE memories
SET embedding_status = CASE
        WHEN embedding IS NOT NULL AND embedding <> z.zero_vec THEN 'embedded'
        ELSE COALESCE(embedding_status, 'pending')
    END,
    embedded_at = CASE
        WHEN embedding IS NOT NULL AND embedding <> z.zero_vec THEN COALESCE(embedded_at, CURRENT_TIMESTAMP)
        ELSE NULL
    END,
    embedding_model = CASE
        WHEN embedding IS NOT NULL AND embedding <> z.zero_vec THEN COALESCE(embedding_model, get_config_text('embedding.model_id'))
        ELSE NULL
    END,
    embedding_attempts = CASE
        WHEN embedding IS NOT NULL AND embedding <> z.zero_vec THEN GREATEST(COALESCE(embedding_attempts, 0), 1)
        ELSE COALESCE(embedding_attempts, 0)
    END,
    embedding_claimed_at = CASE
        WHEN embedding IS NOT NULL AND embedding <> z.zero_vec THEN NULL
        ELSE embedding_claimed_at
    END
FROM z
WHERE embedding_status IS NULL
   OR embedding IS NOT NULL
   OR embedding_attempts IS NULL;

DROP INDEX IF EXISTS idx_memories_embedding;
CREATE INDEX idx_memories_embedding ON memories USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL AND embedding_status = 'embedded';
CREATE INDEX IF NOT EXISTS idx_memories_embedding_queue
    ON memories (embedding_status, created_at)
    WHERE embedding_status IN ('pending', 'in_progress');

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.memory_embed_batch_size', '32'::jsonb,
     'Durable memories claimed per embedding maintenance pass'),
    ('memory.memory_embed_claim_timeout_s', '120'::jsonb,
     'Seconds before an in-progress durable-memory embedding claim is considered stale and reclaimable'),
    ('memory.memory_embed_max_attempts', '3'::jsonb,
     'Embedding attempts before a durable memory is marked failed')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION normalize_memory_embedding_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    zero_vec vector;
BEGIN
    IF NEW.embedding IS NOT NULL THEN
        zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    END IF;

    IF NEW.embedding IS NOT NULL AND NEW.embedding <> zero_vec THEN
        IF NEW.embedding_status IS NULL OR NEW.embedding_status IN ('pending', 'in_progress') THEN
            NEW.embedding_status := 'embedded';
        END IF;
        IF NEW.embedding_status = 'embedded' THEN
            NEW.embedded_at := COALESCE(NEW.embedded_at, CURRENT_TIMESTAMP);
            NEW.embedding_model := COALESCE(NEW.embedding_model, get_config_text('embedding.model_id'));
            NEW.embedding_claimed_at := NULL;
            NEW.embedding_attempts := GREATEST(COALESCE(NEW.embedding_attempts, 0), 1);
        END IF;
    ELSE
        IF NEW.embedding_status IS NULL OR NEW.embedding_status = 'embedded' THEN
            NEW.embedding_status := 'pending';
        END IF;
        IF NEW.embedding_status IN ('pending', 'failed', 'skipped') THEN
            NEW.embedded_at := NULL;
            NEW.embedding_model := NULL;
            NEW.embedding_claimed_at := NULL;
        END IF;
        NEW.embedding_attempts := GREATEST(COALESCE(NEW.embedding_attempts, 0), 0);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_memory_embedding_lifecycle ON memories;
CREATE TRIGGER trg_memory_embedding_lifecycle
    BEFORE INSERT OR UPDATE OF embedding, embedding_status ON memories
    FOR EACH ROW
    EXECUTE FUNCTION normalize_memory_embedding_lifecycle();

DROP TRIGGER IF EXISTS trg_neighborhood_staleness ON memories;
CREATE TRIGGER trg_neighborhood_staleness
    AFTER UPDATE OF embedding, importance, status ON memories
    FOR EACH ROW
    EXECUTE FUNCTION mark_neighborhoods_stale();

DROP TRIGGER IF EXISTS trg_auto_worldview_alignment_embedding ON memories;
CREATE TRIGGER trg_auto_worldview_alignment_embedding
    AFTER UPDATE OF embedding ON memories
    FOR EACH ROW
    WHEN (NEW.embedding IS NOT NULL)
    EXECUTE FUNCTION auto_check_worldview_alignment();

CREATE OR REPLACE FUNCTION claim_memories_unembedded_batch(
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    batch_size INT := COALESCE(p_limit, get_config_int('memory.memory_embed_batch_size'), 32);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.memory_embed_claim_timeout_s'), 120);
    max_attempts INT := COALESCE(get_config_int('memory.memory_embed_max_attempts'), 3);
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT m.id
        FROM memories m
        WHERE m.status = 'active'
          AND NULLIF(trim(m.content), '') IS NOT NULL
          AND COALESCE(m.embedding_attempts, 0) < GREATEST(max_attempts, 1)
          AND (
              m.embedding_status = 'pending'
              OR (
                  m.embedding_status = 'in_progress'
                  AND COALESCE(m.embedding_claimed_at, '-infinity'::timestamptz)
                      < CURRENT_TIMESTAMP - (GREATEST(timeout_s, 1) * INTERVAL '1 second')
              )
          )
        ORDER BY m.created_at, m.id
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(batch_size, 32), 1)
    ),
    claimed AS (
        UPDATE memories m
        SET embedding_status = 'in_progress',
            embedding_claimed_at = CURRENT_TIMESTAMP,
            embedding_attempts = COALESCE(m.embedding_attempts, 0) + 1,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE m.id = c.id
        RETURNING m.id, m.content, m.type, m.embedding_attempts
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'memory_id', id,
        'content', content,
        'type', type,
        'attempts', embedding_attempts
    ) ORDER BY id), '[]'::jsonb)
    INTO payload
    FROM claimed;

    RETURN payload;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_memory_embedding(
    p_memory_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.memory_embed_max_attempts'), 3);
    final_status TEXT;
BEGIN
    UPDATE memories
    SET embedding_status = CASE
            WHEN COALESCE(embedding_attempts, 0) >= GREATEST(max_attempts, 1) THEN 'failed'
            ELSE 'pending'
        END,
        embedding_claimed_at = NULL,
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'embedding_error',
                jsonb_build_object('error', p_error, 'at', CURRENT_TIMESTAMP)
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_memory_id
    RETURNING embedding_status INTO final_status;

    RETURN jsonb_build_object('memory_id', p_memory_id, 'embedding_status', final_status);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION memory_embedding_lifecycle_summary()
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'pending', count(*) FILTER (WHERE embedding_status = 'pending'),
        'in_progress', count(*) FILTER (WHERE embedding_status = 'in_progress'),
        'embedded', count(*) FILTER (WHERE embedding_status = 'embedded'),
        'failed', count(*) FILTER (WHERE embedding_status = 'failed'),
        'skipped', count(*) FILTER (WHERE embedding_status = 'skipped'),
        'oldest_pending_at', min(created_at) FILTER (WHERE embedding_status = 'pending')
    )
    FROM memories;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION create_memory(
    p_type memory_type,
    p_content TEXT,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

    INSERT INTO memories (
        type,
        content,
        embedding,
        embedding_status,
        embedding_attempts,
        importance,
        source_attribution,
        trust_level,
        trust_updated_at,
        metadata
    )
    VALUES (
        p_type,
        p_content,
        NULL,
        'pending',
        0,
        p_importance,
        normalized_source,
        effective_trust,
        CURRENT_TIMESTAMP,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO new_memory_id;
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MERGE (n:MemoryNode {memory_id: %L})
            SET n.type = %L, n.created_at = %L
            RETURN n
        $q$) as (result ag_catalog.agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_memory_with_embedding(
    p_type memory_type,
    p_content TEXT,
    p_embedding vector,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    IF p_embedding IS NULL THEN
        RAISE EXCEPTION 'embedding must not be NULL';
    END IF;

    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

    INSERT INTO memories (
        type,
        content,
        embedding,
        embedded_at,
        embedding_model,
        embedding_status,
        embedding_attempts,
        importance,
        source_attribution,
        trust_level,
        trust_updated_at,
        metadata
    )
    VALUES (
        p_type,
        p_content,
        p_embedding,
        CURRENT_TIMESTAMP,
        get_config_text('embedding.model_id'),
        'embedded',
        1,
        p_importance,
        normalized_source,
        effective_trust,
        CURRENT_TIMESTAMP,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO new_memory_id;

    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            CREATE (n:MemoryNode {memory_id: %L, type: %L, created_at: %L})
            RETURN n
        $q$) as (result ag_catalog.agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
