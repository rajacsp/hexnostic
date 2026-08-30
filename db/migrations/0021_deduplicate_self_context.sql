-- Repeated persona initialization must update self-model edges instead of
-- layering duplicates; legacy duplicates are collapsed when context is read.
CREATE OR REPLACE FUNCTION upsert_self_concept_edge(
    p_kind TEXT,
    p_concept TEXT,
    p_strength FLOAT DEFAULT 0.8,
    p_evidence_memory_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    evidence_text TEXT;
    now_text TEXT := clock_timestamp()::text;
BEGIN
    IF p_kind IS NULL OR btrim(p_kind) = '' OR p_concept IS NULL OR btrim(p_concept) = '' THEN
        RETURN;
    END IF;

    PERFORM ensure_self_node();
    evidence_text := CASE WHEN p_evidence_memory_id IS NULL THEN NULL ELSE p_evidence_memory_id::text END;

    BEGIN
        EXECUTE format(
            'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                MATCH (s:SelfNode {key: ''self''})
                MERGE (c:ConceptNode {name: %L})
                MERGE (s)-[r:ASSOCIATED]->(c)
                SET r.kind = %L,
                    r.strength = %s,
                    r.updated_at = %L,
                    r.evidence_memory_id = %L
                RETURN r
            $q$) as (result ag_catalog.agtype)',
            p_concept,
            p_kind,
            LEAST(1.0, GREATEST(0.0, COALESCE(p_strength, 0.8))),
            now_text,
            evidence_text
        );
        PERFORM upsert_memory_edge(
            'self', 'self', 'ASSOCIATED', 'concept', p_concept,
            LEAST(1.0, GREATEST(0.0, COALESCE(p_strength, 0.8))), p_kind, NULL,
            jsonb_build_object('kind', p_kind, 'evidence_memory_id', evidence_text)
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_self_model_context(p_limit INT DEFAULT 25)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(200, COALESCE(p_limit, 25)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH raw_hits AS (
            SELECT
                NULLIF(replace(kind_raw::text, '"', ''), 'null') as kind,
                NULLIF(replace(concept_raw::text, '"', ''), 'null') as concept,
                NULLIF(replace(evidence_raw::text, '"', ''), 'null') as evidence_memory_id,
                NULLIF(strength_raw::text, 'null')::float as strength
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (s:SelfNode {key: 'self'})-[r:ASSOCIATED]->(c)
                WHERE r.kind IS NOT NULL
                RETURN r.kind, c.name, r.strength, r.evidence_memory_id
                LIMIT %s
            $q$) as (kind_raw ag_catalog.agtype, concept_raw ag_catalog.agtype, strength_raw ag_catalog.agtype, evidence_raw ag_catalog.agtype)
        ), deduplicated AS (
            SELECT DISTINCT ON (kind, concept)
                kind, concept, strength, evidence_memory_id
            FROM raw_hits
            WHERE kind IS NOT NULL AND concept IS NOT NULL
            ORDER BY kind, concept, strength DESC NULLS LAST
        )
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'kind', kind,
                'concept', concept,
                'strength', COALESCE(strength, 0.0),
                'evidence_memory_id', evidence_memory_id
            )
        ), '[]'::jsonb)
        FROM (
            SELECT * FROM deduplicated
            ORDER BY strength DESC NULLS LAST, kind, concept
            LIMIT %s
        ) ranked
    $sql$, GREATEST(lim * 4, 100), lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_relationships_context(p_limit INT DEFAULT 10)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(100, COALESCE(p_limit, 10)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH raw_hits AS (
            SELECT
                NULLIF(replace(name_raw::text, '"', ''), 'null') as entity,
                NULLIF(strength_raw::text, 'null')::float as strength,
                NULLIF(replace(evidence_raw::text, '"', ''), 'null') as evidence_memory_id
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (s:SelfNode {key: 'self'})-[r:ASSOCIATED]->(c)
                WHERE r.kind = 'relationship'
                RETURN c.name, r.strength, r.evidence_memory_id
                ORDER BY r.strength DESC
                LIMIT %s
            $q$) as (name_raw ag_catalog.agtype, strength_raw ag_catalog.agtype, evidence_raw ag_catalog.agtype)
        ), deduplicated AS (
            SELECT DISTINCT ON (entity)
                entity, strength, evidence_memory_id
            FROM raw_hits
            WHERE entity IS NOT NULL
            ORDER BY entity, strength DESC NULLS LAST
        )
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'entity', entity,
                'strength', COALESCE(strength, 0.0),
                'evidence_memory_id', evidence_memory_id
            )
        ), '[]'::jsonb)
        FROM (
            SELECT * FROM deduplicated
            ORDER BY strength DESC NULLS LAST, entity
            LIMIT %s
        ) ranked
    $sql$, GREATEST(lim * 4, 100), lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_identity_context()
RETURNS JSONB AS $$
DECLARE
    result JSONB := '[]'::jsonb;
BEGIN
    BEGIN
        SELECT COALESCE(
            jsonb_agg(sub.obj ORDER BY sub.strength DESC, sub.kind, sub.concept),
            '[]'::jsonb
        )
        INTO result
        FROM (
            SELECT DISTINCT ON (kind_text, concept_text)
                jsonb_build_object(
                    'type', kind_text,
                    'concept', concept_text,
                    'strength', strength_float
                ) as obj,
                kind_text AS kind,
                concept_text AS concept,
                strength_float AS strength
            FROM (
                SELECT
                    replace(kind::text, '"', '') AS kind_text,
                    replace(concept::text, '"', '') AS concept_text,
                    (strength::text)::float AS strength_float
                FROM ag_catalog.cypher('memory_graph', $q$
                    MATCH (s:SelfNode)-[r:ASSOCIATED]->(c)
                    RETURN r.kind as kind, c.name as concept, r.strength as strength
                    ORDER BY r.strength DESC
                    LIMIT 100
                $q$) as (kind ag_catalog.agtype, concept ag_catalog.agtype, strength ag_catalog.agtype)
            ) raw
            ORDER BY kind_text, concept_text, strength_float DESC
            LIMIT 15
        ) sub;
    EXCEPTION WHEN OTHERS THEN result := '[]'::jsonb; END;
    RETURN result;
END;
$$ LANGUAGE plpgsql;
