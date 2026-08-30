-- 0050: Table homecoming (#77 completion) — Hexis tables out of ag_catalog.
--
-- The function strays were evicted in 0043, but seven TABLES created by
-- migrations in the ag_catalog-first era were still living there
-- (channel_deliveries, channel_messages, channel_sessions,
-- schema_migrations, sub_agent_sessions, tool_executions,
-- workflow_executions). Resolution works via search_path, but
-- schema-qualified tooling (dumps, Prisma introspection, backups) sees a
-- split brain. ALTER TABLE ... SET SCHEMA is atomic and moves no data;
-- owned sequences and indexes travel with their tables. AGE's own catalog
-- tables (ag_graph, ag_label) stay home.
SET search_path = public, ag_catalog, "$user";

DO $migration$
DECLARE
    tbl TEXT;
    moved INT := 0;
BEGIN
    FOR tbl IN
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'ag_catalog'
          AND tablename NOT IN ('ag_graph', 'ag_label')
          -- The migration ledger moves in the RUNNER (core/migrations.py):
          -- moving it here pulls the floor out from under the INSERT that
          -- records this very migration.
          AND tablename <> 'schema_migrations'
          AND tablename NOT IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')
    LOOP
        EXECUTE format('ALTER TABLE ag_catalog.%I SET SCHEMA public', tbl);
        RAISE NOTICE 'table homecoming: moved ag_catalog.% to public', tbl;
        moved := moved + 1;
    END LOOP;
    RAISE NOTICE 'table homecoming: % table(s) moved', moved;
END
$migration$;
