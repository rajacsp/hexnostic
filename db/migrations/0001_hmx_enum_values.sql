-- migrate:no-transaction
-- HMX Slice 0 (schema half): sync enums with the memory-exchange format + AGE labels.
-- `ALTER TYPE ... ADD VALUE` cannot run inside a transaction block, so this migration
-- is applied statement-by-statement in autocommit. Every statement is additive and
-- idempotent (IF NOT EXISTS), so it is a safe no-op on databases that already have it.
ALTER TYPE memory_status ADD VALUE IF NOT EXISTS 'staged';
ALTER TYPE graph_edge_type ADD VALUE IF NOT EXISTS 'SUPERSEDES';
ALTER TYPE graph_edge_type ADD VALUE IF NOT EXISTS 'CONTAINS';
ALTER TYPE graph_edge_type ADD VALUE IF NOT EXISTS 'HAS_BELIEF';
ALTER TYPE graph_edge_type ADD VALUE IF NOT EXISTS 'MEMBER_OF';
