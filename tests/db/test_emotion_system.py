import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_memory_insert_adds_emotional_context(db_pool):
    test_id = get_test_identifier("emotion_context")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            state = {
                "valence": 0.4,
                "arousal": 0.2,
                "dominance": 0.6,
                "primary_emotion": "calm",
                "intensity": 0.5,
            }
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps(state),
            )
            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, metadata)
                VALUES ('semantic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, '{}'::jsonb)
                RETURNING id
                """,
                f"emotion context {test_id}",
            )
            metadata = await conn.fetchval(
                "SELECT metadata FROM memories WHERE id = $1",
                mem_id,
            )
            meta = json.loads(metadata) if isinstance(metadata, str) else metadata
            assert "emotional_context" in meta
            assert abs(float(meta["emotional_context"]["valence"]) - 0.4) < 0.01
            assert abs(float(meta["emotional_valence"]) - 0.4) < 0.01
        finally:
            await tr.rollback()


async def test_sense_memory_availability_creates_activation(db_pool):
    test_id = get_test_identifier("feeling_of_knowing")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding)
                VALUES ('semantic', $1, array_fill(0.2, ARRAY[embedding_dimension()])::vector)
                """,
                f"availability {test_id}",
            )
            payload = await conn.fetchval(
                """
                SELECT sense_memory_availability(
                    $1::text,
                    array_fill(0.2, ARRAY[embedding_dimension()])::vector
                )
                """,
                f"availability {test_id}",
            )
            data = json.loads(payload) if isinstance(payload, str) else payload
            activation_id = data.get("activation_id")
            assert activation_id is not None
            row = await conn.fetchrow(
                "SELECT estimated_matches FROM memory_activation WHERE id = $1",
                activation_id,
            )
            assert row is not None
            assert int(row["estimated_matches"]) >= 1
        finally:
            await tr.rollback()


async def test_background_search_updates_activation_boost(db_pool):
    test_id = get_test_identifier("background_search")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding)
                VALUES ('semantic', $1, array_fill(0.3, ARRAY[embedding_dimension()])::vector)
                RETURNING id
                """,
                f"background search {test_id}",
            )
            activation_id = await conn.fetchval(
                """
                SELECT request_background_search(
                    $1::text,
                    array_fill(0.3, ARRAY[embedding_dimension()])::vector
                )
                """,
                f"background search {test_id}",
            )
            assert activation_id is not None
            await conn.fetchval(
                "SELECT process_background_searches(10, INTERVAL '0 seconds')"
            )
            activation = await conn.fetchrow(
                "SELECT background_search_pending, retrieval_succeeded FROM memory_activation WHERE id = $1",
                activation_id,
            )
            assert activation is not None
            assert activation["background_search_pending"] is False
            metadata = await conn.fetchval(
                "SELECT metadata FROM memories WHERE id = $1",
                mem_id,
            )
            meta = json.loads(metadata) if isinstance(metadata, str) else metadata
            assert float(meta.get("activation_boost", 0.0)) >= 0.2
        finally:
            await tr.rollback()


async def test_learn_emotional_trigger_updates_existing(db_pool):
    test_id = get_test_identifier("learn_trigger")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            response = json.dumps(
                {
                    "valence": 0.2,
                    "arousal": 0.3,
                    "dominance": 0.4,
                    "primary_emotion": "calm",
                }
            )
            await conn.fetchval(
                """
                SELECT learn_emotional_trigger(
                    $1::text,
                    array_fill(0.4, ARRAY[embedding_dimension()])::vector,
                    $2::jsonb
                )
                """,
                f"trigger {test_id}",
                response,
            )
            await conn.fetchval(
                """
                SELECT learn_emotional_trigger(
                    $1::text,
                    array_fill(0.4, ARRAY[embedding_dimension()])::vector,
                    $2::jsonb
                )
                """,
                f"trigger {test_id}",
                response,
            )
            row = await conn.fetchrow(
                "SELECT times_activated, confidence FROM emotional_triggers WHERE trigger_pattern = $1",
                f"trigger {test_id}",
            )
            assert row is not None
            assert int(row["times_activated"]) >= 2
            assert float(row["confidence"]) >= 0.5
        finally:
            await tr.rollback()
