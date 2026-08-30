"""Tests for the compression-native memory strength substrate
(db/03 calculate_strength, db/05 touch_memories reinforcement, db/31 recmem
ranking). Part 1 of docs/memory_retention_design.md."""
from __future__ import annotations

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_calculate_strength_decays_and_reinforcement_resets(db_pool):
    async with db_pool.acquire() as conn:
        fresh = await conn.fetchval("SELECT calculate_strength(0.8, 0.05, now(), now())")
        old = await conn.fetchval("SELECT calculate_strength(0.8, 0.05, now() - interval '60 days', NULL)")
        reinforced = await conn.fetchval("SELECT calculate_strength(0.8, 0.05, now() - interval '60 days', now())")
        assert fresh > 0.75                # fresh ~ importance
        assert old < 0.1                   # decays without reinforcement
        assert reinforced > 0.75           # reinforcement resets the decay clock -> back up
        assert reinforced > old            # the up-ladder
        # bounded to (0, 1]
        assert 0.0 <= await conn.fetchval("SELECT calculate_strength(1.0, 0.0, now(), now())") <= 1.0


async def test_touch_memories_reinforces(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding, importance, trust_level, status) "
                "VALUES ('semantic', 'touch probe', array_fill(0.1, ARRAY[embedding_dimension()])::vector, "
                "0.7, 0.9, 'active') RETURNING id"
            )
            await conn.execute("SELECT touch_memories($1::uuid[])", [mid])
            row = await conn.fetchrow(
                "SELECT last_reinforced, reinforcement_count, access_count FROM memories WHERE id=$1", mid)
            assert row["last_reinforced"] is not None
            assert row["reinforcement_count"] == 1
            assert row["access_count"] == 1
        finally:
            await tr.rollback()


async def test_recmem_ranks_strong_above_faded(db_pool):
    """Equal similarity (identical embeddings), different strength -> the strong
    memory outranks the faded one, and fidelity/strength are returned. Needs the
    embedding service (query embedding)."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            faded = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, last_reinforced) "
                "VALUES ('semantic', 'FADED spec', array_fill(0.11, ARRAY[embedding_dimension()])::vector, "
                "0.7, 0.9, 'active', now() - interval '90 days', NULL) RETURNING id")
            strong = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, last_reinforced) "
                "VALUES ('semantic', 'STRONG spec', array_fill(0.11, ARRAY[embedding_dimension()])::vector, "
                "0.7, 0.9, 'active', now(), now()) RETURNING id")
            rows = await conn.fetch(
                "SELECT item_id, score, strength, fidelity FROM recmem_recall_context('the spec', 0, 0, 5, NULL) "
                "WHERE tier='semantic' AND item_id = ANY($1::uuid[]) ORDER BY score DESC",
                [faded, strong])
            assert len(rows) == 2
            assert rows[0]["item_id"] == strong           # strong ranks first
            assert rows[0]["strength"] > rows[1]["strength"]
            assert all(abs(r["fidelity"] - 1.0) < 1e-9 for r in rows)  # uniform until consolidation
        finally:
            await tr.rollback()
