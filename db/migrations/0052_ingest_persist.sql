-- 0052: Atomic ingest persistence (plans/db_pushdown.md 3.1 + 2.6
-- helpers). The post-LLM persistence loop becomes one transaction;
-- worldview-hint threshold and decay bands become config. Baseline
-- mirror: db/66.
SET search_path = public, ag_catalog, "$user";


INSERT INTO config (key, value, description) VALUES
    ('memory.ingest_decay_base', '0.01'::jsonb,
     'Base decay rate for ingested memories; intensity bands scale it'),
    ('memory.ingest_worldview_hint_threshold', '0.7'::jsonb,
     'Minimum similarity for an extraction hint to link a worldview memory')
ON CONFLICT (key) DO NOTHING;

-- 2.6: intensity -> decay-rate bands (flat < 0.1 decays 3x faster; vivid
-- > 0.6 decays half as fast), base config-owned.
CREATE OR REPLACE FUNCTION decay_rate_for_intensity(
    p_intensity FLOAT
) RETURNS FLOAT AS $$
DECLARE
    base FLOAT := COALESCE(get_config_float('memory.ingest_decay_base'), 0.01);
    i FLOAT := COALESCE(p_intensity, 0.0);
BEGIN
    RETURN CASE
        WHEN i < 0.1 THEN base * 3.0
        WHEN i < 0.3 THEN base * 1.5
        WHEN i > 0.6 THEN base * 0.5
        ELSE base
    END;
END;
$$ LANGUAGE plpgsql STABLE;

-- 2.6: resolve an extraction's supports/contradicts hint to a worldview
-- memory by embedding similarity.
CREATE OR REPLACE FUNCTION find_worldview_by_hint(
    p_hint TEXT,
    p_threshold FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    threshold FLOAT := COALESCE(p_threshold,
        get_config_float('memory.ingest_worldview_hint_threshold'), 0.7);
    hint_emb vector;
    found UUID;
BEGIN
    IF NULLIF(trim(COALESCE(p_hint, '')), '') IS NULL THEN
        RETURN NULL;
    END IF;

    BEGIN
        hint_emb := (get_embedding(ARRAY[ensure_embedding_prefix(p_hint, 'search_query')]))[1];
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    SELECT m.id INTO found
    FROM memories m
    WHERE m.type = 'worldview'
      AND m.status = 'active'
      AND (1 - (m.embedding <=> hint_emb)) >= threshold
    ORDER BY m.embedding <=> hint_emb
    LIMIT 1;

    RETURN found;
END;
$$ LANGUAGE plpgsql;

-- Hints arrive as a string or a list of strings; normalize to one text.
CREATE OR REPLACE FUNCTION _ingest_hint_text(p_hint JSONB)
RETURNS TEXT AS $$
BEGIN
    IF p_hint IS NULL OR p_hint = 'null'::jsonb THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p_hint) = 'array' THEN
        RETURN NULLIF(trim((
            SELECT string_agg(value, ' ')
            FROM jsonb_array_elements_text(p_hint)
            WHERE NULLIF(trim(value), '') IS NOT NULL
        )), '');
    END IF;
    RETURN NULLIF(trim(p_hint #>> '{}'), '');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3.1: the whole post-LLM persistence pass, atomic.
-- p_extractions: [{content, confidence, importance, category, concepts[],
--                  connections[], supports, contradicts}]
-- p_options: {min_confidence, min_importance_floor, base_trust, permanent}
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

    RETURN jsonb_build_object(
        'created', to_jsonb(created_ids),
        'corroborated', corroborated,
        'failed_corroborations', failed_corroborations
    );
END;
$$ LANGUAGE plpgsql;
