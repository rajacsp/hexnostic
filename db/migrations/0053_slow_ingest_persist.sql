-- 0053: Slow-ingest fact persistence, atomic (plans/db_pushdown.md 3.2).
-- Kills the duplicated Python fact loop in slow_ingest_rlm.py (slow +
-- hybrid paths) and moves the acceptance trust multipliers to config.
-- Baseline mirror: db/66.
SET search_path = public, ag_catalog, "$user";

-- 3.2: slow-ingest fact persistence, atomic. Serves both the slow path and
-- the hybrid path (which passes empty connection/worldview arrays). The
-- acceptance -> trust multipliers move from a Python dict to config.
INSERT INTO config (key, value, description) VALUES
    ('memory.slow_ingest_trust_multipliers',
     '{"accept": 1.0, "contest": 0.4, "question": 0.7}'::jsonb,
     'Trust multiplier applied to a chunk''s trust_assessment by acceptance stance')
ON CONFLICT (key) DO NOTHING;

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
    trust_assessment FLOAT := COALESCE((p_assessment->>'trust_assessment')::float, 0.5);
    importance FLOAT := COALESCE((p_assessment->>'importance')::float, 0.5);
    impact TEXT := COALESCE(p_assessment->>'worldview_impact', 'neutral');
    trust_mult FLOAT := COALESCE(
        (get_config('memory.slow_ingest_trust_multipliers')->>acceptance)::float, 0.7);
    base_trust FLOAT := trust_assessment * trust_mult;
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
        (SELECT jsonb_agg(jsonb_build_object('content', f, 'confidence', trust_assessment))
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
                fact, trust_assessment, ARRAY['ingested_fact'], ARRAY[]::text[],
                jsonb_build_array(p_source), importance, p_source, base_trust);
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
