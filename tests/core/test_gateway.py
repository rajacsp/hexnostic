"""
Tests for core/gateway.py — Gateway event bus.

Covers: submit, record, dequeue, concurrent dequeue (SKIP LOCKED),
complete, fail, cleanup, recent.
"""

from __future__ import annotations

import asyncio

import pytest

from core.gateway import EventSource, EventStatus, Gateway, GatewayEvent

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Submit / Record
# ============================================================================


async def test_submit_creates_pending_event(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(EventSource.HEARTBEAT, "heartbeat:test:1")
    assert isinstance(event_id, int)
    assert event_id > 0

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM gateway_events WHERE id = $1", event_id
        )
    assert row is not None
    assert row["source"] == "heartbeat"
    assert row["status"] == "pending"
    assert row["session_key"] == "heartbeat:test:1"
    assert row["started_at"] is None
    assert row["completed_at"] is None


async def test_submit_stores_payload(db_pool):
    gw = Gateway(db_pool)
    payload = {"heartbeat_id": "abc-123", "energy": 10}
    event_id = await gw.submit(
        EventSource.HEARTBEAT, "heartbeat:test:payload", payload
    )

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT payload FROM gateway_events WHERE id = $1", event_id
        )
    import json

    stored = json.loads(row["payload"]) if isinstance(row["payload"], str) else row["payload"]
    assert stored["heartbeat_id"] == "abc-123"
    assert stored["energy"] == 10


async def test_record_creates_recorded_event(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.record(
        EventSource.CHAT,
        "chat:api:session-xyz",
        {"message": "hello"},
    )
    assert isinstance(event_id, int)

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM gateway_events WHERE id = $1", event_id
        )
    assert row is not None
    assert row["source"] == "chat"
    assert row["status"] == "recorded"
    assert row["session_key"] == "chat:api:session-xyz"


async def test_record_is_not_dequeued(db_pool):
    """Recorded events should never appear in dequeue results."""
    gw = Gateway(db_pool)
    await gw.record(EventSource.CHAT, "chat:api:no-dequeue")

    event = await gw.dequeue([EventSource.CHAT])
    # Should be None because there are no 'pending' chat events
    assert event is None


# ============================================================================
# Dequeue
# ============================================================================


async def test_dequeue_returns_pending_and_marks_processing(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(
        EventSource.CRON, "cron:test:dequeue", {"task": "cleanup"}
    )

    event = await gw.dequeue([EventSource.CRON])
    assert event is not None
    assert isinstance(event, GatewayEvent)
    assert event.id == event_id
    assert event.source == EventSource.CRON
    assert event.status == EventStatus.PROCESSING
    assert event.started_at is not None
    assert event.session_key == "cron:test:dequeue"


async def test_dequeue_returns_none_when_empty(db_pool):
    gw = Gateway(db_pool)
    # Dequeue a source that shouldn't have any pending events
    event = await gw.dequeue([EventSource.WEBHOOK])
    assert event is None


async def test_dequeue_filters_by_source(db_pool):
    gw = Gateway(db_pool)
    await gw.submit(EventSource.MAINTENANCE, "maintenance:test:filter")

    # Try to dequeue a different source — should get None
    event = await gw.dequeue([EventSource.WEBHOOK])
    assert event is None

    # Now dequeue the right source
    event = await gw.dequeue([EventSource.MAINTENANCE])
    assert event is not None
    assert event.source == EventSource.MAINTENANCE


async def test_dequeue_skips_locked_events(db_pool):
    """Two concurrent dequeues should not return the same event."""
    gw = Gateway(db_pool)
    id1 = await gw.submit(EventSource.INTERNAL, "internal:test:lock1")
    id2 = await gw.submit(EventSource.INTERNAL, "internal:test:lock2")

    # Dequeue both concurrently
    results = await asyncio.gather(
        gw.dequeue([EventSource.INTERNAL]),
        gw.dequeue([EventSource.INTERNAL]),
    )

    events = [r for r in results if r is not None]
    assert len(events) == 2
    ids = {e.id for e in events}
    assert ids == {id1, id2}, "Both events should be dequeued without conflict"


async def test_dequeue_multi_source(db_pool):
    """Dequeue should accept multiple sources."""
    gw = Gateway(db_pool)
    await gw.submit(EventSource.HEARTBEAT, "heartbeat:multi")

    event = await gw.dequeue([EventSource.HEARTBEAT, EventSource.CRON, EventSource.MAINTENANCE])
    assert event is not None
    assert event.source == EventSource.HEARTBEAT


# ============================================================================
# Complete / Fail
# ============================================================================


async def test_complete_sets_status_and_timestamp(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(EventSource.HEARTBEAT, "heartbeat:test:complete")
    event = await gw.dequeue([EventSource.HEARTBEAT])
    assert event is not None

    await gw.complete(event.id, {"decision": "observe"})

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM gateway_events WHERE id = $1", event.id
        )
    assert row["status"] == "completed"
    assert row["completed_at"] is not None
    assert row["started_at"] is not None

    import json

    result = json.loads(row["result"]) if isinstance(row["result"], str) else row["result"]
    assert result["decision"] == "observe"


async def test_complete_without_result(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(EventSource.MAINTENANCE, "maint:test:complete-no-result")
    event = await gw.dequeue([EventSource.MAINTENANCE])
    assert event is not None

    await gw.complete(event.id)

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT status, result FROM gateway_events WHERE id = $1", event.id
        )
    assert row["status"] == "completed"
    assert row["result"] is None


async def test_fail_sets_error(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(EventSource.CRON, "cron:test:fail")
    event = await gw.dequeue([EventSource.CRON])
    assert event is not None

    await gw.fail(event.id, "Connection timeout")

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM gateway_events WHERE id = $1", event.id
        )
    assert row["status"] == "failed"
    assert row["error"] == "Connection timeout"
    assert row["completed_at"] is not None


# ============================================================================
# Reclaim / Cleanup
# ============================================================================


async def test_reclaim_resets_stale_processing_event(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(EventSource.INTERNAL, "internal:reclaim:stale")
    event = await gw.dequeue([EventSource.INTERNAL])
    assert event is not None
    assert event.id == event_id

    async with db_pool.acquire() as conn:
        await conn.execute(
            "UPDATE gateway_events SET started_at = now() - interval '15 minutes' "
            "WHERE id = $1",
            event_id,
        )

    reclaimed = await gw.reclaim()
    assert reclaimed >= 1

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT status, started_at FROM gateway_events WHERE id = $1",
            event_id,
        )
    assert row["status"] == "pending"
    assert row["started_at"] is None


async def test_reclaim_accepts_legacy_string_interval(db_pool):
    gw = Gateway(db_pool)

    reclaimed = await gw.reclaim("10 minutes")

    assert isinstance(reclaimed, int)


async def test_cleanup_removes_old_events(db_pool):
    gw = Gateway(db_pool)

    # Create events in terminal states (completed, failed, recorded)
    id1 = await gw.record(EventSource.CHAT, "chat:cleanup:1")
    id2 = await gw.record(EventSource.CHAT, "chat:cleanup:2")

    # Also create one that goes through submit -> dequeue -> fail
    id3 = await gw.submit(EventSource.CHANNEL, "channel:cleanup:3")
    ev = await gw.dequeue([EventSource.CHANNEL])
    assert ev is not None
    assert ev.id == id3
    await gw.fail(ev.id, "test error")

    # Back-date the events so cleanup will catch them
    async with db_pool.acquire() as conn:
        await conn.execute(
            "UPDATE gateway_events SET created_at = now() - interval '8 days' "
            "WHERE id = ANY($1::bigint[])",
            [id1, id2, id3],
        )

        # Run cleanup with 7-day threshold
        deleted = await conn.fetchval("SELECT gateway_cleanup('7 days'::interval)")
    assert deleted >= 3


async def test_cleanup_preserves_recent_events(db_pool):
    gw = Gateway(db_pool)
    recent_id = await gw.record(EventSource.CHAT, "chat:cleanup:recent")

    async with db_pool.acquire() as conn:
        deleted = await conn.fetchval("SELECT gateway_cleanup('7 days'::interval)")

    # Recent event should still exist
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id FROM gateway_events WHERE id = $1", recent_id
        )
    assert row is not None


# ============================================================================
# Recent
# ============================================================================


async def test_recent_returns_events_in_order(db_pool):
    gw = Gateway(db_pool)

    # Create a few events
    ids = []
    for i in range(3):
        eid = await gw.record(EventSource.CHAT, f"chat:recent:order-{i}")
        ids.append(eid)

    events = await gw.recent(source=EventSource.CHAT, limit=10)
    assert len(events) >= 3

    # Most recent first
    recent_ids = [e.id for e in events]
    for i in range(len(recent_ids) - 1):
        assert recent_ids[i] > recent_ids[i + 1], "Events should be in descending order"


async def test_recent_filters_by_source(db_pool):
    gw = Gateway(db_pool)
    await gw.record(EventSource.CHAT, "chat:recent:filter")

    events = await gw.recent(source=EventSource.WEBHOOK, limit=10)
    # No webhook events should exist
    for e in events:
        assert e.source == EventSource.WEBHOOK


async def test_recent_without_filter(db_pool):
    gw = Gateway(db_pool)
    await gw.record(EventSource.CHAT, "chat:recent:all")
    await gw.submit(EventSource.HEARTBEAT, "heartbeat:recent:all")

    events = await gw.recent(limit=100)
    sources = {e.source for e in events}
    assert len(sources) >= 2, "Should return events from multiple sources"


# ============================================================================
# GatewayEvent dataclass
# ============================================================================


async def test_gateway_event_from_record(db_pool):
    gw = Gateway(db_pool)
    event_id = await gw.submit(
        EventSource.SUB_AGENT,
        "sub_agent:task:abc",
        {"task": "summarize"},
    )

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM gateway_events WHERE id = $1", event_id
        )

    event = GatewayEvent.from_record(row)
    assert event.id == event_id
    assert event.source == EventSource.SUB_AGENT
    assert event.status == EventStatus.PENDING
    assert event.session_key == "sub_agent:task:abc"
    assert event.payload == {"task": "summarize"}
    assert event.correlation_id is not None
    assert event.created_at is not None
    assert event.result is None
    assert event.error is None
