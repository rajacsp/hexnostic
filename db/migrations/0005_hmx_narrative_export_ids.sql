-- HMX narrative records need a portable local identifier before Python can
-- scope them under export_id. AGE properties alone do not guarantee one.
CREATE OR REPLACE FUNCTION hmx_export_narrative() RETURNS JSONB AS $$
DECLARE
    chapters JSONB;
    turning_points JSONB;
    threads JSONB;
    conflicts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        props::text::jsonb || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO chapters
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:LifeChapterNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        props::text::jsonb || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO turning_points
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:TurningPointNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        props::text::jsonb || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO threads
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:NarrativeThreadNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(
        props::text::jsonb || jsonb_build_object('id', replace(node_id::text, '"', ''))
    ), '[]'::jsonb) INTO conflicts
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:ValueConflictNode) RETURN id(n), properties(n)
    $q$) AS (node_id ag_catalog.agtype, props ag_catalog.agtype);

    RETURN jsonb_build_object(
        'life_chapters', chapters,
        'turning_points', turning_points,
        'narrative_threads', threads,
        'value_conflicts', conflicts
    );
END;
$$ LANGUAGE plpgsql STABLE;
