-- 0035: Origin memories and conscious-episode extraction are ON by default.
-- These are core memory-system behavior, not options: an agent that does not
-- know its origin or form memories of what it experiences reproduces issues
-- #37/#40. The flags briefly defaulted to false while 0032/0033 were in
-- development; this flips any value seeded during that window. The flags
-- remain as kill switches (CI, cost control, custom personas) — operators who
-- want them off can set false again; this migration runs exactly once.
SET search_path = public, ag_catalog, "$user";

UPDATE config SET value = 'true'::jsonb
WHERE key IN ('origin_memories.enabled', 'extraction.enabled')
  AND value = 'false'::jsonb;
