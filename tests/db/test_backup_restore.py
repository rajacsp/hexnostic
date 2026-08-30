"""Round-trip test for AGE-aware backup/restore (core/backup_restore.py): a memory
and the Apache AGE graph survive backup -> restore. Skipped when the host pg client
tools are unavailable."""
from __future__ import annotations

import os
import shutil
from uuid import uuid4

import asyncpg
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_HAS_PG = all(shutil.which(t) for t in ("pg_dump", "pg_restore", "psql"))


@pytest.mark.skipif(not _HAS_PG, reason="host pg_dump/pg_restore/psql not available")
async def test_backup_restore_preserves_memory_and_graph(db_pool):
    from core.agent_api import db_dsn_from_env
    from core.backup_restore import backup, restore

    src_dsn = db_dsn_from_env()  # the module's temp DB (conftest set POSTGRES_DB)
    base = src_dsn.rsplit("/", 1)[0]
    token = f"backup-witness-{uuid4().hex[:8]}"
    async with db_pool.acquire() as conn:
        await conn.execute(
            "INSERT INTO memories (type, content, embedding, importance, trust_level, status) "
            "VALUES ('episodic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.5, 0.9, 'active')",
            token)

    scratch = f"tmp_restore_{uuid4().hex[:8]}"
    scratch_dsn = f"{base}/{scratch}"
    dump = backup(src_dsn, label="test")
    try:
        restore(str(dump), scratch_dsn)  # drops+creates scratch, reloads the dump
        conn = await asyncpg.connect(scratch_dsn)
        try:
            await conn.execute("LOAD 'age'")
            await conn.execute("SET search_path = public, ag_catalog")
            # the row survived
            assert await conn.fetchval("SELECT count(*) FROM memories WHERE content=$1", token) == 1
            # the AGE graph is registered again (the pg_dump AGE gotcha did NOT bite)
            assert await conn.fetchval(
                "SELECT count(*) FROM ag_catalog.ag_graph WHERE name='memory_graph'") == 1
            assert await conn.fetchval("SELECT count(*) FROM ag_catalog.ag_label") > 0
            # and the seeded memory's graph node round-tripped
            assert await conn.fetchval('SELECT count(*) FROM memory_graph."MemoryNode"') >= 1
        finally:
            await conn.close()
    finally:
        try:
            os.remove(dump)
        except OSError:
            pass
        admin = await asyncpg.connect(f"{base}/{os.getenv('POSTGRES_ADMIN_DB', 'postgres')}")
        try:
            await admin.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                f"WHERE datname='{scratch}' AND pid <> pg_backend_pid()")
            await admin.execute(f'DROP DATABASE IF EXISTS "{scratch}"')
        finally:
            await admin.close()
