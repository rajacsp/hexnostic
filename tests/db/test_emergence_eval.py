from __future__ import annotations

import hashlib
import json
from datetime import timedelta

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


def _vector(dim: int, axis: int, value: float = 1.0) -> str:
    values = [0.0] * dim
    values[axis] = value
    return "[" + ",".join(str(v) for v in values) + "]"


async def _seed_query_embedding(conn, query: str, axis: int = 0) -> tuple[int, str]:
    dim = int(await conn.fetchval("SELECT embedding_dimension()"))
    vec = _vector(dim, axis)
    for text in (query, f"search_query: {query}"):
        content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        await conn.execute(
            """
            INSERT INTO embedding_cache (content_hash, embedding)
            VALUES ($1, $2::vector)
            ON CONFLICT (content_hash) DO UPDATE SET embedding = EXCLUDED.embedding
            """,
            content_hash,
            vec,
        )
    return dim, vec


async def test_tip_of_tongue_partial_activation_surfaces_cluster_not_memory(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            marker = get_test_identifier("emergence_tot")
            query = f"partial activation cue {marker}"
            dim, query_vec = await _seed_query_embedding(conn, query, axis=0)
            orthogonal_vec = _vector(dim, axis=1)

            cluster_id = await conn.fetchval(
                """
                INSERT INTO clusters (cluster_type, name, centroid_embedding)
                VALUES ('theme', $1, $2::vector)
                RETURNING id
                """,
                f"ToT cluster {marker}",
                query_vec,
            )
            memory_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level)
                VALUES ('semantic', $1, $2::vector, 0.8, 0.9)
                RETURNING id
                """,
                f"orthogonal member {marker}",
                orthogonal_vec,
            )
            await conn.execute("SELECT sync_memory_node($1)", memory_id)
            await conn.execute("SELECT link_memory_to_cluster_graph($1, $2, 1.0)", memory_id, cluster_id)

            rows = await conn.fetch("SELECT * FROM find_partial_activations($1, 0.9, 0.2)", query)
            assert any(row["cluster_id"] == cluster_id for row in rows)
        finally:
            await tr.rollback()


async def test_mood_colored_recall_prefers_mood_congruent_memory(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            marker = get_test_identifier("emergence_mood")
            query = f"mood congruent query {marker}"
            _dim, query_vec = await _seed_query_embedding(conn, query, axis=2)
            await conn.execute("SELECT set_config('memory.recall_strength_weight', '0'::jsonb)")
            await conn.execute("SELECT set_config('memory.recency_weight', '0'::jsonb)")
            await conn.execute("SELECT set_config('memory.recall_activation_boost_weight', '0'::jsonb)")
            await conn.execute("SELECT set_config('memory.recall_graph_adjacency_weight', '0'::jsonb)")
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"valence": 0.8, "arousal": 0.4, "primary_emotion": "warm"}),
            )
            positive_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
                VALUES ('semantic', $1, $2::vector, 0.8, 0.9, $3::jsonb)
                RETURNING id
                """,
                f"positive congruent memory {marker}",
                query_vec,
                json.dumps({"emotional_valence": 0.8}),
            )
            negative_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
                VALUES ('semantic', $1, $2::vector, 0.8, 0.9, $3::jsonb)
                RETURNING id
                """,
                f"negative incongruent memory {marker}",
                query_vec,
                json.dumps({"emotional_valence": -0.8}),
            )

            rows = await conn.fetch(
                "SELECT item_id, tier, score FROM recmem_recall_context($1, 0, 0, 5, NULL, FALSE, 0)",
                query,
            )
            ordered = [row["item_id"] for row in rows if row["item_id"] in {positive_id, negative_id}]
            assert ordered[:2] == [positive_id, negative_id]
        finally:
            await tr.rollback()


async def test_open_goal_memory_enters_knowledge_tier_and_archived_goal_does_not(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            marker = get_test_identifier("emergence_goal")
            query = f"open goal cue {marker}"
            _dim, query_vec = await _seed_query_embedding(conn, query, axis=3)
            active_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
                VALUES ('goal', $1, $2::vector, 0.9, 0.9, $3::jsonb)
                RETURNING id
                """,
                f"active open goal {marker}",
                query_vec,
                json.dumps({"priority": "active", "title": f"active open goal {marker}"}),
            )
            archived_id = await conn.fetchval(
                """
                INSERT INTO memories (type, status, content, embedding, importance, trust_level, metadata)
                VALUES ('goal', 'archived', $1, $2::vector, 0.9, 0.9, $3::jsonb)
                RETURNING id
                """,
                f"archived closed goal {marker}",
                query_vec,
                json.dumps({"priority": "completed", "title": f"archived closed goal {marker}"}),
            )

            rows = await conn.fetch(
                "SELECT item_id, tier, memory_type FROM recmem_recall_context($1, 0, 0, 0, NULL, FALSE, 5)",
                query,
            )
            seen = {row["item_id"]: row for row in rows}
            assert seen[active_id]["tier"] == "knowledge"
            assert seen[active_id]["memory_type"] == "goal"
            assert archived_id not in seen
        finally:
            await tr.rollback()


async def test_spaced_reinforcement_scores_above_massed_repetition(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            marker = get_test_identifier("emergence_spacing")
            vec = await conn.fetchval(
                "SELECT array_fill(0.25::float, ARRAY[embedding_dimension()])::vector::text"
            )
            spaced_id = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding) VALUES ('semantic', $1, $2::vector) RETURNING id",
                f"spaced practice memory {marker}",
                vec,
            )
            massed_id = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding) VALUES ('semantic', $1, $2::vector) RETURNING id",
                f"massed practice memory {marker}",
                vec,
            )

            for offset in (timedelta(days=3), timedelta(days=2), timedelta(days=1)):
                await conn.execute(
                    """
                    SELECT record_memory_reinforcement(
                        $1::uuid, 'recall'::text, 'eval'::text, '{}'::jsonb, CURRENT_TIMESTAMP - $2::interval
                    )
                    """,
                    spaced_id,
                    offset,
                )
            for offset in (
                timedelta(days=3),
                timedelta(days=3, minutes=10),
                timedelta(days=3, minutes=20),
            ):
                await conn.execute(
                    """
                    SELECT record_memory_reinforcement(
                        $1::uuid, 'recall'::text, 'eval'::text, '{}'::jsonb, CURRENT_TIMESTAMP - $2::interval
                    )
                    """,
                    massed_id,
                    offset,
                )

            spaced = await conn.fetchval(
                "SELECT memory_spaced_reinforcement_score($1, INTERVAL '180 days', INTERVAL '12 hours')",
                spaced_id,
            )
            massed = await conn.fetchval(
                "SELECT memory_spaced_reinforcement_score($1, INTERVAL '180 days', INTERVAL '12 hours')",
                massed_id,
            )
            assert spaced > massed
        finally:
            await tr.rollback()
