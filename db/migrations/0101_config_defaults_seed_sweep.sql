-- Move broad feature defaults into the fallback registry for existing
-- databases. Active config rows are preserved as operator overrides; fresh
-- databases seed these keys directly into config_defaults from db/*.sql.

SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS config_defaults (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL,
    description TEXT,
    source_path TEXT,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO config_defaults (key, value, description, source_path)
SELECT c.key, c.value, c.description, 'db/migrations/0101_config_defaults_seed_sweep.sql'
FROM config c
WHERE (
       c.key LIKE 'memory.%'
    OR c.key LIKE 'retention.%'
    OR c.key LIKE 'rlm.%'
    OR c.key LIKE 'transformation.%'
    OR c.key LIKE 'emotion.%'
    OR c.key LIKE 'skills.self_improvement.%'
    OR c.key LIKE 'metamemory.%'
    OR c.key LIKE 'incubation.%'
    OR c.key LIKE 'origin_memories.%'
    OR c.key LIKE 'inspection.%'
    OR c.key LIKE 'belief.%'
    OR c.key LIKE 'guardrails.action_claims.%'
    OR c.key LIKE 'subconscious.%'
    OR c.key LIKE 'ingest.%'
    OR c.key LIKE 'continuity.%'
    OR c.key LIKE 'channel.web_inbox.%'
    OR c.key = 'channel.broadcast_window_days'
    OR c.key = 'agent.tools'
    OR c.key = 'tools'
    OR c.key = 'llm.recmem'
    OR c.key = 'llm.summarization'
    OR c.key = 'llm.skill_improvement'
    OR c.key = 'chat.use_rlm'
    OR c.key = 'heartbeat.use_rlm'
    OR c.key LIKE 'heartbeat.cost_%'
    OR c.key IN (
        'heartbeat.base_regeneration',
        'heartbeat.max_energy',
        'heartbeat.heartbeat_interval_minutes',
        'heartbeat.max_decision_tokens',
        'heartbeat.allowed_actions',
        'heartbeat.max_active_goals',
        'heartbeat.goal_stale_days',
        'heartbeat.user_contact_cooldown_hours',
        'heartbeat.task_energy_multiplier',
        'heartbeat.base_timeout_seconds',
        'heartbeat.task_timeout_seconds',
        'heartbeat.base_max_tokens',
        'heartbeat.task_max_tokens'
    )
    OR c.key LIKE 'maintenance.%'
)
ON CONFLICT (key) DO NOTHING;
