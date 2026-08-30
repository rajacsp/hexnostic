-- Sources are authority (#83, Eric's ruling): trust_level always derives
-- from provenance. The slow-ingest acceptance multiplier retires (stance
-- lives in edges/metadata); sync_memory_trust covers worldview rows;
-- initialization-seeded rows get an honest 'initialization' source
-- (operator-authored, config-owned trust) and every disagreeing active
-- semantic/worldview row is recomputed once, with the count logged.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('memory.init_seed_trust', '0.95'::jsonb,
     'Source trust for initialization-seeded memories (operator-authored)')
ON CONFLICT (key) DO NOTHING;

SELECT delete_config_key('memory.slow_ingest_trust_multipliers');

CREATE OR REPLACE FUNCTION sync_memory_trust(p_memory_id UUID)
RETURNS VOID AS $$
DECLARE
    mtype memory_type;
    conf FLOAT;
    sources JSONB;
    alignment FLOAT;
    computed FLOAT;
    mem_metadata JSONB;
BEGIN
    SELECT type, metadata INTO mtype, mem_metadata FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Protected memories (e.g. origin documents) keep their seeded trust:
    -- confidence may still be revised, but derived trust is pinned.
    IF COALESCE((mem_metadata->>'protected')::boolean, FALSE) THEN
        RETURN;
    END IF;

    -- Sources are authority (#83) for worldview too: a belief's trust is its
    -- source's trust — a row may never assert more trust than its provenance
    -- carries.
    IF mtype = 'worldview' THEN
        UPDATE memories
        SET trust_level = LEAST(1.0, GREATEST(0.0, COALESCE(
                (source_attribution->>'trust')::float, 0.5))),
            trust_updated_at = CURRENT_TIMESTAMP
        WHERE id = p_memory_id;
        RETURN;
    END IF;

    IF mtype <> 'semantic' THEN
        RETURN;
    END IF;
    conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
    sources := mem_metadata->'source_references';

    sources := dedupe_source_references(sources);
    alignment := compute_worldview_alignment(p_memory_id);
    computed := compute_semantic_trust(conf, sources, alignment);

    UPDATE memories
    SET trust_level = computed,
        trust_updated_at = CURRENT_TIMESTAMP,
        source_attribution = CASE
            WHEN (source_attribution = '{}'::jsonb OR source_attribution IS NULL)
                 AND jsonb_typeof(sources) = 'array'
                 AND jsonb_array_length(sources) > 0
            THEN normalize_source_reference(sources->0)
            ELSE source_attribution
        END
    WHERE id = p_memory_id;
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

    RETURN jsonb_build_object('created', to_jsonb(created_ids), 'corroborated', corroborated);
END;
$$ LANGUAGE plpgsql;

-- Initialization-origin rows: the operator's configuration is the source;
-- say so, so derived trust is honest instead of asserted.
DO $$
DECLARE
    upgraded INT;
    recomputed INT := 0;
    row_id UUID;
BEGIN
    UPDATE memories
    SET source_attribution = COALESCE(source_attribution, '{}'::jsonb)
        || jsonb_build_object(
            'kind', 'initialization',
            'trust', COALESCE(get_config_float('memory.init_seed_trust'), 0.95))
    WHERE metadata->>'origin' = 'initialization'
      AND COALESCE((source_attribution->>'trust')::float, 0.5) < 0.9;
    GET DIAGNOSTICS upgraded = ROW_COUNT;

    FOR row_id IN
        -- Archived rows resurface via archive processing; they converge too.
        SELECT id FROM memories
        WHERE status IN ('active', 'archived') AND type IN ('semantic', 'worldview')
          AND COALESCE((metadata->>'protected')::boolean, FALSE) = FALSE
    LOOP
        PERFORM sync_memory_trust(row_id);
        recomputed := recomputed + 1;
    END LOOP;

    RAISE NOTICE 'trust backfill (#83): % initialization sources upgraded, % rows recomputed', upgraded, recomputed;
END $$;
