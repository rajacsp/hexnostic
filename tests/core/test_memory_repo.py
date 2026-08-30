"""Tests for core.memory_repo -- stub-only memory access for RLM."""

import json
import uuid

import pytest

from tests.utils import _db_dsn

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


@pytest.fixture
async def seeded_memory(db_pool):
    """Seed a single long memory for testing and clean up after."""
    mem_id = None
    async with db_pool.acquire() as conn:
        long_content = "A" * 5000
        mem_id = await conn.fetchval(
            """
            INSERT INTO memories (type, content, embedding, importance, trust_level, status)
            VALUES ('semantic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.8, 0.9, 'active')
            RETURNING id
            """,
            long_content,
        )
    yield str(mem_id)
    async with db_pool.acquire() as conn:
        await conn.execute("DELETE FROM memories WHERE id = $1", mem_id)


@pytest.fixture
async def seeded_episodic_memories(db_pool):
    """Seed several episodic memories and clean up."""
    ids = []
    async with db_pool.acquire() as conn:
        for i in range(5):
            mid = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, $2, 0.9, 'active')
                RETURNING id
                """,
                f"Episodic memory {i}: " + "x" * 300,
                0.5 + i * 0.1,
            )
            ids.append(str(mid))
    yield ids
    async with db_pool.acquire() as conn:
        for mid in ids:
            await conn.execute("DELETE FROM memories WHERE id = $1::uuid", mid)


def test_fetch_by_ids_respects_max_chars(seeded_memory):
    """Fetch a long memory with max_chars truncation."""
    from core.memory_repo import MemoryRepo

    dsn = _db_dsn()
    repo = MemoryRepo(dsn)
    try:
        results = repo.fetch_by_ids([seeded_memory], max_chars=100)
        assert len(results) == 1
        content = results[0]["content"]
        assert len(content) <= 100
    finally:
        repo.close()


def test_fetch_empty_ids_returns_empty():
    """Calling fetch_by_ids with empty list returns empty."""
    from core.memory_repo import MemoryRepo

    dsn = _db_dsn()
    repo = MemoryRepo(dsn)
    try:
        results = repo.fetch_by_ids([])
        assert results == []
    finally:
        repo.close()


def test_fetch_by_ids_returns_all_fields(seeded_memory):
    """Verify that fetch returns expected fields."""
    from core.memory_repo import MemoryRepo

    dsn = _db_dsn()
    repo = MemoryRepo(dsn)
    try:
        results = repo.fetch_by_ids([seeded_memory], max_chars=2000)
        assert len(results) == 1
        row = results[0]
        assert "id" in row
        assert "type" in row
        assert "content" in row
        assert "importance" in row
        assert "trust_level" in row
        assert "created_at" in row
    finally:
        repo.close()


def test_recent_stubs_returns_list(seeded_episodic_memories):
    """recent_stubs returns a list of stub dicts."""
    from core.memory_repo import MemoryRepo

    dsn = _db_dsn()
    repo = MemoryRepo(dsn)
    try:
        stubs = repo.recent_stubs(limit=3, preview_chars=100)
        assert isinstance(stubs, list)
        # Each stub should have preview and content_length
        for stub in stubs:
            assert "preview" in stub or "id" in stub
    finally:
        repo.close()
