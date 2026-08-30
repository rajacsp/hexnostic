-- Batch 8: config defaults registry. Active config remains in `config`;
-- defaults live in `config_defaults`, and getters fall back to defaults.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS config_defaults (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL,
    description TEXT,
    source_path TEXT,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO config_defaults (key, value, description) VALUES
    ('heartbeat.base_regeneration', '10'::jsonb, 'Energy regenerated per heartbeat'),
    ('heartbeat.max_energy', '20'::jsonb, 'Maximum energy cap'),
    ('heartbeat.heartbeat_interval_minutes', '60'::jsonb, 'Minutes between heartbeats'),
    ('heartbeat.max_decision_tokens', '2048'::jsonb, 'Max tokens for heartbeat decision'),
    ('heartbeat.allowed_actions', '["observe","review_goals","remember","recall","connect","reprioritize","reflect","contemplate","meditate","study","debate_internally","maintain","mark_turning_point","begin_chapter","close_chapter","acknowledge_relationship","update_trust","reflect_on_relationship","resolve_contradiction","accept_tension","brainstorm_goals","inquire_shallow","synthesize","reach_out_user","inquire_deep","reach_out_public","fast_ingest","slow_ingest","hybrid_ingest","keep_memory","release_memory","journal_memory","pause_heartbeat","terminate","rest"]'::jsonb, 'Allowed heartbeat actions'),
    ('heartbeat.max_active_goals', '3'::jsonb, 'Maximum concurrent active goals'),
    ('heartbeat.goal_stale_days', '7'::jsonb, 'Days before a goal is flagged as stale'),
    ('heartbeat.user_contact_cooldown_hours', '4'::jsonb, 'Minimum hours between unsolicited user contact'),
    ('heartbeat.cost_observe', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_review_goals', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_remember', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_recall', '1'::jsonb, 'Query memory system'),
    ('heartbeat.cost_connect', '1'::jsonb, 'Create graph relationships'),
    ('heartbeat.cost_reprioritize', '1'::jsonb, 'Move goals between priorities'),
    ('heartbeat.cost_reflect', '2'::jsonb, 'Internal reflection'),
    ('heartbeat.cost_contemplate', '1'::jsonb, 'Deliberate contemplation on a belief'),
    ('heartbeat.cost_meditate', '1'::jsonb, 'Quiet reflection/grounding'),
    ('heartbeat.cost_study', '2'::jsonb, 'Structured learning on a belief'),
    ('heartbeat.cost_debate_internally', '2'::jsonb, 'Internal dialectic on a belief'),
    ('heartbeat.cost_maintain', '2'::jsonb, 'Update beliefs, prune'),
    ('heartbeat.cost_mark_turning_point', '2'::jsonb, 'Mark a narrative turning point'),
    ('heartbeat.cost_begin_chapter', '3'::jsonb, 'Start a new life chapter'),
    ('heartbeat.cost_close_chapter', '3'::jsonb, 'Close a life chapter with summary'),
    ('heartbeat.cost_acknowledge_relationship', '2'::jsonb, 'Recognize a relationship'),
    ('heartbeat.cost_update_trust', '2'::jsonb, 'Adjust relationship trust'),
    ('heartbeat.cost_reflect_on_relationship', '3'::jsonb, 'Reflect on a relationship'),
    ('heartbeat.cost_resolve_contradiction', '3'::jsonb, 'Resolve a contradiction'),
    ('heartbeat.cost_accept_tension', '1'::jsonb, 'Acknowledge tension without resolving'),
    ('heartbeat.cost_pursue', '3'::jsonb, 'Multi-step goal action'),
    ('heartbeat.cost_reach_out', '5'::jsonb, 'Initiate contact with user'),
    ('heartbeat.cost_inquire', '4'::jsonb, 'Ask user a question'),
    ('heartbeat.cost_brainstorm_goals', '3'::jsonb, 'Generate new potential goals'),
    ('heartbeat.cost_inquire_shallow', '4'::jsonb, 'Light web research'),
    ('heartbeat.cost_inquire_deep', '6'::jsonb, 'Deep web research'),
    ('heartbeat.cost_reach_out_user', '5'::jsonb, 'Message the user'),
    ('heartbeat.cost_reach_out_public', '7'::jsonb, 'Public outreach'),
    ('heartbeat.cost_synthesize', '3'::jsonb, 'Generate artifact, form conclusion'),
    ('heartbeat.cost_pause_heartbeat', '0'::jsonb, 'Pause heartbeat cycle (temporary)'),
    ('heartbeat.cost_rest', '0'::jsonb, 'Bank remaining energy'),
    ('heartbeat.cost_terminate', '0'::jsonb, 'Terminate agent'),
    ('heartbeat.cost_fast_ingest', '2'::jsonb, 'Fast ingestion - chunk and extract facts'),
    ('heartbeat.cost_slow_ingest', '5'::jsonb, 'Slow ingestion - conscious RLM reading per chunk'),
    ('heartbeat.cost_hybrid_ingest', '3'::jsonb, 'Hybrid ingestion - fast pass then slow on high-signal chunks'),
    ('heartbeat.cost_keep_memory', '2'::jsonb, 'Spend a point to hold a fading memory back from consolidation'),
    ('heartbeat.cost_release_memory', '0'::jsonb, 'Let a fading memory go (free)'),
    ('heartbeat.cost_journal_memory', '3'::jsonb, 'Commit a fading memory to the journal before letting it fade'),
    ('agent.tools', '["recall","sense_memory_availability","request_background_search","recall_recent","recall_episode","explore_concept","explore_cluster","get_procedures","get_strategies","list_recent_episodes","create_goal","schedule_task","list_scheduled_tasks","update_scheduled_task","delete_scheduled_task","queue_user_message"]'::jsonb, 'Allowed tool names for agent tool use'),
    ('maintenance.maintenance_interval_seconds', '60'::jsonb, 'Seconds between subconscious maintenance ticks'),
    ('maintenance.subconscious_enabled', 'false'::jsonb, 'Enable subconscious decider (LLM-based pattern detection)'),
    ('maintenance.subconscious_interval_seconds', '300'::jsonb, 'Seconds between subconscious decider runs'),
    ('maintenance.neighborhood_batch_size', '10'::jsonb, 'How many stale neighborhoods to recompute per tick'),
    ('maintenance.embedding_cache_older_than_days', '7'::jsonb, 'Days before embedding_cache entries are eligible for cleanup'),
    ('maintenance.working_memory_promote_min_importance', '0.75'::jsonb, 'Working-memory items above this importance are promoted on expiry'),
    ('maintenance.working_memory_promote_min_accesses', '3'::jsonb, 'Working-memory items accessed >= this count are promoted on expiry')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = CURRENT_TIMESTAMP;

CREATE OR REPLACE FUNCTION get_config(p_key TEXT)
RETURNS JSONB AS $$
    SELECT COALESCE(
        (SELECT value FROM config WHERE key = p_key),
        (SELECT value FROM config_defaults WHERE key = p_key)
    );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_config_by_prefixes(p_prefixes TEXT[])
RETURNS TABLE (
    key TEXT,
    value JSONB
) AS $$
BEGIN
    IF p_prefixes IS NULL OR array_length(p_prefixes, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    WITH keys AS (
        SELECT c.key
        FROM config c
        WHERE c.key LIKE ANY(ARRAY(SELECT p || '%' FROM unnest(p_prefixes) p))
        UNION
        SELECT d.key
        FROM config_defaults d
        WHERE d.key LIKE ANY(ARRAY(SELECT p || '%' FROM unnest(p_prefixes) p))
    )
    SELECT k.key, COALESCE(c.value, d.value) AS value
    FROM keys k
    LEFT JOIN config c ON c.key = k.key
    LEFT JOIN config_defaults d ON d.key = k.key
    ORDER BY k.key;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_config_text(p_key TEXT)
RETURNS TEXT AS $$
    WITH val AS (
        SELECT get_config(p_key) AS value
    )
    SELECT CASE
        WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}'
        ELSE value::text
    END
    FROM val;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_config_float(p_key TEXT)
RETURNS FLOAT AS $$
    SELECT (get_config(p_key) #>> '{}')::float;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_config_int(p_key TEXT)
RETURNS INT AS $$
    SELECT (get_config(p_key) #>> '{}')::int;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_config_bool(p_key TEXT)
RETURNS BOOLEAN AS $$
    SELECT COALESCE((get_config(p_key) #>> '{}')::boolean, FALSE);
$$ LANGUAGE sql STABLE;
