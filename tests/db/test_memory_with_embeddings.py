import json

import asyncpg
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _embedding_list(conn, value):
    dimension = await conn.fetchval("SELECT embedding_dimension()")
    return [value] * int(dimension)


async def test_create_memory_with_embedding(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            memory_id = await conn.fetchval(
                """
                SELECT create_memory_with_embedding(
                    'semantic'::memory_type,
                    $1::text,
                    array_fill(0.02, ARRAY[embedding_dimension()])::vector,
                    0.4,
                    NULL,
                    NULL
                )
                """,
                "Embedded memory",
            )
            assert memory_id is not None

            row = await conn.fetchrow(
                """
                SELECT type, content, importance, trust_level, source_attribution
                FROM memories
                WHERE id = $1
                """,
                memory_id,
            )
            source_attribution = (
                json.loads(row["source_attribution"])
                if isinstance(row["source_attribution"], str)
                else row["source_attribution"]
            )
            assert row["type"] == "semantic"
            assert row["content"] == "Embedded memory"
            assert float(row["importance"]) == pytest.approx(0.4)
            assert float(row["trust_level"]) == pytest.approx(0.2, rel=0.05)
            assert source_attribution["kind"] == "unattributed"

            await conn.execute("LOAD 'age';")
            await conn.execute("SET search_path = public, ag_catalog;")
            node_count = await conn.fetchval(
                f"""
                SELECT COUNT(*) FROM cypher('memory_graph', $$
                    MATCH (n:MemoryNode {{memory_id: '{memory_id}'}})
                    RETURN n
                $$) as (n agtype)
                """
            )
            assert int(node_count) >= 1
        finally:
            await tr.rollback()


async def test_batch_create_memories_with_embeddings(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            embedding = await _embedding_list(conn, 0.03)
            payload = json.dumps([embedding, embedding])
            ids = await conn.fetchval(
                """
                SELECT batch_create_memories_with_embeddings(
                    'semantic'::memory_type,
                    $1::text[],
                    $2::jsonb,
                    0.6
                )
                """,
                ["Batch A", "Batch B"],
                payload,
            )
            assert isinstance(ids, list)
            assert len(ids) == 2

            # Verify memories exist with type 'semantic'
            mem_count = await conn.fetchval(
                "SELECT COUNT(*) FROM memories WHERE id = ANY($1::uuid[]) AND type = 'semantic'",
                ids,
            )
            assert int(mem_count) == 2
        finally:
            await tr.rollback()


async def test_batch_create_memories_with_embeddings_length_mismatch(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            embedding = await _embedding_list(conn, 0.04)
            payload = json.dumps([embedding])
            with pytest.raises(asyncpg.PostgresError):
                await conn.fetchval(
                    """
                    SELECT batch_create_memories_with_embeddings(
                        'semantic'::memory_type,
                        $1::text[],
                        $2::jsonb,
                        0.6
                    )
                    """,
                    ["Only content", "Extra content"],
                    payload,
                )
        finally:
            await tr.rollback()


async def test_batch_create_memories_with_embeddings_dimension_mismatch(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            payload = json.dumps([[0.1, 0.2]])
            with pytest.raises(asyncpg.PostgresError):
                await conn.fetchval(
                    """
                    SELECT batch_create_memories_with_embeddings(
                        'semantic'::memory_type,
                        $1::text[],
                        $2::jsonb,
                        0.6
                    )
                    """,
                    ["Bad embedding"],
                    payload,
                )
        finally:
            await tr.rollback()
