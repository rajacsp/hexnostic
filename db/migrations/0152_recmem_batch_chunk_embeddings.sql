-- Batch RecMem span embedding updates so a long unit makes one cache-aware
-- embedding call for all claimed spans instead of one HTTP request per span.

SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION embed_claimed_recmem_chunks(
    p_chunk_ids UUID[],
    p_contents TEXT[]
) RETURNS JSONB AS $$
DECLARE
    expected_count INT := COALESCE(array_length(p_chunk_ids, 1), 0);
    content_count INT := COALESCE(array_length(p_contents, 1), 0);
    embeddings vector[];
    embedding_count INT;
    updated_count INT := 0;
BEGIN
    IF expected_count = 0 THEN
        RETURN jsonb_build_object('updated', 0, 'skipped', true, 'reason', 'no_chunks');
    END IF;

    IF content_count <> expected_count THEN
        RAISE EXCEPTION 'RecMem chunk embedding input mismatch: % ids, % contents',
            expected_count,
            content_count;
    END IF;

    embeddings := get_embedding(p_contents);
    embedding_count := COALESCE(array_length(embeddings, 1), 0);

    IF embedding_count <> expected_count THEN
        RAISE EXCEPTION 'RecMem chunk embedding output mismatch: expected %, got %',
            expected_count,
            embedding_count;
    END IF;

    WITH payload AS (
        SELECT
            p_chunk_ids[i] AS chunk_id,
            embeddings[i] AS embedding
        FROM generate_subscripts(p_chunk_ids, 1) AS i
    )
    UPDATE subconscious_unit_embedding_chunks c
    SET embedding = payload.embedding,
        embedded_at = CURRENT_TIMESTAMP,
        embedding_model = get_config_text('embedding.model_id'),
        embedding_status = 'embedded',
        embedding_claimed_at = NULL,
        updated_at = CURRENT_TIMESTAMP
    FROM payload
    WHERE c.id = payload.chunk_id
      AND c.embedding_status = 'in_progress';

    GET DIAGNOSTICS updated_count = ROW_COUNT;

    IF updated_count <> expected_count THEN
        RAISE EXCEPTION 'RecMem chunk embedding update mismatch: expected %, updated %',
            expected_count,
            updated_count;
    END IF;

    RETURN jsonb_build_object('updated', updated_count);
END;
$$ LANGUAGE plpgsql;
