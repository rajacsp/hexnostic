-- Hexis schema: graph enhancement functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION discover_relationship(
    p_from_id UUID,
    p_to_id UUID,
    p_relationship_type graph_edge_type,
    p_confidence FLOAT DEFAULT 0.8,
    p_discovered_by TEXT DEFAULT 'reflection',
    p_heartbeat_id UUID DEFAULT NULL,
    p_discovery_context TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    BEGIN
        PERFORM create_memory_relationship(
            p_from_id,
            p_to_id,
            p_relationship_type,
            jsonb_build_object(
                'confidence', p_confidence,
                'by', p_discovered_by,
                'context', p_discovery_context,
                'heartbeat_id', p_heartbeat_id
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION link_memory_supports_worldview(
    p_memory_id UUID,
    p_worldview_id UUID,
    p_strength FLOAT DEFAULT 0.8
)
RETURNS VOID AS $$
BEGIN
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (w:MemoryNode {memory_id: %L})
            WHERE w.type = ''worldview''
            MERGE (m)-[r:SUPPORTS]->(w)
            SET r.strength = %s
            RETURN r
        $q$) as (result ag_catalog.agtype)',
        p_memory_id,
        p_worldview_id,
        COALESCE(p_strength, 0.8)
    );
    PERFORM upsert_memory_edge('memory', p_memory_id::text, 'SUPPORTS', 'memory', p_worldview_id::text,
                               COALESCE(p_strength, 0.8), NULL, NULL,
                               jsonb_build_object('strength', COALESCE(p_strength, 0.8)));
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION find_contradictions(p_memory_id UUID DEFAULT NULL)
RETURNS TABLE (
    memory_a UUID,
    memory_b UUID,
    content_a TEXT,
    content_b TEXT
) AS $$
DECLARE
    filter_clause TEXT;
    sql TEXT;
BEGIN
    filter_clause := CASE
        WHEN p_memory_id IS NULL THEN ''
        ELSE format('WHERE a.memory_id = %L OR b.memory_id = %L', p_memory_id, p_memory_id)
    END;

    sql := format($sql$
        WITH pairs AS (
            SELECT
                replace(a_id::text, '"', '')::uuid as a_uuid,
                replace(b_id::text, '"', '')::uuid as b_uuid
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (a:MemoryNode)-[:CONTRADICTS]-(b:MemoryNode)
                %s
                RETURN a.memory_id, b.memory_id
            $q$) as (a_id ag_catalog.agtype, b_id ag_catalog.agtype)
        )
        SELECT
            p.a_uuid as memory_a,
            p.b_uuid as memory_b,
            ma.content as content_a,
            mb.content as content_b
        FROM pairs p
        JOIN memories ma ON ma.id = p.a_uuid
        JOIN memories mb ON mb.id = p.b_uuid
    $sql$, filter_clause);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION find_causal_chain(p_memory_id UUID, p_depth INT DEFAULT 3)
RETURNS TABLE (
    cause_id UUID,
    cause_content TEXT,
    relationship TEXT,
    distance INT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(cause_id_raw::text, '"', '')::uuid as cause_uuid,
                replace(rel_raw::text, '"', '') as rel_type,
                (dist_raw::text)::int as dist
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH path = (cause:MemoryNode)-[:CAUSES*1..%s]->(effect:MemoryNode {memory_id: %L})
                RETURN cause.memory_id, type(relationships(path)[-1]), length(path)
            $q$) as (cause_id_raw ag_catalog.agtype, rel_raw ag_catalog.agtype, dist_raw ag_catalog.agtype)
        )
        SELECT
            h.cause_uuid as cause_id,
            m.content as cause_content,
            h.rel_type as relationship,
            h.dist as distance
        FROM hits h
        JOIN memories m ON m.id = h.cause_uuid
        ORDER BY h.dist ASC
    $sql$, GREATEST(1, LEAST(10, COALESCE(p_depth, 3))), p_memory_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION find_connected_concepts(p_memory_id UUID, p_hops INT DEFAULT 2)
RETURNS TABLE (
    concept_name TEXT,
    path_length INT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        SELECT
            replace(name_raw::text, '"', '')::text as concept_name,
            1 as path_length
        FROM ag_catalog.cypher('memory_graph', $q$
            MATCH (m:MemoryNode {memory_id: %L})-[r:INSTANCE_OF]->(c:ConceptNode)
            RETURN c.name, r.strength
            ORDER BY r.strength DESC
        $q$) as (name_raw ag_catalog.agtype, strength_raw ag_catalog.agtype)
    $sql$, p_memory_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION find_memories_by_concept(
    p_concept_name TEXT,
    p_limit INT DEFAULT 10
)
RETURNS TABLE (
    memory_id UUID,
    memory_content TEXT,
    memory_importance FLOAT,
    memory_type memory_type,
    memory_created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    link_strength FLOAT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(mid_raw::text, '"', '')::uuid as mem_uuid,
                COALESCE((strength_raw::text)::float, 1.0) as strength
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:INSTANCE_OF]->(c:ConceptNode {name: %L})
                RETURN m.memory_id, r.strength
                ORDER BY r.strength DESC
            $q$) as (mid_raw ag_catalog.agtype, strength_raw ag_catalog.agtype)
            LIMIT %s
        )
        SELECT
            m.id as memory_id,
            m.content as memory_content,
            m.importance as memory_importance,
            m.type as memory_type,
            m.created_at as memory_created_at,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            h.strength as link_strength
        FROM hits h
        JOIN memories m ON m.id = h.mem_uuid
        WHERE m.status = 'active'
        ORDER BY h.strength DESC, m.importance DESC
    $sql$, p_concept_name, p_limit);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION find_supporting_evidence(p_worldview_id UUID)
RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    strength FLOAT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(mem_raw::text, '"', '')::uuid as mem_uuid,
                (strength_raw::text)::float as strength
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                WHERE w.type = 'worldview'
                RETURN m.memory_id, r.strength
            $q$) as (mem_raw ag_catalog.agtype, strength_raw ag_catalog.agtype)
        )
        SELECT
            h.mem_uuid as memory_id,
            m.content as content,
            h.strength as strength
        FROM hits h
        JOIN memories m ON m.id = h.mem_uuid
        ORDER BY h.strength DESC
    $sql$, p_worldview_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
