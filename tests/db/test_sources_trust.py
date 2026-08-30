import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_normalize_source_reference(db_pool):
    source = {"kind": "web", "ref": "http://example.com", "trust": 1.5}
    async with db_pool.acquire() as conn:
        raw = await conn.fetchval("SELECT normalize_source_reference($1::jsonb)", json.dumps(source))
        normalized = json.loads(raw) if isinstance(raw, str) else raw
        assert normalized["kind"] == "web"
        assert normalized["ref"] == "http://example.com"
        assert normalized["trust"] == 1.0
        assert "observed_at" in normalized

        empty = await conn.fetchval("SELECT normalize_source_reference('[]'::jsonb)")
        empty_val = json.loads(empty) if isinstance(empty, str) else empty
        assert empty_val == {}


async def test_normalize_and_dedupe_sources(db_pool):
    sources = [
        {"kind": "paper", "ref": "doi:1", "observed_at": "2020-01-01T00:00:00Z", "trust": 0.7},
        {"kind": "paper", "ref": "doi:1", "observed_at": "2021-01-01T00:00:00Z", "trust": 0.9},
    ]
    async with db_pool.acquire() as conn:
        raw = await conn.fetchval("SELECT normalize_source_references($1::jsonb)", json.dumps(sources))
        normalized = json.loads(raw) if isinstance(raw, str) else raw
        assert len(normalized) == 2

        raw = await conn.fetchval("SELECT dedupe_source_references($1::jsonb)", json.dumps(sources))
        deduped = json.loads(raw) if isinstance(raw, str) else raw
        assert len(deduped) == 1
        assert deduped[0]["observed_at"].startswith("2021-01-01")


async def test_source_reinforcement_score(db_pool):
    async with db_pool.acquire() as conn:
        zero = await conn.fetchval("SELECT source_reinforcement_score('[]'::jsonb)")
        assert float(zero) == 0.0

        sources = [{"kind": "web", "ref": "a", "trust": 0.9}, {"kind": "web", "ref": "b", "trust": 0.9}]
        score = await conn.fetchval("SELECT source_reinforcement_score($1::jsonb)", json.dumps(sources))
        assert 0.0 < float(score) <= 1.0


async def test_compute_semantic_trust(db_pool):
    sources = [{"kind": "web", "ref": "a", "trust": 0.9}, {"kind": "web", "ref": "b", "trust": 0.9}]
    async with db_pool.acquire() as conn:
        trust = await conn.fetchval(
            "SELECT compute_semantic_trust(0.9, $1::jsonb, 0.5)",
            json.dumps(sources),
        )
        assert 0.0 < float(trust) <= 1.0


async def test_worldview_alignment_and_trust_sync(db_pool):
    """Test worldview alignment and trust sync (Phase 5: uses graph instead of worldview_primitives)"""
    async with db_pool.acquire() as conn:
        mem_id = await conn.fetchval(
            """
            SELECT create_semantic_memory(
                $1::text,
                0.8::float,
                NULL,
                NULL,
                $2::jsonb,
                0.5,
                NULL,
                NULL
            )
            """,
            "Trust test",
            json.dumps([{"kind": "web", "ref": "a", "trust": 0.5}]),
        )

        # Phase 5: Create worldview memory instead of worldview_primitives row
        worldview_id = await conn.fetchval(
            """
            SELECT create_worldview_memory(
                'test belief',
                'belief',
                0.6,
                0.7,
                0.8,
                'discovered'
            )
            """
        )

        # Phase 5: Link via graph edge instead of worldview_memory_influences
        await conn.execute("LOAD 'age';")
        await conn.execute("SET search_path = public, ag_catalog;")
        await conn.execute(
            f"""
            SELECT * FROM cypher('memory_graph', $$
                MATCH (m:MemoryNode {{memory_id: '{mem_id}'}})
                MATCH (w:MemoryNode {{memory_id: '{worldview_id}'}})
                CREATE (m)-[:SUPPORTS {{strength: 1.0}}]->(w)
                RETURN m
            $$) as (result agtype)
            """
        )

        alignment = await conn.fetchval("SELECT compute_worldview_alignment($1::uuid)", mem_id)
        assert 0.0 <= float(alignment) <= 1.0

        profile_raw = await conn.fetchval("SELECT get_memory_truth_profile($1::uuid)", mem_id)
        profile = json.loads(profile_raw) if isinstance(profile_raw, str) else profile_raw
        assert profile["type"] == "semantic"
        assert profile["source_count"] >= 1

        # Trigger trust sync via update to metadata source_references.
        await conn.execute(
            "UPDATE memories SET metadata = metadata || jsonb_build_object('source_references', $1::jsonb) WHERE id = $2",
            json.dumps([{"kind": "paper", "ref": "b", "trust": 0.9}]),
            mem_id,
        )
        await conn.execute("SELECT sync_memory_trust($1::uuid)", mem_id)
        trust = await conn.fetchval("SELECT trust_level FROM memories WHERE id = $1", mem_id)
        assert trust is not None

        # Cleanup
        await conn.execute("DELETE FROM memories WHERE id = $1", worldview_id)
        await conn.execute("DELETE FROM memories WHERE id = $1", mem_id)


async def test_update_worldview_confidence_from_influences(db_pool):
    """Test worldview confidence updates from supporting evidence (Phase 5: uses graph)"""
    async with db_pool.acquire() as conn:
        # Phase 5: Create worldview memory instead of worldview_primitives row
        worldview_id = await conn.fetchval(
            """
            SELECT create_worldview_memory(
                'test belief',
                'belief',
                0.4,
                0.7,
                0.8,
                'discovered'
            )
            """
        )
        mem_id = await conn.fetchval(
            "INSERT INTO memories (type, content, embedding, trust_level) VALUES ('semantic', 'evidence', array_fill(0.1, ARRAY[embedding_dimension()])::vector, 1.0) RETURNING id"
        )

        # Phase 5: Link via graph edge instead of worldview_memory_influences
        await conn.execute("LOAD 'age';")
        await conn.execute("SET search_path = public, ag_catalog;")
        await conn.execute(
            f"""
            SELECT * FROM cypher('memory_graph', $$
                MATCH (m:MemoryNode {{memory_id: '{mem_id}'}})
                MATCH (w:MemoryNode {{memory_id: '{worldview_id}'}})
                CREATE (m)-[:SUPPORTS {{strength: 1.0}}]->(w)
                RETURN m
            $$) as (result agtype)
            """
        )

        # Get confidence from metadata before update
        before_raw = await conn.fetchval("SELECT metadata FROM memories WHERE id = $1", worldview_id)
        before_meta = json.loads(before_raw) if isinstance(before_raw, str) else before_raw
        before = float(before_meta.get('confidence', 0.4))

        await conn.execute("SELECT update_worldview_confidence_from_influences($1::uuid)", worldview_id)

        # Get confidence from metadata after update
        after_raw = await conn.fetchval("SELECT metadata FROM memories WHERE id = $1", worldview_id)
        after_meta = json.loads(after_raw) if isinstance(after_raw, str) else after_raw
        after = float(after_meta.get('confidence', 0.4))
        assert after >= before

        await conn.execute("DELETE FROM memories WHERE id = $1", worldview_id)
        await conn.execute("DELETE FROM memories WHERE id = $1", mem_id)
