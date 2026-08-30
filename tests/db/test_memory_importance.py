from __future__ import annotations

import asyncpg
import pytest

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def test_repeated_recall_cannot_inflate_importance_past_one(db_pool, ensure_embedding_service):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            memory_id = await conn.fetchval(
                "SELECT create_semantic_memory($1, 0.8, ARRAY['importance-bound'])",
                "A repeatedly recalled test memory",
            )
            for _ in range(30):
                await conn.fetchval("SELECT touch_memories(ARRAY[$1::uuid])", memory_id)

            importance = await conn.fetchval("SELECT importance FROM memories WHERE id = $1", memory_id)
            assert 0.0 <= float(importance) <= 1.0

            with pytest.raises(asyncpg.CheckViolationError):
                await conn.execute("UPDATE memories SET importance = 1.1 WHERE id = $1", memory_id)
        finally:
            await transaction.rollback()
