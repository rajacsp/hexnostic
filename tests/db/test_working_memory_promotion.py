import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_touch_working_memory_updates_access(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            wm_id = await conn.fetchval(
                """
                INSERT INTO working_memory (content, embedding, access_count, last_accessed)
                VALUES (
                    'Touch test',
                    array_fill(0.2, ARRAY[embedding_dimension()])::vector,
                    2,
                    CURRENT_TIMESTAMP - INTERVAL '1 day'
                )
                RETURNING id
                """
            )
            before = await conn.fetchrow(
                "SELECT access_count, last_accessed FROM working_memory WHERE id = $1",
                wm_id,
            )

            await conn.execute("SELECT touch_working_memory($1::uuid[])", [wm_id])

            after = await conn.fetchrow(
                "SELECT access_count, last_accessed FROM working_memory WHERE id = $1",
                wm_id,
            )
            assert int(after["access_count"]) == int(before["access_count"]) + 1
            assert after["last_accessed"] >= before["last_accessed"]
        finally:
            await tr.rollback()


async def test_promote_working_memory_to_episodic(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            wm_id = await conn.fetchval(
                """
                INSERT INTO working_memory (
                    content,
                    embedding,
                    importance,
                    source_attribution,
                    trust_level
                )
                VALUES (
                    $1,
                    array_fill(0.3, ARRAY[embedding_dimension()])::vector,
                    0.3,
                    $2::jsonb,
                    0.6
                )
                RETURNING id
                """,
                "Promote me",
                json.dumps({"kind": "test", "ref": "wm:1"}),
            )

            new_id = await conn.fetchval(
                "SELECT promote_working_memory_to_episodic($1::uuid, 0.8)",
                wm_id,
            )
            assert new_id is not None

            row = await conn.fetchrow(
                "SELECT type, content, importance, trust_level, metadata FROM memories WHERE id = $1",
                new_id,
            )
            assert row["type"] == "episodic"
            assert row["content"] == "Promote me"
            assert float(row["importance"]) == pytest.approx(0.8)
            assert float(row["trust_level"]) == pytest.approx(0.6, rel=0.05)

            # Now read from metadata instead of episodic_memories table
            metadata = row["metadata"]
            if isinstance(metadata, str):
                metadata = json.loads(metadata)
            assert metadata is not None
            context = metadata.get("context", {})
            if isinstance(context, str):
                context = json.loads(context)
            assert context.get("from_working_memory_id") == str(wm_id)
            emotional_valence = metadata.get("emotional_valence", 0.0)
            assert -1.0 <= float(emotional_valence) <= 1.0
        finally:
            await tr.rollback()
