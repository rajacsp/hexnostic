-- 0044: Turn retention on (#74, RecMem Rev 5 Phase 2).
--
-- The compression-native fade ladder (db/47: consolidate aged low-strength
-- episodic groups -> LLM gist with fidelity tracking -> distill lessons
-- upward -> archive -> grace-window prune) has been implemented and tested
-- since it merged, and shipped dark. With scenes (#73) feeding it, it is the
-- day->week grain of the memory hierarchy, so it goes live.
--
-- CALLED OUT: this flips retention on for existing installs on upgrade.
-- Guards that make that safe: nothing younger than retention.min_age_days
-- (30) is touched; protected classes (worldview/goals, importance>=0.85,
-- intense/valenced, pinned, ingested docs) are exempt; borderline cases
-- escalate to the conscious heartbeat for veto; originals survive
-- prune_grace_days (14) as the undo window; capacity pruning stays off
-- (retention.capacity=0); user documents only fade with explicit approval.
-- retention.enabled remains the kill switch.
SET search_path = public, ag_catalog, "$user";

UPDATE config
SET value = 'true'::jsonb,
    description = 'Master switch for rest-cycle memory consolidation + pruning (kill switch)'
WHERE key = 'retention.enabled';
