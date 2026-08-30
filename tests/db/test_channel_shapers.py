"""Channel-command shapers (3.13): target resolution and rendered replies.

Also regression pins: the former Python /status, /energy, and /goals
handlers queried columns that do not exist (max_energy, energy_regen_rate,
last_heartbeat; goal status 'queued') and failed on every call.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_resolve_last_active_prefers_sender(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'chan-a', 'alice', now() - interval '1 hour'),
                       ('discord', 'chan-b', 'bob', now())
                """
            )
            for_alice = json.loads(await conn.fetchval(
                "SELECT resolve_last_active_target('alice')"
            ))
            global_latest = json.loads(await conn.fetchval(
                "SELECT resolve_last_active_target(NULL)"
            ))
            targets = json.loads(await conn.fetchval(
                "SELECT list_broadcast_targets()"
            ))
        finally:
            await tr.rollback()

    assert for_alice["channel_type"] == "telegram"
    assert global_latest["sender_id"] == "bob"
    assert {t["sender_id"] for t in targets} >= {"alice", "bob"}


async def test_broadcast_window_is_config(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('slack', 'stale-chan', 'stale-sender', now() - interval '30 days')
                """
            )
            default_window = json.loads(await conn.fetchval(
                "SELECT list_broadcast_targets()"
            ))
            await conn.execute(
                "SELECT set_config('channel.broadcast_window_days', '60'::jsonb)"
            )
            wide_window = json.loads(await conn.fetchval(
                "SELECT list_broadcast_targets()"
            ))
        finally:
            await tr.rollback()

    assert all(t["sender_id"] != "stale-sender" for t in default_window)
    assert any(t["sender_id"] == "stale-sender" for t in wide_window)


async def test_status_and_energy_summaries_render(db_pool):
    async with db_pool.acquire() as conn:
        status = await conn.fetchval("SELECT channel_status_summary()")
        energy = await conn.fetchval("SELECT channel_energy_summary()")

    assert status.startswith("**Agent Status**")
    assert "Energy:" in status and "Heartbeats:" in status
    assert energy.startswith("**Energy**")
    assert "/hour" in energy


async def test_goals_summary_reads_metadata_priority(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, metadata)
                VALUES ('goal', 'Queued goal for shaper test',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.9, 0.9, 'active', '{"priority": "queued"}'::jsonb)
                """
            )
            rendered = await conn.fetchval("SELECT channel_goals_summary()")
        finally:
            await tr.rollback()

    assert rendered.startswith("**Active Goals**")
    assert "[queued]" in rendered
    assert "Queued goal for shaper test" in rendered
