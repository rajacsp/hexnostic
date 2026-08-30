-- DB-owned document-ingestion routing: the dedup / related / create policy.
-- Ports the 0.92 / 0.8 similarity thresholds + duplicate/related/create decision
-- out of services/ingest.py:_create_semantic_memories into SQL, config-driven,
-- doing ONE batched vector search instead of N per-extraction Python round-trips.
--
-- Note: dedup uses a true nearest-neighbor vector search over active semantic
-- memories (more correct than the Python recall pipeline it replaces). The
-- decision (dup/related/create) is threshold-driven; only the related-edge
-- target differs from the old code (nearest neighbor vs. its last-wins quirk).
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('memory.ingest_theta_dup', '0.92'::jsonb,
     'Ingest: similarity >= this treats an extraction as a duplicate of an existing semantic memory (merge source + boost confidence, no new memory)'),
    ('memory.ingest_theta_related', '0.8'::jsonb,
     'Ingest: similarity in [related, dup) creates a new memory linked ASSOCIATED to the neighbor')
ON CONFLICT (key) DO NOTHING;

-- Route a single already-embedded item: nearest active-semantic neighbor +
-- the threshold decision. Split out so the routing policy is testable without
-- the embedding service (get_embedding).
CREATE OR REPLACE FUNCTION ingest_route_embedding(p_embedding vector)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    theta_dup FLOAT := COALESCE(get_config_float('memory.ingest_theta_dup'), 0.92);
    theta_related FLOAT := COALESCE(get_config_float('memory.ingest_theta_related'), 0.8);
    top_id UUID;
    top_sim FLOAT;
    decision TEXT;
    matched UUID;
BEGIN
    IF p_embedding IS NULL THEN
        RETURN jsonb_build_object('decision', 'create', 'matched_memory_id', NULL, 'similarity', NULL);
    END IF;

    SELECT n.id, n.sim INTO top_id, top_sim
    FROM (
        SELECT m.id, 1 - (m.embedding <=> p_embedding) AS sim
        FROM memories m
        WHERE m.status = 'active'
          AND m.type = 'semantic'
          AND m.embedding IS NOT NULL
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
        ORDER BY m.embedding <=> p_embedding
        LIMIT 5
    ) n
    ORDER BY n.sim DESC
    LIMIT 1;

    IF top_id IS NOT NULL AND top_sim >= theta_dup THEN
        decision := 'duplicate'; matched := top_id;
    ELSIF top_id IS NOT NULL AND top_sim >= theta_related THEN
        decision := 'related'; matched := top_id;
    ELSE
        decision := 'create'; matched := NULL;
    END IF;

    RETURN jsonb_build_object(
        'decision', decision, 'matched_memory_id', matched, 'similarity', top_sim);
END;
$$;

CREATE OR REPLACE FUNCTION ingest_route_extractions(
    p_extractions JSONB,
    p_min_confidence FLOAT DEFAULT 0.0
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    ext JSONB;
    idx INT := -1;
    content TEXT;
    routed JSONB;
    plan JSONB := '[]'::jsonb;
BEGIN
    FOR ext IN SELECT * FROM jsonb_array_elements(COALESCE(p_extractions, '[]'::jsonb))
    LOOP
        idx := idx + 1;
        -- Below-confidence extractions are dropped (mirrors the Python filter).
        IF COALESCE((ext->>'confidence')::float, 0.0) < p_min_confidence THEN
            CONTINUE;
        END IF;
        content := COALESCE(ext->>'content', '');
        IF content = '' THEN
            CONTINUE;
        END IF;

        routed := ingest_route_embedding((get_embedding(ARRAY[content]))[1]);
        plan := plan || jsonb_build_array(routed || jsonb_build_object('index', idx));
    END LOOP;

    RETURN plan;
END;
$$;
