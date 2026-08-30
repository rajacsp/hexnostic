"""Tests for the dopamine reinforcement system (db/28_functions_dopamine.sql)."""

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _get_dopamine_state(conn) -> dict:
    raw = await conn.fetchval("SELECT get_dopamine_state()")
    if isinstance(raw, str):
        return json.loads(raw)
    return dict(raw) if raw else {}


async def _set_affective_state(conn, **kwargs) -> None:
    await conn.execute(
        "SELECT set_current_affective_state($1::jsonb)",
        json.dumps(kwargs),
    )


async def _insert_test_memory(conn, content: str = "test memory", minutes_ago: int = 5) -> str:
    """Insert a test memory within a specific time window."""
    mid = await conn.fetchval(
        """
        INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at)
        VALUES ('episodic', $1,
                array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                0.5, 0.9, 'active',
                CURRENT_TIMESTAMP - ($2 || ' minutes')::interval)
        RETURNING id
        """,
        content,
        str(minutes_ago),
    )
    return str(mid)


async def _get_memory_metadata(conn, memory_id: str) -> dict:
    raw = await conn.fetchval(
        "SELECT metadata FROM memories WHERE id = $1::uuid", memory_id
    )
    if isinstance(raw, str):
        return json.loads(raw)
    return dict(raw) if raw else {}


async def _get_memory_importance(conn, memory_id: str) -> float:
    return await conn.fetchval(
        "SELECT importance FROM memories WHERE id = $1::uuid", memory_id
    )


# ---------------------------------------------------------------------------
# Tests: get_dopamine_state
# ---------------------------------------------------------------------------


async def test_get_dopamine_state_defaults(db_pool):
    """get_dopamine_state returns sensible defaults when no dopamine has been set."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            state = await _get_dopamine_state(conn)
            assert isinstance(state, dict)
            assert "tonic" in state
            assert "effective" in state
            # Default tonic is 0.5
            assert 0.4 <= state["tonic"] <= 0.6
        finally:
            await tr.rollback()


async def test_dopamine_tonic_persists_through_normalization(db_pool):
    """Dopamine fields survive normalize_affective_state()."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _set_affective_state(
                conn,
                dopamine_tonic=0.75,
                dopamine_phasic=0.3,
                dopamine_spike_trigger="test",
            )
            state = await _get_dopamine_state(conn)
            assert abs(state["tonic"] - 0.75) < 0.01
            assert abs(state["phasic"] - 0.3) < 0.01
            assert state["spike_trigger"] == "test"
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: fire_dopamine_spike — positive RPE
# ---------------------------------------------------------------------------


async def test_fire_dopamine_spike_positive(db_pool):
    """Positive RPE boosts tonic and enhances recent memories."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Set baseline tonic
            await _set_affective_state(conn, dopamine_tonic=0.5)

            # Insert a recent memory
            mid = await _insert_test_memory(conn, "rewarding experience", minutes_ago=10)
            original_importance = await _get_memory_importance(conn, mid)

            # Fire a positive spike
            result_raw = await conn.fetchval(
                "SELECT fire_dopamine_spike($1, $2)",
                0.6,  # positive RPE
                "goal completed",
            )
            result = json.loads(result_raw) if isinstance(result_raw, str) else result_raw

            assert result["fired"] is True
            assert result["rpe"] == 0.6
            assert result["tonic_new"] > result["tonic_old"]
            assert result["memories_boosted"] > 0

            # Memory should have boosted activation and importance
            meta = await _get_memory_metadata(conn, mid)
            assert meta.get("activation_boost", 0) > 0
            new_importance = await _get_memory_importance(conn, mid)
            assert new_importance > original_importance
        finally:
            await tr.rollback()


async def test_fire_dopamine_spike_negative(db_pool):
    """Negative RPE lowers tonic and suppresses recent memories."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Set slightly elevated tonic
            await _set_affective_state(conn, dopamine_tonic=0.6)

            # Insert a recent memory with some activation
            mid = await _insert_test_memory(conn, "painful experience", minutes_ago=10)
            await conn.execute(
                """
                UPDATE memories SET metadata = jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{activation_boost}', '0.3'::jsonb
                ) WHERE id = $1::uuid
                """,
                mid,
            )

            # Fire a negative spike
            result_raw = await conn.fetchval(
                "SELECT fire_dopamine_spike($1, $2)",
                -0.5,  # negative RPE
                "rejection",
            )
            result = json.loads(result_raw) if isinstance(result_raw, str) else result_raw

            assert result["fired"] is True
            assert result["tonic_new"] < result["tonic_old"]

            # Activation should be reduced
            meta = await _get_memory_metadata(conn, mid)
            assert meta.get("activation_boost", 0) < 0.3
        finally:
            await tr.rollback()


async def test_fire_dopamine_spike_tonic_ema(db_pool):
    """Repeated positive spikes progressively raise tonic."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _set_affective_state(conn, dopamine_tonic=0.5)

            for _ in range(5):
                await conn.fetchval(
                    "SELECT fire_dopamine_spike($1, $2)", 0.4, "repeated reward"
                )

            state = await _get_dopamine_state(conn)
            # After 5 positive spikes, tonic should be noticeably above 0.5
            assert state["tonic"] > 0.55
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: drive modulation
# ---------------------------------------------------------------------------


async def test_positive_spike_satisfies_drives(db_pool):
    """Positive dopamine spike reduces curiosity and connection drives."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Set drives to known levels
            await conn.execute(
                "UPDATE drives SET current_level = 0.7 WHERE name IN ('curiosity', 'connection')"
            )

            await conn.fetchval(
                "SELECT fire_dopamine_spike($1, $2)", 0.5, "achievement"
            )

            curiosity = await conn.fetchval(
                "SELECT current_level FROM drives WHERE name = 'curiosity'"
            )
            assert curiosity < 0.7
        finally:
            await tr.rollback()


async def test_negative_spike_increases_rest_drive(db_pool):
    """Negative dopamine spike increases rest drive."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "UPDATE drives SET current_level = 0.3 WHERE name = 'rest'"
            )

            await conn.fetchval(
                "SELECT fire_dopamine_spike($1, $2)", -0.6, "failure"
            )

            rest = await conn.fetchval(
                "SELECT current_level FROM drives WHERE name = 'rest'"
            )
            assert rest > 0.3
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: dopamine-modulated decay
# ---------------------------------------------------------------------------


async def test_decay_activation_boosts_dopamine_modulated(db_pool):
    """High tonic dopamine slows activation decay."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await _insert_test_memory(conn, "important memory")
            await conn.execute(
                """
                UPDATE memories SET metadata = jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{activation_boost}', '0.5'::jsonb
                ) WHERE id = $1::uuid
                """,
                mid,
            )

            # High tonic — should decay slowly
            await _set_affective_state(conn, dopamine_tonic=0.9)
            await conn.fetchval("SELECT decay_activation_boosts(0.1)")
            meta_high = await _get_memory_metadata(conn, mid)
            boost_after_high = meta_high.get("activation_boost", 0)

            # Reset boost
            await conn.execute(
                """
                UPDATE memories SET metadata = jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{activation_boost}', '0.5'::jsonb
                ) WHERE id = $1::uuid
                """,
                mid,
            )

            # Low tonic — should decay faster
            await _set_affective_state(conn, dopamine_tonic=0.1)
            await conn.fetchval("SELECT decay_activation_boosts(0.1)")
            meta_low = await _get_memory_metadata(conn, mid)
            boost_after_low = meta_low.get("activation_boost", 0)

            # High-dopamine state should have preserved more activation
            assert boost_after_high > boost_after_low
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: dopamine at encoding
# ---------------------------------------------------------------------------


async def test_dopamine_at_encoding_tagged(db_pool):
    """New memories get tagged with dopamine_at_encoding from current tonic."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _set_affective_state(conn, dopamine_tonic=0.8)

            mid = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', 'high dopamine encoding test',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.5, 0.9, 'active')
                RETURNING id
                """
            )
            meta = await _get_memory_metadata(conn, str(mid))
            assert "dopamine_at_encoding" in meta
            assert abs(meta["dopamine_at_encoding"] - 0.8) < 0.05
        finally:
            await tr.rollback()


async def test_high_dopamine_encoding_boosts_importance(db_pool):
    """Memories encoded during high dopamine get an importance bump."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Encode at high dopamine
            await _set_affective_state(conn, dopamine_tonic=0.9)
            mid_high = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', 'high dopamine memory',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.5, 0.9, 'active')
                RETURNING id
                """
            )

            # Encode at neutral dopamine
            await _set_affective_state(conn, dopamine_tonic=0.5)
            mid_neutral = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', 'neutral dopamine memory',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.5, 0.9, 'active')
                RETURNING id
                """
            )

            imp_high = await _get_memory_importance(conn, str(mid_high))
            imp_neutral = await _get_memory_importance(conn, str(mid_neutral))
            assert imp_high > imp_neutral
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: tonic drift (homeostasis)
# ---------------------------------------------------------------------------


async def test_drift_dopamine_tonic_toward_baseline(db_pool):
    """drift_dopamine_tonic() pulls tonic toward 0.5."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _set_affective_state(conn, dopamine_tonic=0.9)

            result_raw = await conn.fetchval("SELECT drift_dopamine_tonic(0.1)")
            result = json.loads(result_raw) if isinstance(result_raw, str) else result_raw

            assert result["drifted"] is True
            assert result["new_tonic"] < 0.9
            assert result["new_tonic"] > 0.5  # hasn't overshot to below baseline
        finally:
            await tr.rollback()


async def test_drift_from_low_tonic(db_pool):
    """Drift from low tonic pulls upward toward 0.5."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _set_affective_state(conn, dopamine_tonic=0.1)

            await conn.fetchval("SELECT drift_dopamine_tonic(0.1)")
            state = await _get_dopamine_state(conn)

            assert state["tonic"] > 0.1
            assert state["tonic"] < 0.5
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: dopamine_decay_multiplier (pure function)
# ---------------------------------------------------------------------------


async def test_dopamine_decay_multiplier(db_pool):
    """dopamine_decay_multiplier returns expected range."""
    async with db_pool.acquire() as conn:
        # High dopamine → low multiplier (slow decay)
        high = await conn.fetchval("SELECT dopamine_decay_multiplier(1.0)")
        assert high == pytest.approx(0.3, abs=0.01)

        # Low dopamine → high multiplier (fast decay)
        low = await conn.fetchval("SELECT dopamine_decay_multiplier(0.0)")
        assert low == pytest.approx(1.0, abs=0.01)

        # Neutral
        mid = await conn.fetchval("SELECT dopamine_decay_multiplier(0.5)")
        assert 0.5 < mid < 0.8


# ---------------------------------------------------------------------------
# Tests: neighborhood spread
# ---------------------------------------------------------------------------


async def test_positive_spike_spreads_to_neighbors(db_pool):
    """Positive RPE spreads activation boost through memory neighborhoods."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Insert two memories
            mid1 = await _insert_test_memory(conn, "main memory", minutes_ago=5)
            mid2 = await _insert_test_memory(conn, "neighbor memory", minutes_ago=60)

            # Set up neighborhood: mid1's neighbor is mid2
            await conn.execute(
                """
                INSERT INTO memory_neighborhoods (memory_id, neighbors, is_stale)
                VALUES ($1::uuid, $2::jsonb, false)
                ON CONFLICT (memory_id) DO UPDATE SET neighbors = $2::jsonb
                """,
                mid1,
                json.dumps({"0": mid2}),
            )

            # Fire positive spike
            await conn.fetchval(
                "SELECT fire_dopamine_spike($1, $2)", 0.7, "social reward"
            )

            # mid2 (neighbor) should have gained activation from spread
            meta2 = await _get_memory_metadata(conn, mid2)
            assert meta2.get("activation_boost", 0) > 0
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Tests: update_mood dopamine modulation
# ---------------------------------------------------------------------------


async def test_update_mood_dopamine_modulated(db_pool):
    """update_mood() respects dopamine tonic for decay rate."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Set a strong positive mood
            await _set_affective_state(
                conn,
                mood_valence=0.8,
                mood_arousal=0.6,
                dopamine_tonic=0.9,
            )

            # Run mood update — high dopamine should preserve mood
            await conn.fetchval("SELECT update_mood()")

            state = await _get_dopamine_state(conn)
            affect_raw = await conn.fetchval("SELECT get_current_affective_state()")
            affect = json.loads(affect_raw) if isinstance(affect_raw, str) else affect_raw

            # Mood should still be positive (high dopamine slows decay)
            assert affect["mood_valence"] > 0.5
        finally:
            await tr.rollback()
