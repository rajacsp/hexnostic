import json

import pytest

from tests.utils import _coerce_json, get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_normalize_affective_state_clamps_values(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_config('emotion.baseline', $1::jsonb)",
                json.dumps({"valence": 0.1, "arousal": 0.2, "dominance": 0.3, "intensity": 0.4}),
            )
            state = _coerce_json(
                await conn.fetchval(
                    "SELECT normalize_affective_state($1::jsonb)",
                    json.dumps({"valence": 2.0, "arousal": -1.0, "dominance": 2.0, "intensity": 2.0}),
                )
            )
            assert state["valence"] == 1.0
            assert state["arousal"] == 0.0
            assert state["dominance"] == 1.0
            assert state["intensity"] == 1.0
        finally:
            await tr.rollback()


async def test_get_emotional_context_for_memory_uses_current_state(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"valence": 0.3, "arousal": 0.4, "dominance": 0.5, "intensity": 0.6}),
            )
            ctx = _coerce_json(await conn.fetchval("SELECT get_emotional_context_for_memory()"))
            assert ctx["valence"] == 0.3
            assert ctx["arousal"] == 0.4
            assert ctx["dominance"] == 0.5
            assert ctx["intensity"] == 0.6
        finally:
            await tr.rollback()


async def test_regulate_emotional_state_reduces_intensity(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"valence": 0.6, "arousal": 0.7, "dominance": 0.5, "intensity": 0.9}),
            )
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT regulate_emotional_state('reduce', NULL, NULL)"
                )
            )
            before = result["before"]
            after = result["after"]
            assert after["intensity"] < before["intensity"]
        finally:
            await tr.rollback()


async def test_decay_activation_boosts_and_get_spontaneous_memories(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Set dopamine tonic to 0 so decay multiplier is 1.0 (no modulation)
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"dopamine_tonic": 0.0}),
            )

            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, metadata)
                VALUES (
                    'semantic',
                    $1,
                    array_fill(0.2, ARRAY[embedding_dimension()])::vector,
                    $2::jsonb
                )
                RETURNING id
                """,
                f"activation {get_test_identifier('activation')}",
                json.dumps({"activation_boost": 0.5}),
            )

            updated = await conn.fetchval("SELECT decay_activation_boosts(0.1)")
            assert int(updated) >= 1

            boost = await conn.fetchval(
                "SELECT (metadata->>'activation_boost')::float FROM memories WHERE id = $1",
                mem_id,
            )
            assert boost == pytest.approx(0.4, rel=0.05)

            rows = await conn.fetch("SELECT id FROM get_spontaneous_memories(3)")
            assert mem_id in {row["id"] for row in rows}
        finally:
            await tr.rollback()


async def test_cleanup_memory_activations_removes_expired(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding)
                VALUES ('semantic', $1, array_fill(0.3, ARRAY[embedding_dimension()])::vector)
                RETURNING id
                """,
                f"activation cleanup {get_test_identifier('activation')}",
            )
            await conn.execute(
                """
                INSERT INTO memory_activation (query_text, query_embedding, expires_at)
                VALUES ($1, array_fill(0.3, ARRAY[embedding_dimension()])::vector, CURRENT_TIMESTAMP - INTERVAL '1 hour')
                """,
                "test",
            )

            deleted = await conn.fetchval("SELECT cleanup_memory_activations()")
            assert int(deleted) >= 1

            remaining = await conn.fetchval("SELECT COUNT(*) FROM memory_activation")
            assert int(remaining) == 0
        finally:
            await tr.rollback()


async def test_update_mood_uses_recent_memories(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"mood_valence": 0.0, "mood_arousal": 0.3}),
            )
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, metadata)
                VALUES (
                    'episodic',
                    $1,
                    array_fill(0.4, ARRAY[embedding_dimension()])::vector,
                    $2::jsonb
                )
                """,
                f"mood memory {get_test_identifier('mood')}",
                json.dumps({"emotional_valence": 0.9, "context": {"heartbeat_id": "hb"}}),
            )

            await conn.execute("SELECT update_mood()")
            mood = _coerce_json(await conn.fetchval("SELECT get_current_affective_state()"))
            assert mood["mood_valence"] > 0.0
        finally:
            await tr.rollback()


async def test_match_emotional_triggers_returns_matches(db_pool, ensure_embedding_service):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT initialize_innate_emotions()")
            matches = _coerce_json(
                await conn.fetchval(
                    "SELECT match_emotional_triggers($1, 3, 0.5)",
                    "gratitude appreciation thankful",
                )
            )
            assert matches
            assert any("trigger_pattern" in entry for entry in matches)
        finally:
            await tr.rollback()


async def test_initialize_innate_emotions_inserts_rows(db_pool, ensure_embedding_service):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("DELETE FROM emotional_triggers WHERE origin = 'innate'")
            inserted = await conn.fetchval("SELECT initialize_innate_emotions()")
            assert int(inserted) > 0
            count = await conn.fetchval("SELECT COUNT(*) FROM emotional_triggers WHERE origin = 'innate'")
            assert int(count) > 0
        finally:
            await tr.rollback()


async def test_ensure_emotion_bootstrap_sets_config(db_pool, ensure_embedding_service):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("DELETE FROM config WHERE key = 'emotion.initialized'")
            await conn.execute("SELECT ensure_emotion_bootstrap()")
            initialized = _coerce_json(
                await conn.fetchval("SELECT get_config('emotion.initialized')")
            )
            assert initialized is True

            state = _coerce_json(await conn.fetchval("SELECT get_current_affective_state()"))
            assert "valence" in state
            assert "mood_valence" in state
        finally:
            await tr.rollback()


async def test_apply_emotional_context_to_memory_applies_metadata(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"valence": 0.1, "arousal": 0.2, "dominance": 0.3, "intensity": 0.4}),
            )
            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, metadata)
                VALUES (
                    'semantic',
                    $1,
                    array_fill(0.5, ARRAY[embedding_dimension()])::vector,
                    $2::jsonb
                )
                RETURNING id
                """,
                f"context {get_test_identifier('emotion_context')}",
                json.dumps({"emotional_context": {"valence": 2.0, "arousal": 2.0}}),
            )
            meta = _coerce_json(
                await conn.fetchval(
                    "SELECT metadata FROM memories WHERE id = $1",
                    mem_id,
                )
            )
            assert meta["emotional_context"]["valence"] == 1.0
            assert meta["emotional_context"]["arousal"] == 1.0
            assert meta["emotional_valence"] == 1.0
        finally:
            await tr.rollback()
