import pytest

from services.memory_embeddings import run_memory_embed_step
from tests.utils import get_test_identifier


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_memory_creation_defers_embedding_until_worker(db_pool):
    marker = get_test_identifier("memory-embeddings")
    async with db_pool.acquire() as conn:
        memory_id = await conn.fetchval(
            """
            SELECT create_semantic_memory(
                p_content := $1::text,
                p_confidence := 0.72,
                p_category := ARRAY['test']::text[],
                p_related_concepts := ARRAY['async embedding lifecycle']::text[],
                p_source_references := jsonb_build_array(jsonb_build_object('kind', 'test', 'ref', $2::text)),
                p_importance := 0.6,
                p_source_attribution := jsonb_build_object('kind', 'test', 'ref', $2::text),
                p_trust_level := 0.8
            )
            """,
            f"{marker}: durable memories are embedded asynchronously",
            marker,
        )

        row = await conn.fetchrow(
            """
            SELECT embedding IS NULL AS embedding_missing,
                   embedding_status,
                   embedding_attempts
            FROM memories
            WHERE id = $1::uuid
            """,
            memory_id,
        )
        assert row["embedding_missing"] is True
        assert row["embedding_status"] == "pending"
        assert row["embedding_attempts"] == 0

        result = await run_memory_embed_step(conn)
        assert result["claimed"] >= 1
        assert result["embedded"] >= 1

        embedded = await conn.fetchrow(
            """
            SELECT embedding IS NOT NULL AS has_embedding,
                   embedding_status,
                   embedded_at IS NOT NULL AS has_embedded_at,
                   embedding_attempts
            FROM memories
            WHERE id = $1::uuid
            """,
            memory_id,
        )
        assert embedded["has_embedding"] is True
        assert embedded["embedding_status"] == "embedded"
        assert embedded["has_embedded_at"] is True
        assert embedded["embedding_attempts"] >= 1
