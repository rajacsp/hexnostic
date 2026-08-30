"""HMX Slice 0: schema prerequisites for the memory-exchange format (plans/hmx.md).

Covers the enum/lineage half (migrations 0001/0002) and the bootstrap-provenance
half (migration 0003): init-created memories are tagged acquisition_mode=bootstrap
plus replaceable_during_bootstrap at creation, deliberately-transformed rows read
as experienced, and hmx_backfill_provenance() classifies legacy rows the same way.
"""
from __future__ import annotations

import json
import uuid

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_SEED_SQL = """
    INSERT INTO memories (type, content, embedding, importance, trust_level, status,
                          metadata, source_attribution)
    VALUES ($1, $2, array_fill(0.1, ARRAY[embedding_dimension()])::vector,
            0.8, 0.9, 'active', $3::jsonb, $4::jsonb)
    RETURNING id
"""


async def _seed(conn, *, metadata: dict | None = None, source: dict | None = None) -> uuid.UUID:
    return await conn.fetchval(
        _SEED_SQL,
        "semantic",
        f"hmx slice0 test memory {uuid.uuid4().hex}",
        json.dumps(metadata or {}),
        json.dumps(source or {}),
    )


async def _provenance(conn, mem_id: uuid.UUID) -> dict:
    row = await conn.fetchrow("SELECT metadata FROM memories WHERE id = $1", mem_id)
    return json.loads(row["metadata"]) if isinstance(row["metadata"], str) else row["metadata"]


class TestSchemaPrerequisites:
    async def test_memory_status_includes_staged(self, db_pool):
        async with db_pool.acquire() as conn:
            labels = {
                r["enumlabel"]
                for r in await conn.fetch(
                    "SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid "
                    "WHERE t.typname = 'memory_status'"
                )
            }
            assert "staged" in labels
            # The value is usable, not just registered
            assert await conn.fetchval("SELECT 'staged'::memory_status::text") == "staged"

    async def test_graph_edge_type_synced_with_age(self, db_pool):
        async with db_pool.acquire() as conn:
            labels = {
                r["enumlabel"]
                for r in await conn.fetch(
                    "SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid "
                    "WHERE t.typname = 'graph_edge_type'"
                )
            }
            assert {"SUPERSEDES", "CONTAINS", "HAS_BELIEF", "MEMBER_OF"} <= labels

            age_edges = {
                r["name"]
                for r in await conn.fetch(
                    "SELECT name FROM ag_catalog.ag_label "
                    "WHERE graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = 'memory_graph') "
                    "AND kind = 'e'"
                )
            }
            assert "SUPERSEDES" in age_edges

    async def test_lineage_id_exists_and_is_uuid(self, db_pool):
        async with db_pool.acquire() as conn:
            raw = await conn.fetchval("SELECT value FROM config WHERE key = 'agent.lineage_id'")
            assert raw is not None
            lineage = json.loads(raw) if isinstance(raw, str) else raw
            uuid.UUID(str(lineage))  # raises if malformed


class TestBootstrapProvenanceTrigger:
    async def test_init_created_memory_tagged_bootstrap_on_insert(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(conn, metadata={"origin": "initialization"})
                meta = await _provenance(conn, mem_id)
                assert meta["provenance"]["acquisition_mode"] == "bootstrap"
                assert meta["replaceable_during_bootstrap"] is True
            finally:
                await tr.rollback()

    async def test_source_attribution_marker_also_tags(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(conn, source={"source": "initialization"})
                meta = await _provenance(conn, mem_id)
                assert meta["provenance"]["acquisition_mode"] == "bootstrap"
            finally:
                await tr.rollback()

    async def test_marker_added_by_update_tags_like_init_goals(self, db_pool):
        """init_goals() creates goals first and marks origin=initialization in a
        follow-up UPDATE; the tag must land on that path too."""
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(conn)
                assert "provenance" not in await _provenance(conn, mem_id)
                await conn.execute(
                    "UPDATE memories SET metadata = metadata || '{\"origin\": \"initialization\"}'::jsonb "
                    "WHERE id = $1",
                    mem_id,
                )
                meta = await _provenance(conn, mem_id)
                assert meta["provenance"]["acquisition_mode"] == "bootstrap"
                assert meta["replaceable_during_bootstrap"] is True
            finally:
                await tr.rollback()

    async def test_ordinary_memory_left_untagged(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(conn, metadata={"topic": "coffee"})
                assert "provenance" not in await _provenance(conn, mem_id)
            finally:
                await tr.rollback()

    async def test_transformed_init_memory_reads_experienced(self, db_pool):
        """A deliberately-transformed belief (non-empty change_history) is earned
        state, not bootstrap — even if it still carries the init marker."""
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(
                    conn,
                    metadata={
                        "origin": "initialization",
                        "change_history": [{"changed_at": "2026-01-01", "kind": "core_value"}],
                    },
                )
                meta = await _provenance(conn, mem_id)
                assert meta["provenance"]["acquisition_mode"] == "experienced"
                assert "replaceable_during_bootstrap" not in meta
            finally:
                await tr.rollback()

    async def test_existing_provenance_never_overwritten(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                mem_id = await _seed(
                    conn,
                    metadata={
                        "origin": "initialization",
                        "provenance": {"acquisition_mode": "experienced"},
                    },
                )
                # Touch the row; the WHEN clause must not re-fire
                await conn.execute(
                    "UPDATE memories SET importance = 0.9 WHERE id = $1", mem_id
                )
                meta = await _provenance(conn, mem_id)
                assert meta["provenance"]["acquisition_mode"] == "experienced"
            finally:
                await tr.rollback()


class TestBackfill:
    async def test_backfill_classifies_legacy_rows(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                # Simulate rows that predate the trigger
                await conn.execute(
                    "ALTER TABLE memories DISABLE TRIGGER trg_hmx_bootstrap_provenance"
                )
                pristine = await _seed(conn, metadata={"origin": "initialization"})
                transformed = await _seed(
                    conn,
                    metadata={
                        "origin": "initialization",
                        "change_history": [{"changed_at": "2026-01-01"}],
                    },
                )
                lived = await _seed(conn, metadata={"topic": "coffee"})
                await conn.execute(
                    "ALTER TABLE memories ENABLE TRIGGER trg_hmx_bootstrap_provenance"
                )

                counts_raw = await conn.fetchval("SELECT hmx_backfill_provenance()")
                counts = json.loads(counts_raw) if isinstance(counts_raw, str) else counts_raw
                assert counts["bootstrap"] >= 1
                assert counts["experienced_from_init"] >= 1
                assert counts["experienced"] >= 1

                meta = await _provenance(conn, pristine)
                assert meta["provenance"]["acquisition_mode"] == "bootstrap"
                assert meta["replaceable_during_bootstrap"] is True

                meta = await _provenance(conn, transformed)
                assert meta["provenance"]["acquisition_mode"] == "experienced"
                assert "replaceable_during_bootstrap" not in meta

                meta = await _provenance(conn, lived)
                assert meta["provenance"]["acquisition_mode"] == "experienced"

                # Idempotent: a second run finds nothing left to classify
                again_raw = await conn.fetchval("SELECT hmx_backfill_provenance()")
                again = json.loads(again_raw) if isinstance(again_raw, str) else again_raw
                assert again == {"bootstrap": 0, "experienced_from_init": 0, "experienced": 0}
            finally:
                await tr.rollback()
