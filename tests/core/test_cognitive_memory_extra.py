import pytest

from core.cognitive_memory_api import (
    CognitiveMemory,
    MemoryInput,
    MemoryType,
    RelationshipInput,
    RelationshipType,
)
from tests.utils import _db_dsn, get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.core]


@pytest.fixture(scope="module")
async def mem_client(ensure_embedding_service):
    client = await CognitiveMemory.create(_db_dsn(), min_size=1, max_size=5)
    yield client
    await client.close()


async def test_recall_recent_filters_by_type(mem_client, db_pool):
    test_id = get_test_identifier("recent_type")
    sem_id = await mem_client.remember(f"Sem {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    epi_id = await mem_client.remember(f"Epi {test_id}", type=MemoryType.EPISODIC, importance=0.6)
    try:
        rows = await mem_client.recall_recent(limit=5, memory_type=MemoryType.EPISODIC)
        assert any(m.id == epi_id for m in rows)
        assert all(m.type == MemoryType.EPISODIC for m in rows)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", sem_id)
            await conn.execute("DELETE FROM memories WHERE id = $1", epi_id)


async def test_list_recent_episodes_and_recall_episode(mem_client, db_pool):
    test_id = get_test_identifier("episodes")
    mid = await mem_client.remember(f"Episode {test_id}", type=MemoryType.EPISODIC, importance=0.6)
    try:
        episodes = await mem_client.list_recent_episodes(limit=5)
        assert episodes
        async with db_pool.acquire() as conn:
            episode_id = await conn.fetchval(
                """
                SELECT e.id
                FROM episodes e
                CROSS JOIN LATERAL find_episode_memories_graph(e.id) fem
                WHERE fem.memory_id = $1
                ORDER BY e.started_at DESC
                LIMIT 1
                """,
                mid,
            )
        memories = await mem_client.recall_episode(episode_id)
        assert any(m.id == mid for m in memories)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)


async def test_remember_batch_and_link_concepts(mem_client, db_pool):
    """Test remember_batch creates memories and links concepts in graph.
    Phase 2 (ReduceScopeCreep): Concepts are now graph-only.
    """
    test_id = get_test_identifier("batch")
    items = [
        MemoryInput(content=f"Batch A {test_id}", type=MemoryType.SEMANTIC, importance=0.6, concepts=[f"C_{test_id}"]),
        MemoryInput(content=f"Batch B {test_id}", type=MemoryType.EPISODIC, importance=0.5),
    ]
    ids = await mem_client.remember_batch(items)
    assert len(ids) == 2
    try:
        # Verify concept was linked in graph
        async with db_pool.acquire() as conn:
            await conn.execute("LOAD 'age';")
            await conn.execute("SET search_path = public, ag_catalog;")
            edge_count = await conn.fetchval(f"""
                SELECT COUNT(*) FROM cypher('memory_graph', $$
                    MATCH (m:MemoryNode {{memory_id: '{ids[0]}'}})-[:INSTANCE_OF]->(c:ConceptNode {{name: 'C_{test_id}'}})
                    RETURN c
                $$) as (c agtype)
            """)
            assert int(edge_count) >= 1, "Concept should be linked in graph"
    finally:
        # Note: concepts table removed in Phase 2 - concepts are now graph-only
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = ANY($1::uuid[])", ids)


async def test_connect_batch_and_find_causes(mem_client, db_pool):
    test_id = get_test_identifier("causes")
    a = await mem_client.remember(f"A {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    b = await mem_client.remember(f"B {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    c = await mem_client.remember(f"C {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    try:
        await mem_client.connect_batch(
            [
                RelationshipInput(from_id=a, to_id=b, relationship_type=RelationshipType.CAUSES),
                RelationshipInput(from_id=b, to_id=c, relationship_type=RelationshipType.CAUSES),
            ]
        )
        rows = await mem_client.find_causes(c, depth=3)
        assert any(str(r.get("cause_id")) == str(a) for r in rows)
    finally:
        # Note: relationship_discoveries table removed in Phase 8 - only graph edges now
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = ANY($1::uuid[])", [a, b, c])


async def test_find_contradictions(mem_client, db_pool):
    test_id = get_test_identifier("contradict")
    a = await mem_client.remember(f"X {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    b = await mem_client.remember(f"Not X {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    try:
        await mem_client.connect_memories(a, b, RelationshipType.CONTRADICTS, confidence=0.9, context="test")
        rows = await mem_client.find_contradictions(a)
        assert rows
    finally:
        # Note: relationship_discoveries table removed in Phase 8 - only graph edges now
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = ANY($1::uuid[])", [a, b])


async def test_find_supporting_evidence(mem_client, db_pool):
    """Test find_supporting_evidence with worldview memories."""
    test_id = get_test_identifier("supporting")
    async with db_pool.acquire() as conn:
        worldview_id = await conn.fetchval(
            "SELECT create_worldview_memory($1, 'belief', 0.9, 0.8, 0.8, 'test')",
            f"Belief {test_id}",
        )

    mem_id = await mem_client.remember(f"Evidence {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    try:
        await mem_client.connect_memories(mem_id, worldview_id, RelationshipType.SUPPORTS, confidence=0.9)
        async with db_pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM find_supporting_evidence($1)", worldview_id)
        assert any(r["memory_id"] == mem_id for r in rows)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = ANY($1::uuid[])", [mem_id, worldview_id])


async def test_touch_memories_updates_access_count(mem_client, db_pool):
    test_id = get_test_identifier("touch")
    mid = await mem_client.remember(f"Touch {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    try:
        await mem_client.touch_memories([mid])
        async with db_pool.acquire() as conn:
            count = await conn.fetchval("SELECT access_count FROM memories WHERE id = $1", mid)
        assert int(count) >= 1
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)


async def test_get_emotional_state_shape(mem_client):
    state = await mem_client.get_emotional_state()
    assert state is None or isinstance(state, dict)
