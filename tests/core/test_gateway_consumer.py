"""
Tests for GatewayConsumer — event dequeue and dispatch.

Covers: handler registration, dispatch to correct handler, error handling,
skip when empty, heartbeat handler factory basics.
"""

from __future__ import annotations

import asyncio
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
# Helpers
# ============================================================================


def _make_handler(results: list[dict], return_value: dict | None = None):
    """Create a simple handler that records calls and returns a fixed value."""

    async def handler(event: GatewayEvent) -> dict[str, Any] | None:
        results.append({
            "id": event.id,
            "source": event.source.value,
            "payload": event.payload,
        })
        return return_value

    return handler


def _make_failing_handler(error_msg: str = "test error"):
    """Create a handler that always raises."""

    async def handler(event: GatewayEvent) -> dict[str, Any] | None:
        raise RuntimeError(error_msg)

    return handler


# ============================================================================
# Registration
# ============================================================================


async def test_register_adds_source(db_pool):
    consumer = GatewayConsumer(db_pool)
    assert consumer.sources == []

    consumer.register(EventSource.HEARTBEAT, _make_handler([]))
    assert EventSource.HEARTBEAT in consumer.sources

    consumer.register(EventSource.CRON, _make_handler([]))
    assert set(consumer.sources) == {EventSource.HEARTBEAT, EventSource.CRON}


# ============================================================================
# Dispatch
# ============================================================================


async def test_consumer_dispatches_to_correct_handler(db_pool):
    gw = Gateway(db_pool)
    hb_calls: list[dict] = []
    cron_calls: list[dict] = []

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.HEARTBEAT, _make_handler(hb_calls, {"ok": True}))
    consumer.register(EventSource.CRON, _make_handler(cron_calls, {"ok": True}))

    # Submit events
    hb_id = await gw.submit(EventSource.HEARTBEAT, "heartbeat:dispatch:1", {"hb": 1})
    cron_id = await gw.submit(EventSource.CRON, "cron:dispatch:1", {"cron": 1})

    # Run consumer for a short burst
    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.5)
    consumer.stop()
    await task

    # Verify dispatch
    assert len(hb_calls) == 1
    assert hb_calls[0]["id"] == hb_id
    assert hb_calls[0]["payload"]["hb"] == 1

    assert len(cron_calls) == 1
    assert cron_calls[0]["id"] == cron_id
    assert cron_calls[0]["payload"]["cron"] == 1

    # Verify events are completed in DB
    async with db_pool.acquire() as conn:
        hb_row = await conn.fetchrow("SELECT status, result FROM gateway_events WHERE id = $1", hb_id)
        assert hb_row["status"] == "completed"

        cron_row = await conn.fetchrow("SELECT status, result FROM gateway_events WHERE id = $1", cron_id)
        assert cron_row["status"] == "completed"


async def test_consumer_handles_dispatch_error(db_pool):
    gw = Gateway(db_pool)

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.WEBHOOK, _make_failing_handler("boom"))

    event_id = await gw.submit(EventSource.WEBHOOK, "webhook:error:1")

    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.5)
    consumer.stop()
    await task

    # Event should be marked as failed
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT status, error FROM gateway_events WHERE id = $1", event_id)
    assert row["status"] == "failed"
    assert "boom" in row["error"]


async def test_consumer_skips_when_queue_empty(db_pool):
    calls: list[dict] = []

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.SUB_AGENT, _make_handler(calls))

    # Run consumer with no events — should not crash
    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.3)
    consumer.stop()
    await task

    assert len(calls) == 0


async def test_consumer_ignores_unregistered_sources(db_pool):
    gw = Gateway(db_pool)
    calls: list[dict] = []

    consumer = GatewayConsumer(db_pool, poll_interval=0.1)
    consumer.register(EventSource.HEARTBEAT, _make_handler(calls))

    # Submit an event for an unregistered source — consumer won't dequeue it
    # because it only dequeues registered sources
    await gw.submit(EventSource.CHANNEL, "channel:ignored:1")

    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.3)
    consumer.stop()
    await task

    assert len(calls) == 0


async def test_consumer_processes_multiple_events_serially(db_pool):
    gw = Gateway(db_pool)
    calls: list[dict] = []

    consumer = GatewayConsumer(db_pool, poll_interval=0.05)
    consumer.register(EventSource.INTERNAL, _make_handler(calls, {"done": True}))

    # Submit 3 events
    ids = []
    for i in range(3):
        eid = await gw.submit(EventSource.INTERNAL, f"internal:serial:{i}")
        ids.append(eid)

    consumer.running = True
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(1.0)
    consumer.stop()
    await task

    # All 3 should have been processed
    assert len(calls) == 3
    processed_ids = [c["id"] for c in calls]
    for eid in ids:
        assert eid in processed_ids


async def test_consumer_stop_is_clean(db_pool):
    """Consumer should stop cleanly when stop() is called."""
    consumer = GatewayConsumer(db_pool, poll_interval=0.05)
    consumer.register(EventSource.HEARTBEAT, _make_handler([]))

    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.2)
    consumer.stop()

    # Should complete without hanging
    await asyncio.wait_for(task, timeout=2.0)
    assert not consumer.running


# ============================================================================
# Heartbeat handler factory
# ============================================================================


async def test_heartbeat_handler_factory_import():
    """Verify the create_heartbeat_handler factory is importable."""
    from services.worker_service import create_heartbeat_handler

    assert callable(create_heartbeat_handler)
