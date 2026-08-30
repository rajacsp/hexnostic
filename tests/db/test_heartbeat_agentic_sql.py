"""Tests for DB-owned agentic-heartbeat helpers (db/43_functions_heartbeat_agentic.sql).

is_within_active_hours (was worker_service._check_active_hours) and
finalize_agentic_heartbeat (was inline SQL in heartbeat_agentic.finalize_heartbeat).
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


async def test_is_within_active_hours(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # No active_hours configured -> unrestricted (True).
            await conn.execute("DELETE FROM config WHERE key = 'heartbeat.active_hours'")
            assert await conn.fetchval("SELECT is_within_active_hours()") is True

            await conn.execute("SELECT set_config('heartbeat.timezone', '\"UTC\"')")

            # Full-day window -> True.
            await conn.execute("SELECT set_config('heartbeat.active_hours', '\"00:00-23:59\"')")
            assert await conn.fetchval("SELECT is_within_active_hours()") is True

            # Empty window (start == end) -> always False, regardless of clock.
            await conn.execute("SELECT set_config('heartbeat.active_hours', '\"00:00-00:00\"')")
            assert await conn.fetchval("SELECT is_within_active_hours()") is False

            # Malformed value -> fail open (True).
            await conn.execute("SELECT set_config('heartbeat.active_hours', '\"garbage\"')")
            assert await conn.fetchval("SELECT is_within_active_hours()") is True
            await conn.execute("SELECT set_config('heartbeat.active_hours', '\"25:00-26:00\"')")
            assert await conn.fetchval("SELECT is_within_active_hours()") is True

            # Unknown timezone falls back to UTC (still evaluates the window).
            await conn.execute("SELECT set_config('heartbeat.active_hours', '\"00:00-00:00\"')")
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Not/AZone\"')")
            assert await conn.fetchval("SELECT is_within_active_hours()") is False
        finally:
            await tr.rollback()


async def test_finalize_checkpoints_interrupted_backlog(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            item = await conn.fetchval(
                "INSERT INTO public.backlog (title, status, priority) "
                "VALUES ('cp', 'in_progress', 'high') RETURNING id"
            )
            await conn.fetchval(
                "SELECT finalize_agentic_heartbeat($1::text, $2::text, $3::int, $4::int, $5::text, $6::boolean)",
                "hb", "ran out of time", 20, 1, "timeout", True,
            )
            cp = _j(await conn.fetchval("SELECT checkpoint FROM public.backlog WHERE id = $1", item))
            assert cp["step"] == "interrupted"
            assert "timeout" in cp["progress"]
        finally:
            await tr.rollback()


async def test_finalize_does_not_overwrite_existing_checkpoint(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            existing = json.dumps({"step": "step 3", "progress": "good", "next_action": "verify"})
            item = await conn.fetchval(
                "INSERT INTO public.backlog (title, status, priority, checkpoint) "
                "VALUES ('cp2', 'in_progress', 'high', $1::jsonb) RETURNING id",
                existing,
            )
            await conn.fetchval(
                "SELECT finalize_agentic_heartbeat($1::text, $2::text, $3::int, $4::int, $5::text, $6::boolean)",
                "hb", "timed out", 10, 0, "timeout", True,
            )
            cp = _j(await conn.fetchval("SELECT checkpoint FROM public.backlog WHERE id = $1", item))
            assert cp["step"] == "step 3"  # unchanged
        finally:
            await tr.rollback()


async def test_finalize_no_checkpoint_when_completed(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            item = await conn.fetchval(
                "INSERT INTO public.backlog (title, status, priority) "
                "VALUES ('cp3', 'in_progress', 'high') RETURNING id"
            )
            await conn.fetchval(
                "SELECT finalize_agentic_heartbeat($1::text, $2::text, $3::int, $4::int, $5::text, $6::boolean)",
                "hb", "done", 5, 0, "completed", True,
            )
            cp = await conn.fetchval("SELECT checkpoint FROM public.backlog WHERE id = $1", item)
            assert cp is None  # completed heartbeats don't auto-checkpoint
        finally:
            await tr.rollback()
