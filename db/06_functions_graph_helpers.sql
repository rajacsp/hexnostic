-- Hexis schema: graph helper functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION link_memory_to_episode_graph(
    p_memory_id UUID,
    p_episode_id UUID,
    p_sequence_order INT DEFAULT 0
)
RETURNS BOOLEAN AS $$
BEGIN
    PERFORM sync_episode_node(p_episode_id);
    PERFORM sync_memory_node(p_memory_id);

    EXECUTE format('SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode {memory_id: %L})
        MATCH (e:EpisodeNode {episode_id: %L})
        CREATE (m)-[:IN_EPISODE {sequence_order: %s}]->(e)
        RETURN m
    $q$) as (result ag_catalog.agtype)', p_memory_id, p_episode_id, p_sequence_order);

    PERFORM upsert_memory_edge('memory', p_memory_id::text, 'IN_EPISODE', 'episode', p_episode_id::text,
                               1.0, NULL, NULL, jsonb_build_object('sequence_order', p_sequence_order));
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_cluster_members_graph(p_cluster_id UUID)
RETURNS TABLE (
    memory_id UUID,
    membership_strength FLOAT
) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN EXECUTE format('SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode)-[r:MEMBER_OF]->(c:ClusterNode {cluster_id: %L})
        RETURN m.memory_id, r.strength
    $q$) as (mid ag_catalog.agtype, str ag_catalog.agtype)', p_cluster_id)
    LOOP
        memory_id := replace(rec.mid::text, '"', '')::uuid;
        membership_strength := COALESCE(replace(rec.str::text, '"', '')::float, 1.0);
        RETURN NEXT;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
