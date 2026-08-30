"""Tests for asymmetric felt emotional intensity (db/03 current_emotional_intensity)
-- Phase 3 of docs/memory_retention_design.md §8/§9: embers for joy, healing for
pain, re-kindle on recall; persistence stays keyed to the encoded peak."""
from __future__ import annotations

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def _ci(conn, enc, val, age_days, reinforced_days_ago=None):
    return await conn.fetchval(
        "SELECT current_emotional_intensity($1, $2, now() - ($3 || ' days')::interval, "
        "CASE WHEN $4::text IS NULL THEN NULL ELSE now() - ($4 || ' days')::interval END)",
        enc, val, str(age_days), None if reinforced_days_ago is None else str(reinforced_days_ago))


async def test_positive_peak_keeps_ember(db_pool):
    async with db_pool.acquire() as conn:
        old = await _ci(conn, 0.9, 0.8, 3650, None)   # a 10-year-old joy, never revisited
        floor = 0.8 * 0.9 * 0.5                        # valence * encoded * ember_factor
        assert old >= floor - 1e-6                     # never cools below its ember
        assert old > 0.1
        assert old < 0.9                               # but has settled from the peak


async def test_negative_pain_heals_to_calm(db_pool):
    async with db_pool.acquire() as conn:
        old_pain = await _ci(conn, 0.9, -0.8, 3650, None)
        assert old_pain < 0.05                         # healed toward calm (floor 0 for negative)


async def test_recall_rekindles(db_pool):
    async with db_pool.acquire() as conn:
        cold = await _ci(conn, 0.9, 0.8, 365, 365)     # last felt a year ago
        hot = await _ci(conn, 0.9, 0.8, 365, 0)        # felt again today
        assert hot > cold + 0.1                        # remembering stirs it back up


async def test_negative_rekindle_is_weaker(db_pool):
    async with db_pool.acquire() as conn:
        pos = await _ci(conn, 0.9, 0.8, 365, 0)
        neg = await _ci(conn, 0.9, -0.8, 365, 0)
        assert neg < pos                               # rumination can't hold a wound as hot as joy


async def test_bounded(db_pool):
    async with db_pool.acquire() as conn:
        assert 0.0 <= await _ci(conn, 1.0, 1.0, 0, 0) <= 1.0
        assert await _ci(conn, 0.0, 0.0, 100, None) == 0.0


async def test_protection_reads_encoded_peak_not_felt(db_pool):
    """A healed old wound (felt intensity ~0) whose ENCODED peak is high stays
    protected -- its fact survives even though the charge has cooled."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await conn.fetchval(
                "INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, metadata) "
                "VALUES ('episodic', 'an old wound', array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.3, 0.9, 'active', "
                "now() - interval '3650 days', '{\"emotional_context\":{\"intensity\":0.9},\"emotional_valence\":-0.8}'::jsonb) RETURNING id")
            felt = await conn.fetchval("SELECT current_emotional_intensity(0.9, -0.8, now() - interval '3650 days', NULL)")
            assert felt < 0.05                          # the feeling has healed
            assert await conn.fetchval("SELECT is_memory_protected($1)", mid) is True   # but it stays protected
        finally:
            await tr.rollback()


async def test_embered_joy_stays_recallable(db_pool):
    """Equal similarity, both old/low-strength -- the embered positive memory
    outranks the mundane one in recall (ember keeps it accessible). Needs the
    embedding service (query embedding)."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Both memories embed AT the query so similarity is realistic
            # (~1.0). At artificial near-zero similarity the multiplicative
            # ember term vanishes and additive mood congruence (a real,
            # separate mechanism — the joyful memory is incongruent with a
            # neutral present mood) decides instead of the ember under test.
            emb = "(get_embedding(ARRAY['an old note']))[1]"
            mundane = await conn.fetchval(
                f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at) "
                f"VALUES ('semantic', 'a mundane old note', {emb}, 0.3, 0.9, 'active', now() - interval '300 days') RETURNING id")
            embered = await conn.fetchval(
                f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, metadata) "
                f"VALUES ('semantic', 'a joyful old note', {emb}, 0.3, 0.9, 'active', now() - interval '300 days', "
                f"'{{\"emotional_context\":{{\"intensity\":0.9}},\"emotional_valence\":0.85}}'::jsonb) RETURNING id")
            rows = await conn.fetch(
                "SELECT item_id, score FROM recmem_recall_context('an old note', 0, 0, 5, NULL) "
                "WHERE tier='semantic' AND item_id = ANY($1::uuid[]) ORDER BY score DESC", [mundane, embered])
            assert len(rows) == 2
            assert rows[0]["item_id"] == embered
        finally:
            await tr.rollback()
