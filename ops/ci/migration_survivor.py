#!/usr/bin/env python3
"""CI proof that an existing Hexis database survives schema migration.

This intentionally starts from the database already baked into the published
``hexis-brain`` image, inserts durable state, runs the same migration runner used
by the CLI/API/workers, and verifies the state is still present afterward.

As release tags accrue, CI can run this script against older image tags too. For
now it is tolerant of ``latest`` already containing some schema changes: the
load-bearing invariant is data survival + idempotent forward migration.
"""
from __future__ import annotations

import asyncio
import os
from uuid import uuid4

import asyncpg

from core.migrations import apply_pending_migrations, migration_status


def _dsn() -> str:
    host = os.getenv("POSTGRES_HOST", "127.0.0.1")
    port = os.getenv("POSTGRES_PORT", "5432")
    user = os.getenv("POSTGRES_USER", "hexis_user")
    password = os.getenv("POSTGRES_PASSWORD", "hexis_password")
    db = os.getenv("POSTGRES_DB", "hexis_memory")
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"


async def _prepare(conn: asyncpg.Connection) -> None:
    try:
        await conn.execute("LOAD 'age'")
    except Exception:
        pass
    await conn.execute("SET search_path = public, ag_catalog")


async def _insert_sentinel(conn: asyncpg.Connection, content: str) -> None:
    await conn.execute(
        """
        INSERT INTO memories (type, content, embedding, importance, trust_level, status)
        VALUES (
            'episodic',
            $1,
            array_fill(0.123, ARRAY[embedding_dimension()])::vector,
            0.5,
            0.9,
            'active'
        )
        """,
        content,
    )


async def main() -> None:
    sentinel = f"ci migration survivor {uuid4()}"
    conn = await asyncpg.connect(_dsn())
    try:
        await _prepare(conn)
        before = await migration_status(conn)
        print(f"migration status before: {before}")

        await _insert_sentinel(conn, sentinel)
        before_count = await conn.fetchval("SELECT count(*) FROM memories WHERE content=$1", sentinel)
        if before_count != 1:
            raise AssertionError("sentinel memory was not inserted")

        applied = await apply_pending_migrations(conn)
        print(f"applied migrations: {applied}")
        await _prepare(conn)

        after_count = await conn.fetchval("SELECT count(*) FROM memories WHERE content=$1", sentinel)
        if after_count != 1:
            raise AssertionError("sentinel memory did not survive migrations")

        after = await migration_status(conn)
        print(f"migration status after: {after}")
        if after["pending"]:
            raise AssertionError(f"migrations still pending after apply: {after['pending']}")

        if await apply_pending_migrations(conn) != []:
            raise AssertionError("migration runner is not idempotent")

        # Canonical schema (#77): after any apply, no ag_catalog function may
        # shadow a public twin — the runner's postcondition must have evicted
        # every stray.
        shadow_count = await conn.fetchval(
            """
            SELECT count(*) FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'ag_catalog'
              AND EXISTS (
                  SELECT 1 FROM pg_proc p2
                  JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
                  WHERE n2.nspname = 'public' AND p2.proname = p.proname
              )
            """
        )
        if shadow_count:
            raise AssertionError(
                f"{shadow_count} ag_catalog function(s) shadow public after migrate (#77)"
            )

        if await conn.fetchval("SELECT 'staged'::memory_status::text") != "staged":
            raise AssertionError("HMX memory_status enum delta is not usable")
        if await conn.fetchval("SELECT 'SUPERSEDES'::graph_edge_type::text") != "SUPERSEDES":
            raise AssertionError("HMX graph_edge_type enum delta is not usable")
        if not await conn.fetchval("SELECT value IS NOT NULL FROM config WHERE key='agent.lineage_id'"):
            raise AssertionError("agent.lineage_id config was not created")

        age_label = await conn.fetchval(
            "SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_label WHERE name='SUPERSEDES')"
        )
        if age_label is not True:
            raise AssertionError("SUPERSEDES AGE edge label is missing")

        # When the provenance backfill lands in this run, it must classify the
        # pre-existing sentinel as lived experience. (Skipped if the image
        # already carried 0003 — its backfill ran before the sentinel existed.)
        if "0003_hmx_bootstrap_provenance" in applied:
            mode = await conn.fetchval(
                "SELECT metadata->'provenance'->>'acquisition_mode' FROM memories WHERE content=$1",
                sentinel,
            )
            if mode != "experienced":
                raise AssertionError(
                    f"provenance backfill did not classify the sentinel (got {mode!r})"
                )

        print("migration survivor proof passed")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
