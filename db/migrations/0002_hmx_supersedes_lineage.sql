-- HMX Slice 0 (schema half): the SUPERSEDES AGE edge label + a stable lineage id.
-- Transactional and idempotent.

-- Canonical supersession edges in the memory_graph (guarded: no-op if it exists).
DO $$
BEGIN
    PERFORM create_elabel('memory_graph', 'SUPERSEDES');
EXCEPTION WHEN OTHERS THEN
    NULL;  -- label already registered
END $$;

-- Lineage id: established once at birth, propagated on port/duplicate (HMX).
INSERT INTO config (key, value, description)
VALUES ('agent.lineage_id', to_jsonb(gen_random_uuid()::text),
        'Stable identity lineage id (HMX): established at birth, propagated on port/duplicate')
ON CONFLICT (key) DO NOTHING;
