-- 0043: One brain, one schema — evict stale Hexis functions from ag_catalog.
--
-- Older migration runners (and the docker-compose server default
-- search_path=ag_catalog,public) created Hexis functions inside ag_catalog.
-- The modern runner creates/replaces in public, so ag_catalog accumulated
-- STALE copies that shadow their updated public twins for every runtime
-- connection: workers were executing months-old versions of ~30 functions
-- (apply_recmem_episode_create/merge, recmem_recall_context,
-- run_subconscious_maintenance, the HMX digest family, ...) no matter what
-- migrations said. Found live when a retired code path (semantic_refine
-- auto-queue, #57) resurrected during scene-consolidation verification (#73).
--
-- Fix: drop every ag_catalog function whose NAME exists in public — those are
-- all Hexis strays (AGE's own internals have no public twins) — and pin the
-- database default search_path to public-first. docker-compose and the
-- Python/CI connection setup are flipped in the same commit.
SET search_path = public, ag_catalog, "$user";

DO $migration$
DECLARE
    stray RECORD;
    dropped INT := 0;
BEGIN
    FOR stray IN
        SELECT p.proname,
               pg_get_function_identity_arguments(p.oid) AS args,
               p.prokind
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ag_catalog'
          AND EXISTS (
              SELECT 1
              FROM pg_proc p2
              JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
              WHERE n2.nspname = 'public'
                AND p2.proname = p.proname
          )
    LOOP
        -- Fail loud on dependents (no CASCADE): anything still bound to a
        -- stray copy needs a deliberate look, not a silent cascade.
        EXECUTE format(
            'DROP %s IF EXISTS ag_catalog.%I(%s)',
            CASE stray.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
            stray.proname,
            stray.args
        );
        dropped := dropped + 1;
    END LOOP;
    RAISE NOTICE 'one_brain_one_schema: dropped % stray ag_catalog function(s)', dropped;
END
$migration$;

-- Runtime connections resolve public first from now on; ag_catalog stays on
-- the path so AGE (cypher, agtype) keeps working unqualified.
DO $migration$
BEGIN
    EXECUTE format(
        'ALTER DATABASE %I SET search_path = public, ag_catalog, "$user"',
        current_database()
    );
END
$migration$;
