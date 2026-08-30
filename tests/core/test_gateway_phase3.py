"""
Tests for Phase 3 gateway features — webhooks, channel recording, SSE broadcast.

Covers: webhook event submission, channel event recording,
pg_notify for real-time broadcast, consumer dispatch of webhook events.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest

from core.gateway import (
    EventSource,
    EventStatus,
    Gateway,
    GatewayConsumer,
    GatewayEvent,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Webhook events
# ============================================================================


async def test_webhook_submit_creates_pending_event(db_pool):
    """Submitting a webhook event creates a pending row in gateway_events."""
    gw = Gateway(db_pool)
    event_id = await gw.submit(
        EventSource.WEBHOOK,
        "webhook:github",
        {"action": "push", "repo": "hexis"},
    )

    assert event_id is not None
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT source, status, session_key, payload FROM gateway_events WHERE id = $1",
            event_id,
        )
    assert row["source"] == "webhook"
    assert row["status"] == "pending"
    assert row["session_key"] == "webhook:github"
    payload = row["payload"] if isinstance(row["payload"], dict) else json.loads(row["payload"])
    assert payload["action"] == "push"


async def test_webhook_dequeue_and_complete(db_pool):
    """Webhook events can be dequeued and completed like any other event."""
    gw = Gateway(db_pool)

    # Drain any leftover pending webhook events from earlier tests
    while await gw.dequeue([EventSource.WEBHOOK]) is not None:
        pass

    event_id = await gw.submit(
        EventSource.WEBHOOK,
        "webhook:stripe",
        {"event": "payment.completed", "amount": 42},
    )

    event = await gw.dequeue([EventSource.WEBHOOK])
    assert event is not None
    assert event.id == event_id
    assert event.source == EventSource.WEBHOOK
    assert event.payload["event"] == "payment.completed"

    await gw.complete(event.id, {"processed": True})

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT status, result FROM gateway_events WHERE id = $1",
            event_id,
        )
    assert row["status"] == "completed"


async def test_webhook_consumer_dispatch(db_pool):
    """GatewayConsumer can dequeue and dispatch webhook events."""
    gw = Gateway(db_pool)

    # Drain any leftover pending webhook events
    while await gw.dequeue([EventSource.WEBHOOK]) is not None:
        pass

    calls: list[dict] = []

    async def webhook_handler(event: GatewayEvent) -> dict[str, Any] | None:
        calls.append({
            "id": event.id,
            "source": event.source.value,
            "payload": event.payload,
        })
        return {"handled": True}

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.WEBHOOK, webhook_handler)

    event_id = await gw.submit(
        EventSource.WEBHOOK,
        "webhook:test",
        {"test": True},
    )

    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.5)
    consumer.stop()
    await task

    assert len(calls) == 1
    assert calls[0]["id"] == event_id
    assert calls[0]["payload"]["test"] is True

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT status FROM gateway_events WHERE id = $1",
            event_id,
        )
    assert row["status"] == "completed"


# ============================================================================
# Channel event recording
# ============================================================================


async def test_channel_record_creates_recorded_event(db_pool):
    """Channel events use record-and-dispatch (status='recorded')."""
    gw = Gateway(db_pool)
    event_id = await gw.record(
        EventSource.CHANNEL,
        "channel:discord:123456:user789",
        {"message": "Hello from Discord", "sender": "TestUser"},
    )

    assert event_id is not None
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT source, status, session_key, payload FROM gateway_events WHERE id = $1",
            event_id,
        )
    assert row["source"] == "channel"
    assert row["status"] == "recorded"
    assert "discord" in row["session_key"]
    payload = row["payload"] if isinstance(row["payload"], dict) else json.loads(row["payload"])
    assert payload["sender"] == "TestUser"


async def test_channel_events_not_dequeued(db_pool):
    """Recorded channel events are NOT picked up by dequeue (they aren't pending)."""
    gw = Gateway(db_pool)
    await gw.record(
        EventSource.CHANNEL,
        "channel:telegram:99:sender1",
        {"message": "test"},
    )

    event = await gw.dequeue([EventSource.CHANNEL])
    assert event is None


async def test_channel_recent_query(db_pool):
    """Channel events appear in recent() queries filtered by source."""
    gw = Gateway(db_pool)
    await gw.record(
        EventSource.CHANNEL,
        "channel:slack:room1:user1",
        {"message": "Slack message"},
    )

    events = await gw.recent(source=EventSource.CHANNEL, limit=5)
    assert len(events) >= 1
    assert events[0].source == EventSource.CHANNEL


# ============================================================================
# pg_notify for SSE broadcast
# ============================================================================


async def test_pg_notify_fires_on_submit(db_pool):
    """Submitting an event fires a pg_notify on the 'gateway_events' channel."""
    received: list[str] = []

    def on_notify(conn, pid, channel, payload):
        received.append(payload)

    conn = await db_pool.acquire()
    try:
        await conn.add_listener("gateway_events", on_notify)

        gw = Gateway(db_pool)
        event_id = await gw.submit(
            EventSource.WEBHOOK,
            "webhook:notify_test",
            {"test": "notify"},
        )

        # Give the notification a moment to arrive
        await asyncio.sleep(0.3)

        assert len(received) >= 1
        assert str(event_id) in received
    finally:
        await conn.remove_listener("gateway_events", on_notify)
        await db_pool.release(conn)


async def test_pg_notify_not_fired_on_record(db_pool):
    """Record-mode events (chat, channel) do NOT fire pg_notify."""
    received: list[str] = []

    def on_notify(conn, pid, channel, payload):
        received.append(payload)

    conn = await db_pool.acquire()
    try:
        await conn.add_listener("gateway_events", on_notify)

        gw = Gateway(db_pool)
        await gw.record(
            EventSource.CHAT,
            "chat:api:test",
            {"message": "no notify expected"},
        )

        await asyncio.sleep(0.3)
        assert len(received) == 0
    finally:
        await conn.remove_listener("gateway_events", on_notify)
        await db_pool.release(conn)


# ============================================================================
# Mixed-source consumer
# ============================================================================


async def test_consumer_handles_multiple_source_types(db_pool):
    """Consumer can handle both heartbeat and webhook events in the same loop."""
    gw = Gateway(db_pool)

    # Drain any leftover pending events
    while await gw.dequeue([EventSource.HEARTBEAT, EventSource.WEBHOOK]) is not None:
        pass

    hb_calls: list[dict] = []
    wh_calls: list[dict] = []

    async def hb_handler(event: GatewayEvent) -> dict[str, Any] | None:
        hb_calls.append({"id": event.id})
        return {"ok": True}

    async def wh_handler(event: GatewayEvent) -> dict[str, Any] | None:
        wh_calls.append({"id": event.id})
        return {"ok": True}

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.HEARTBEAT, hb_handler)
    consumer.register(EventSource.WEBHOOK, wh_handler)

    hb_id = await gw.submit(EventSource.HEARTBEAT, "heartbeat:mixed:1", {"hb": True})
    wh_id = await gw.submit(EventSource.WEBHOOK, "webhook:mixed:1", {"wh": True})

    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.5)
    consumer.stop()
    await task

    assert len(hb_calls) == 1
    assert hb_calls[0]["id"] == hb_id
    assert len(wh_calls) == 1
    assert wh_calls[0]["id"] == wh_id
