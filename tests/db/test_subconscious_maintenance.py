import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_run_subconscious_maintenance(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            payload = json.dumps(
                {
                    "working_memory_promote_min_importance": 0.9,
                    "working_memory_promote_min_accesses": 5,
                    "neighborhood_batch_size": 1,
                    "embedding_cache_older_than_days": 0,
                }
            )
            result_raw = await conn.fetchval(
                "SELECT run_subconscious_maintenance($1::jsonb)",
                payload,
            )
            result = json.loads(result_raw) if isinstance(result_raw, str) else result_raw
            assert result.get("success") is True
            assert "working_memory" in result
            assert "neighborhoods_recomputed" in result
            assert "embedding_cache_deleted" in result

            last_run = await conn.fetchval(
                "SELECT last_maintenance_at FROM maintenance_state WHERE id = 1"
            )
            assert last_run is not None
        finally:
            await tr.rollback()
