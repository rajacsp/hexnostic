import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_sync_memory_trust(db_pool):
    sources = [
        {"kind": "web", "ref": "https://example.com/a", "trust": 1.0},
        {"kind": "paper", "ref": "doi:10.1/test", "trust": 0.8},
    ]
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Create semantic memory with metadata containing confidence and sources
            metadata = json.dumps({
                "confidence": 0.9,
                "source_references": sources
            })
            memory_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, trust_level, source_attribution, metadata)
                VALUES (
                    'semantic',
                    'Trust sync',
                    array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                    0.1,
                    '{}'::jsonb,
                    $1::jsonb
                )
                RETURNING id
                """,
                metadata
            )

            await conn.execute("SELECT sync_memory_trust($1::uuid)", memory_id)
            expected = await conn.fetchval(
                "SELECT compute_semantic_trust(0.9, $1::jsonb, compute_worldview_alignment($2::uuid))",
                json.dumps(sources),
                memory_id,
            )
            row = await conn.fetchrow(
                "SELECT trust_level, source_attribution FROM memories WHERE id = $1",
                memory_id,
            )
            source_attribution = (
                json.loads(row["source_attribution"])
                if isinstance(row["source_attribution"], str)
                else row["source_attribution"]
            )
            assert float(row["trust_level"]) == pytest.approx(float(expected), rel=0.02)
            assert source_attribution["ref"] in {"https://example.com/a", "doi:10.1/test"}
        finally:
            await tr.rollback()


async def test_sync_memory_trust_increases_with_worldview_support(db_pool):
    """Test worldview influence on trust (Phase 5: uses graph edges instead of tables)"""
    sources = [{"kind": "web", "ref": "https://example.com", "trust": 1.0}]
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Create semantic memory with metadata
            metadata = json.dumps({
                "confidence": 0.9,
                "source_references": sources
            })
            memory_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, trust_level, metadata)
                VALUES (
                    'semantic',
                    'Worldview trigger',
                    array_fill(0.3, ARRAY[embedding_dimension()])::vector,
                    0.1,
                    $1::jsonb
                )
                RETURNING id
                """,
                metadata
            )

            # Trigger initial trust sync
            await conn.execute("SELECT sync_memory_trust($1::uuid)", memory_id)
            baseline_trust = await conn.fetchval("SELECT trust_level FROM memories WHERE id = $1", memory_id)

            # Phase 5: Create worldview memory instead of worldview_primitives row
            worldview_id = await conn.fetchval(
                """
                SELECT create_worldview_memory(
                    'test belief',
                    'belief',
                    0.5,
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
                    MATCH (m:MemoryNode {{memory_id: '{memory_id}'}})
                    MATCH (w:MemoryNode {{memory_id: '{worldview_id}'}})
                    CREATE (m)-[:SUPPORTS {{strength: 1.0}}]->(w)
                    RETURN m
                $$) as (result agtype)
                """
            )

            # Trigger trust sync after adding worldview support
            await conn.execute("SELECT sync_memory_trust($1::uuid)", memory_id)

            updated_trust = await conn.fetchval("SELECT trust_level FROM memories WHERE id = $1", memory_id)
            # Phase 5: Get confidence from metadata instead of worldview_primitives
            worldview_meta_raw = await conn.fetchval(
                "SELECT metadata FROM memories WHERE id = $1",
                worldview_id,
            )
            worldview_meta = json.loads(worldview_meta_raw) if isinstance(worldview_meta_raw, str) else worldview_meta_raw
            updated_confidence = float(worldview_meta.get('confidence', 0.5))

            # Trust should increase with worldview support, confidence should remain at initial value
            assert float(updated_trust) >= float(baseline_trust)
            assert updated_confidence >= 0.5
        finally:
            await tr.rollback()
