-- Ingestion receipts (#85/#90 stage 1): completion is recorded per section
-- in a dedicated table, atomically with persistence — never asserted by the
-- encounter memory's mere existence. This stage is inert to current Python
-- (the persist hook fires only when p_source carries section_hash); the
-- pipeline adopts it in the receipt-ordering stage.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS ingestion_receipts (
    doc_ref TEXT NOT NULL,
    section_hash TEXT NOT NULL,
    memory_id UUID,
    memories_created INT NOT NULL DEFAULT 0,
    source_path TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (doc_ref, section_hash)
);

CREATE OR REPLACE FUNCTION record_ingestion_receipt(
    p_doc_ref TEXT,
    p_section_hash TEXT,
    p_memory_id UUID DEFAULT NULL,
    p_memories_created INT DEFAULT 0,
    p_source_path TEXT DEFAULT NULL
) RETURNS VOID AS $$
    INSERT INTO ingestion_receipts (doc_ref, section_hash, memory_id, memories_created, source_path)
    VALUES (p_doc_ref, p_section_hash, p_memory_id, COALESCE(p_memories_created, 0), p_source_path)
    ON CONFLICT (doc_ref, section_hash) DO NOTHING;
$$ LANGUAGE sql;

-- Receipt lookup: the receipts table, with the legacy whole-document
-- memory-attribution fallback ONLY for documents that predate the table —
-- a new-era document always has table rows (the enc: sentinel lands with
-- the encounter), so its encounter attribution can never resurrect the
-- receipt-before-work skip (#85).
CREATE OR REPLACE FUNCTION get_ingestion_receipts(
    p_doc_ref TEXT,
    p_hashes TEXT[]
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(hash, memory_id), '{}'::jsonb) FROM (
        SELECT r.section_hash AS hash, r.memory_id
        FROM ingestion_receipts r
        WHERE r.doc_ref = p_doc_ref AND r.section_hash = ANY(p_hashes)
        UNION
        SELECT m.source_attribution->>'content_hash' AS hash, m.id AS memory_id
        FROM memories m
        WHERE NOT EXISTS (SELECT 1 FROM ingestion_receipts r WHERE r.doc_ref = p_doc_ref)
          AND m.source_attribution->>'ref' = p_doc_ref
          AND m.source_attribution->>'content_hash' = ANY(p_hashes)
    ) hits;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION ingest_persist_extractions(
    p_extractions JSONB,
    p_source JSONB,
    p_encounter_id UUID DEFAULT NULL,
    p_intensity FLOAT DEFAULT 0.0,
    p_options JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    opts JSONB := COALESCE(p_options, '{}'::jsonb);
    min_conf FLOAT := COALESCE((opts->>'min_confidence')::float, 0.0);
    imp_floor FLOAT := (opts->>'min_importance_floor')::float;
    base_trust FLOAT := (opts->>'base_trust')::float;
    permanent BOOLEAN := COALESCE((opts->>'permanent')::boolean, false);
    plan JSONB;
    planned JSONB;
    ext JSONB;
    idx INT;
    decision TEXT;
    matched_id UUID;
    memory_id UUID;
    hint TEXT;
    worldview_id UUID;
    hint_cache JSONB := '{}'::jsonb;
    created_ids UUID[] := ARRAY[]::UUID[];
    corroborated INT := 0;
    failed_corroborations INT := 0;
    importance FLOAT;
    concept TEXT;
    relname TEXT;
    decay FLOAT;
BEGIN
    -- One batched embedding warm-up for everything the router will keep.
    PERFORM prefetch_embeddings(ARRAY(
        SELECT e->>'content'
        FROM jsonb_array_elements(COALESCE(p_extractions, '[]'::jsonb)) e
        WHERE COALESCE((e->>'confidence')::float, 0.0) >= min_conf
    ));

    plan := ingest_route_extractions(p_extractions, min_conf);

    FOR planned IN SELECT value FROM jsonb_array_elements(COALESCE(plan, '[]'::jsonb))
    LOOP
        idx := (planned->>'index')::int;
        ext := p_extractions->idx;
        IF ext IS NULL THEN
            CONTINUE;
        END IF;
        decision := planned->>'decision';
        matched_id := NULLIF(planned->>'matched_memory_id', '')::uuid;

        IF decision = 'duplicate' AND matched_id IS NOT NULL THEN
            -- Corroboration, not re-creation (#34/#35): audited revision +
            -- source merge + evidence edge from the encounter.
            BEGIN
                PERFORM add_memory_evidence(
                    matched_id, 'supports', p_source, NULL, p_encounter_id, 'fast_ingest');
                corroborated := corroborated + 1;
            EXCEPTION WHEN OTHERS THEN
                failed_corroborations := failed_corroborations + 1;
                RAISE WARNING 'ingest corroboration failed for %: %', matched_id, SQLERRM;
            END;
            CONTINUE;
        END IF;

        importance := COALESCE((ext->>'importance')::float, 0.5);
        IF imp_floor IS NOT NULL THEN
            importance := GREATEST(importance, imp_floor);
        END IF;

        memory_id := create_semantic_memory(
            ext->>'content',
            COALESCE((ext->>'confidence')::float, 0.5),
            ARRAY[COALESCE(NULLIF(ext->>'category', ''), 'general')],
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(ext->'connections')), ARRAY[]::text[]),
            jsonb_build_array(p_source),
            importance,
            p_source,
            base_trust
        );
        created_ids := created_ids || memory_id;

        FOR concept IN SELECT trim(c) FROM jsonb_array_elements_text(COALESCE(ext->'concepts', '[]'::jsonb)) c
        LOOP
            IF concept <> '' THEN
                PERFORM link_memory_to_concept(memory_id, concept, 1.0);
            END IF;
        END LOOP;

        -- Worldview hints, resolved once per distinct hint.
        FOR hint, relname IN
            SELECT h.hint, h.rel FROM (VALUES
                (_ingest_hint_text(ext->'supports'), 'SUPPORTS'),
                (_ingest_hint_text(ext->'contradicts'), 'CONTRADICTS')
            ) AS h(hint, rel)
        LOOP
            IF hint IS NULL THEN
                CONTINUE;
            END IF;
            IF hint_cache ? hint THEN
                worldview_id := NULLIF(hint_cache->>hint, '')::uuid;
            ELSE
                worldview_id := find_worldview_by_hint(hint);
                hint_cache := hint_cache || jsonb_build_object(hint, COALESCE(worldview_id::text, ''));
            END IF;
            IF worldview_id IS NOT NULL THEN
                PERFORM discover_relationship(memory_id, worldview_id,
                    relname::graph_edge_type,
                    COALESCE((ext->>'confidence')::float, 0.5), 'ingest');
            END IF;
        END LOOP;

        IF p_encounter_id IS NOT NULL THEN
            PERFORM discover_relationship(memory_id, p_encounter_id,
                'DERIVED_FROM'::graph_edge_type, 0.9, 'ingest');
        END IF;
        IF planned->>'decision' = 'related' AND matched_id IS NOT NULL THEN
            PERFORM discover_relationship(memory_id, matched_id,
                'ASSOCIATED'::graph_edge_type, 0.6, 'ingest');
        END IF;

        decay := CASE WHEN permanent THEN 0.0 ELSE decay_rate_for_intensity(p_intensity) END;
        UPDATE memories SET decay_rate = decay WHERE id = memory_id;
    END LOOP;

    -- Section receipt (#85/#90): completion is recorded in the SAME
    -- transaction as persistence — a crash before this point leaves the
    -- section unreceipted and therefore retried, never silently skipped.
    IF p_source ? 'section_hash' THEN
        PERFORM record_ingestion_receipt(
            COALESCE(p_source->>'content_hash', p_source->>'ref'),
            p_source->>'section_hash',
            NULL,
            COALESCE(array_length(created_ids, 1), 0),
            p_source->>'path');
    END IF;

    RETURN jsonb_build_object(
        'created', to_jsonb(created_ids),
        'corroborated', corroborated,
        'failed_corroborations', failed_corroborations
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION slow_ingest_persist_facts(
    p_facts JSONB,
    p_assessment JSONB,
    p_source JSONB,
    p_encounter_id UUID DEFAULT NULL,
    p_connection_ids UUID[] DEFAULT ARRAY[]::UUID[],
    p_worldview_ids UUID[] DEFAULT ARRAY[]::UUID[],
    p_rejection_reason_ids UUID[] DEFAULT ARRAY[]::UUID[],
    p_context TEXT DEFAULT 'slow_ingest'
) RETURNS JSONB AS $$
DECLARE
    acceptance TEXT := COALESCE(p_assessment->>'acceptance', 'question');
    importance FLOAT := COALESCE((p_assessment->>'importance')::float, 0.5);
    impact TEXT := COALESCE(p_assessment->>'worldview_impact', 'neutral');
    valid_facts TEXT[];
    plan JSONB;
    planned JSONB;
    idx INT;
    fact TEXT;
    decision TEXT;
    matched_id UUID;
    memory_id UUID;
    other UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    corroborated INT := 0;
BEGIN
    valid_facts := ARRAY(
        SELECT trim(f) FROM jsonb_array_elements_text(COALESCE(p_facts, '[]'::jsonb)) f
        WHERE length(trim(f)) >= 10
    );
    IF cardinality(valid_facts) = 0 THEN
        RETURN jsonb_build_object('created', '[]'::jsonb, 'corroborated', 0);
    END IF;

    plan := ingest_route_extractions(
        (SELECT jsonb_agg(jsonb_build_object('content', f, 'confidence',
                COALESCE((p_assessment->>'trust_assessment')::float, 0.5)))
         FROM unnest(valid_facts) f),
        0.0);

    FOR planned IN SELECT value FROM jsonb_array_elements(COALESCE(plan, '[]'::jsonb))
    LOOP
        idx := (planned->>'index')::int;
        fact := valid_facts[idx + 1];
        IF fact IS NULL THEN
            CONTINUE;
        END IF;
        decision := planned->>'decision';
        matched_id := NULLIF(planned->>'matched_memory_id', '')::uuid;

        IF decision = 'duplicate' AND matched_id IS NOT NULL THEN
            BEGIN
                PERFORM add_memory_evidence(
                    matched_id, 'supports', p_source, NULL, p_encounter_id, p_context);
                corroborated := corroborated + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '% corroboration failed for %: %', p_context, matched_id, SQLERRM;
            END;
            CONTINUE;
        END IF;

        BEGIN
            memory_id := create_semantic_memory(
                fact,
                COALESCE((p_assessment->>'trust_assessment')::float, 0.5),
                ARRAY['ingested_fact'], ARRAY[]::text[],
                jsonb_build_array(p_source), importance, p_source, NULL);
            created_ids := created_ids || memory_id;

            IF p_encounter_id IS NOT NULL THEN
                PERFORM discover_relationship(memory_id, p_encounter_id,
                    'DERIVED_FROM'::graph_edge_type, 0.9, p_context);
            END IF;
            IF decision = 'related' AND matched_id IS NOT NULL THEN
                PERFORM discover_relationship(memory_id, matched_id,
                    'ASSOCIATED'::graph_edge_type, 0.6, p_context);
            END IF;
            FOREACH other IN ARRAY COALESCE(p_connection_ids, ARRAY[]::UUID[]) LOOP
                PERFORM discover_relationship(memory_id, other,
                    'ASSOCIATED'::graph_edge_type, 0.7, p_context);
            END LOOP;
            IF impact IN ('supports', 'contradicts') THEN
                FOREACH other IN ARRAY (COALESCE(p_worldview_ids, ARRAY[]::UUID[]))[1:3] LOOP
                    PERFORM discover_relationship(memory_id, other,
                        (CASE impact WHEN 'supports' THEN 'SUPPORTS' ELSE 'CONTRADICTS' END)::graph_edge_type,
                        0.7, p_context);
                END LOOP;
            END IF;
            IF acceptance = 'contest' THEN
                FOREACH other IN ARRAY COALESCE(p_rejection_reason_ids, ARRAY[]::UUID[]) LOOP
                    PERFORM discover_relationship(memory_id, other,
                        'CONTESTED_BECAUSE'::graph_edge_type, 0.8, p_context);
                END LOOP;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '% fact persistence failed: %', p_context, SQLERRM;
        END;
    END LOOP;

    IF p_source ? 'section_hash' THEN
        PERFORM record_ingestion_receipt(
            COALESCE(p_source->>'content_hash', p_source->>'ref'),
            p_source->>'section_hash',
            NULL,
            COALESCE(array_length(created_ids, 1), 0),
            p_source->>'path');
    END IF;

    RETURN jsonb_build_object('created', to_jsonb(created_ids), 'corroborated', corroborated);
END;
$$ LANGUAGE plpgsql;
