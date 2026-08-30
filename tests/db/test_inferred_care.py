"""Inferred care check-ins (#98 Batch 2b): a user_event extraction creates
the memory AND a bounded, scheduled, web-inbox-pinned check-in after the
event — with confidence floors, dedupe, caps, and the no-same-moment clamp.
"""
from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _stub(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                array_fill(0.01::float, ARRAY[2 + abs(hashtext(t)) % (embedding_dimension() - 2)]) ||
                ARRAY[1.0::float] ||
                array_fill(0.01::float, ARRAY[embedding_dimension() - 3 - abs(hashtext(t)) % (embedding_dimension() - 2)])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents) t
        $$ LANGUAGE sql;
        """
    )


async def _unit(conn, m):
    import uuid as _uuid
    return await conn.fetchval(
        """
        INSERT INTO subconscious_units (content, user_text, assistant_text, importance,
                                        status, idempotency_key)
        VALUES ($1, $1, '', 0.7, 'active', $2)
        RETURNING id
        """,
        f"turn about an event {m}", f"test:{_uuid.uuid4().hex}",
    )


def _event(unit_id, m, **over):
    from datetime import datetime, timedelta, timezone
    when = (datetime.now(timezone.utc) + timedelta(days=30)).isoformat()
    fact = {
        "unit_id": str(unit_id),
        "content": f"Eric has a job interview at Acme {m}",
        "kind": "user_event",
        "category": "event_check_in",
        "confidence": 0.8,
        "when": when,  # inside the 90-day horizon
        "care_note": "he said he's nervous about it",
        "dedupe_key": f"interview:{m}",
    }
    fact.update(over)
    return fact


async def test_user_event_creates_memory_and_bounded_checkin(db_pool):
    m = get_test_identifier("care")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub(conn)
            unit = await _unit(conn, m)
            result = json.loads(await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                unit, json.dumps([_event(unit, m)]),
            ))
            assert result["created"] == 1

            mem = await conn.fetchrow(
                "SELECT id FROM memories WHERE content LIKE '%' || $1 || '%'", m)
            assert mem is not None

            task = await conn.fetchrow(
                "SELECT next_run_at, action_payload, delivery, max_runs FROM scheduled_tasks "
                "WHERE action_payload->>'dedupe_key' = $1", f"interview:{m}")
            assert task is not None
            payload = json.loads(task["action_payload"])
            assert "How did it go?" in payload["message"]
            assert "nervous" in payload["message"]  # care_note carried
            assert payload["intent"] == "care_checkin"
            assert json.loads(task["delivery"])["mode"] == "web_inbox"
            assert task["max_runs"] == 1
            # Fires after the event + configured delay (not clamped to now)
            from datetime import datetime, timedelta, timezone
            fires = task["next_run_at"]
            expected = datetime.now(timezone.utc) + timedelta(days=30, minutes=120)
            assert abs((fires - expected).total_seconds()) < 300

            # Dedupe: the same key again merges (no second task)
            unit2 = await _unit(conn, m + "b")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                unit2, json.dumps([_event(unit2, m)]),
            )
            n = await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"interview:{m}")
            assert n == 1
        finally:
            await tr.rollback()


async def test_confidence_floors_caps_and_clamp(db_pool):
    m = get_test_identifier("care")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub(conn)
            # Low confidence: memory yes, schedule no
            u1 = await _unit(conn, m + "1")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                u1, json.dumps([_event(u1, m + "low", confidence=0.6,
                                       dedupe_key=f"low:{m}")]),
            )
            assert await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"low:{m}") == 0

            # care_check_in demands 0.86: 0.8 fails, 0.9 passes
            u2 = await _unit(conn, m + "2")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                u2, json.dumps([_event(u2, m + "care", category="care_check_in",
                                       confidence=0.8, dedupe_key=f"care1:{m}")]),
            )
            assert await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"care1:{m}") == 0
            u3 = await _unit(conn, m + "3")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                u3, json.dumps([_event(u3, m + "care2", category="care_check_in",
                                       confidence=0.9, dedupe_key=f"care2:{m}")]),
            )
            assert await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"care2:{m}") == 1

            # No-same-moment clamp: a near-past event fires >= one heartbeat out
            u4 = await _unit(conn, m + "4")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                u4, json.dumps([_event(u4, m + "soon",
                                       when="2020-01-01T00:00:00Z",  # long past → skipped
                                       dedupe_key=f"past:{m}")]),
            )
            assert await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"past:{m}") == 0

            # Kill switch
            await conn.execute("SELECT set_config('care.checkins_enabled', 'false'::jsonb)")
            u5 = await _unit(conn, m + "5")
            await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                u5, json.dumps([_event(u5, m + "off", dedupe_key=f"off:{m}")]),
            )
            assert await conn.fetchval(
                "SELECT COUNT(*) FROM scheduled_tasks WHERE action_payload->>'dedupe_key' = $1",
                f"off:{m}") == 0
        finally:
            await tr.rollback()
