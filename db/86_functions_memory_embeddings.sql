-- Async embedding lifecycle for durable memories.
--
-- Ordinary memory creation records the memory immediately and leaves
-- embedding_status='pending'. Maintenance workers claim, embed, and mark rows
-- complete; imports with precomputed embeddings can still insert directly.
SET search_path = public, ag_catalog, "$user";

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
