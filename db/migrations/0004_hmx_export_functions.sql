-- HMX Slice 1: export functions. Identical content to the baseline file
-- db/48_functions_memory_exchange.sql (see db/migrations/README.md on mirroring).
-- All statements are CREATE OR REPLACE — idempotent on fresh and existing DBs.
-- ============================================================================
SET check_function_bodies = off;

-- Memories section: the non-protected memory types. Worldview and goal
-- memories are exported through their dedicated (protected) sections instead,
-- so one row never rides in two sections.
CREATE OR REPLACE FUNCTION hmx_export_memories(
    p_types TEXT[] DEFAULT NULL,
    p_since TIMESTAMPTZ DEFAULT NULL,
    p_until TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'type', m.type,
        'status', m.status,
        'content', m.content,
        'importance', m.importance,
        'trust_level', m.trust_level,
        'decay_rate', m.decay_rate,
        'created_at', m.created_at,
        'updated_at', m.updated_at,
        'valid_from', m.valid_from,
        'valid_until', m.valid_until,
        'access_count', m.access_count,
        'last_accessed', m.last_accessed,
        'superseded_by', m.superseded_by,
        'source_attribution', m.source_attribution,
        'metadata', m.metadata
    ) ORDER BY m.created_at, m.id), '[]'::jsonb)
    FROM memories m
    WHERE m.status IN ('active', 'archived')
      AND m.type::text = ANY(COALESCE(p_types, ARRAY['episodic','semantic','procedural','strategic']))
      AND m.type::text NOT IN ('worldview', 'goal')
      AND (p_since IS NULL OR m.created_at >= p_since)
      AND (p_until IS NULL OR m.created_at <= p_until);
$$ LANGUAGE sql STABLE;

-- Episodes with membership resolved from the flat edge substrate.
CREATE OR REPLACE FUNCTION hmx_export_episodes() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', e.id,
        'started_at', e.started_at,
        'ended_at', e.ended_at,
        'summary', e.summary,
        'metadata', e.metadata,
        'memory_ids', COALESCE((
            SELECT jsonb_agg(DISTINCT me.src_id)
            FROM memory_edges me
            WHERE me.rel_type = 'IN_EPISODE'
              AND me.dst_type = 'episode'
              AND me.dst_id = e.id::text
        ), '[]'::jsonb)
    ) ORDER BY e.started_at, e.id), '[]'::jsonb)
    FROM episodes e;
$$ LANGUAGE sql STABLE;

-- Graph edges from the primary flat substrate, plus canonical SUPERSEDES
-- edges derived from the legacy memories.superseded_by column.
CREATE OR REPLACE FUNCTION hmx_export_relationships() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(edge), '[]'::jsonb)
    FROM (
        SELECT jsonb_build_object(
            'source_id', me.src_id,
            'source_type', me.src_type,
            'target_id', me.dst_id,
            'target_type', me.dst_type,
            'edge_type', me.rel_type,
            'properties', COALESCE(me.properties, '{}'::jsonb) || jsonb_build_object(
                'weight', me.weight,
                'kind', me.kind,
                'source', me.source,
                'created_at', me.created_at
            )
        ) AS edge
        FROM memory_edges me
        UNION ALL
        SELECT jsonb_build_object(
            'source_id', m.id::text,
            'source_type', 'memory',
            'target_id', m.superseded_by::text,
            'target_type', 'memory',
            'edge_type', 'SUPERSEDES',
            'properties', jsonb_build_object('created_at', m.updated_at, 'reason', 'superseded_by_column')
        )
        FROM memories m
        WHERE m.superseded_by IS NOT NULL
    ) edges;
$$ LANGUAGE sql STABLE;

-- Worldview (protected): beliefs/boundaries/values with graph evidence.
CREATE OR REPLACE FUNCTION hmx_export_worldview() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'category', COALESCE(m.metadata->>'category', 'belief'),
        'content', m.content,
        'confidence', COALESCE((m.metadata->>'confidence')::float, 0.8),
        'stability', COALESCE((m.metadata->>'stability')::float, 0.7),
        'importance', m.importance,
        'status', m.status,
        'supporting_ids', COALESCE((
            SELECT jsonb_agg(DISTINCT me.src_id)
            FROM memory_edges me
            WHERE me.rel_type IN ('SUPPORTS', 'EVIDENCE_FOR')
              AND me.dst_type = 'memory' AND me.dst_id = m.id::text
        ), '[]'::jsonb),
        'contesting_ids', COALESCE((
            SELECT jsonb_agg(DISTINCT me.src_id)
            FROM memory_edges me
            WHERE me.rel_type IN ('CONTRADICTS', 'CONTESTED_BECAUSE')
              AND me.dst_type = 'memory' AND me.dst_id = m.id::text
        ), '[]'::jsonb),
        'metadata', m.metadata
    ) ORDER BY m.created_at, m.id), '[]'::jsonb)
    FROM memories m
    WHERE m.type = 'worldview' AND m.status IN ('active', 'archived');
$$ LANGUAGE sql STABLE;

-- Goals (protected): goal memories carry their structure in metadata.
CREATE OR REPLACE FUNCTION hmx_export_goals() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'title', COALESCE(m.metadata->>'title', m.content),
        'description', m.metadata->>'description',
        'priority', COALESCE(m.metadata->>'priority', 'queued'),
        'source', COALESCE(m.metadata->>'source', 'curiosity'),
        'due_at', m.metadata->'due_at',
        'progress', COALESCE(m.metadata->'progress', '[]'::jsonb),
        'blocked_by', m.metadata->'blocked_by',
        'parent_goal_id', m.metadata->>'parent_goal_id',
        'status', m.status,
        'metadata', m.metadata
    ) ORDER BY m.created_at, m.id), '[]'::jsonb)
    FROM memories m
    WHERE m.type = 'goal' AND m.status IN ('active', 'archived');
$$ LANGUAGE sql STABLE;

-- Drives (protected): live motivational dynamics.
CREATE OR REPLACE FUNCTION hmx_export_drives() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name', d.name,
        'description', d.description,
        'current_level', d.current_level,
        'baseline', d.baseline,
        'accumulation_rate', d.accumulation_rate,
        'decay_rate', d.decay_rate,
        'satisfaction_cooldown', d.satisfaction_cooldown::text,
        'last_satisfied', d.last_satisfied,
        'urgency_threshold', d.urgency_threshold
    ) ORDER BY d.name), '[]'::jsonb)
    FROM drives d;
$$ LANGUAGE sql STABLE;

-- Emotional triggers (protected). Embedding omitted by design.
CREATE OR REPLACE FUNCTION hmx_export_emotional_triggers() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', t.id,
        'trigger_pattern', t.trigger_pattern,
        'valence_delta', t.valence_delta,
        'arousal_delta', t.arousal_delta,
        'dominance_delta', t.dominance_delta,
        'typical_emotion', t.typical_emotion,
        'confidence', t.confidence,
        'times_activated', t.times_activated,
        'origin', t.origin,
        'source_memory_ids', COALESCE(to_jsonb(t.source_memory_ids), '[]'::jsonb)
    ) ORDER BY t.trigger_pattern, t.id), '[]'::jsonb)
    FROM emotional_triggers t;
$$ LANGUAGE sql STABLE;

-- Clusters without centroid embeddings (recomputed on import).
CREATE OR REPLACE FUNCTION hmx_export_clusters() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'cluster_type', c.cluster_type,
        'name', c.name,
        'member_ids', COALESCE((
            SELECT jsonb_agg(gcm.memory_id)
            FROM get_cluster_members_graph(c.id) gcm
        ), '[]'::jsonb)
    ) ORDER BY c.name, c.id), '[]'::jsonb)
    FROM clusters c;
$$ LANGUAGE sql STABLE;

-- Narrative scaffolding (protected): AGE vertex properties, exported
-- explicitly per subsection.
CREATE OR REPLACE FUNCTION hmx_export_narrative() RETURNS JSONB AS $$
DECLARE
    chapters JSONB;
    turning_points JSONB;
    threads JSONB;
    conflicts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(props::text::jsonb), '[]'::jsonb) INTO chapters
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:LifeChapterNode) RETURN properties(n)
    $q$) AS (props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(props::text::jsonb), '[]'::jsonb) INTO turning_points
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:TurningPointNode) RETURN properties(n)
    $q$) AS (props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(props::text::jsonb), '[]'::jsonb) INTO threads
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:NarrativeThreadNode) RETURN properties(n)
    $q$) AS (props ag_catalog.agtype);

    SELECT COALESCE(jsonb_agg(props::text::jsonb), '[]'::jsonb) INTO conflicts
    FROM ag_catalog.cypher('memory_graph', $q$
        MATCH (n:ValueConflictNode) RETURN properties(n)
    $q$) AS (props ag_catalog.agtype);

    RETURN jsonb_build_object(
        'life_chapters', chapters,
        'turning_points', turning_points,
        'narrative_threads', threads,
        'value_conflicts', conflicts
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Identity (protected): the self-model facets plus the initialized profile.
CREATE OR REPLACE FUNCTION hmx_export_identity() RETURNS JSONB AS $$
DECLARE
    profile JSONB;
    facets JSONB;
BEGIN
    SELECT value->'agent' INTO profile FROM config WHERE key = 'agent.init_profile';
    facets := get_self_model_context(200);
    RETURN jsonb_build_array(jsonb_build_object(
        'key', 'core_identity',
        'content', COALESCE(profile->>'description', ''),
        'profile', COALESCE(profile, '{}'::jsonb),
        'facets', COALESCE(facets, '[]'::jsonb)
    ));
END;
$$ LANGUAGE plpgsql STABLE;

-- In-flight work (port/duplicate): memories-in-becoming.
CREATE OR REPLACE FUNCTION hmx_export_in_flight_work() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'consolidation_tasks', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', t.id,
                'task_type', t.task_type,
                'status', t.status,
                'created_at', t.created_at,
                'updated_at', t.updated_at,
                'input_ids', COALESCE(to_jsonb(t.source_unit_ids), '[]'::jsonb),
                'target_memory_id', t.target_memory_id,
                'attempt_count', t.attempts,
                'properties', COALESCE(t.task_payload, '{}'::jsonb)
            ) ORDER BY t.created_at, t.id)
            FROM recmem_consolidation_tasks t
            WHERE t.status IN ('pending', 'in_progress', 'failed')
        ), '[]'::jsonb),
        'reconsolidation_tasks', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', r.id,
                'status', r.status,
                'memory_ids', CASE WHEN r.belief_id IS NULL THEN '[]'::jsonb
                                   ELSE jsonb_build_array(r.belief_id) END,
                'reason', r.transformation_type,
                'created_at', r.created_at,
                'properties', jsonb_build_object(
                    'old_content', r.old_content,
                    'new_content', r.new_content
                )
            ) ORDER BY r.created_at, r.id)
            FROM reconsolidation_tasks r
            WHERE r.status IN ('pending', 'in_progress', 'failed')
        ), '[]'::jsonb)
    );
$$ LANGUAGE sql STABLE;

-- Audit records: the protected-replacement audit tables arrive with MVP-PR
-- (plan Slice 9). Until then a port carries empty immutable history.
CREATE OR REPLACE FUNCTION hmx_export_audit_records() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'protected_replacement_audit', '[]'::jsonb,
        'protected_section_verified_audit', '[]'::jsonb,
        'protected_replacement_reversion_audit', '[]'::jsonb,
        'transformation_history', '[]'::jsonb
    );
$$ LANGUAGE sql STABLE;

SET check_function_bodies = on;
