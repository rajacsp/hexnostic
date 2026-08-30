"""
Centralized event gateway.

All events -- chat, heartbeat, cron, webhook, channel -- flow through here.
Two modes:
  - record-and-dispatch: for chat (event recorded, execution inline)
  - queue-and-consume: for everything else (event queued, worker dequeues)
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from typing import Any, Awaitable, Callable

import asyncpg

logger = logging.getLogger(__name__)


class EventSource(str, Enum):
    CHAT = "chat"
    HEARTBEAT = "heartbeat"
    CRON = "cron"
    MAINTENANCE = "maintenance"
    WEBHOOK = "webhook"
    CHANNEL = "channel"
    INTERNAL = "internal"
    SUB_AGENT = "sub_agent"


class EventStatus(str, Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"
    RECORDED = "recorded"


@dataclass
class GatewayEvent:
    id: int
    source: EventSource
    status: EventStatus
    session_key: str
    payload: dict
    result: dict | None
    error: str | None
    correlation_id: str
    created_at: datetime
    started_at: datetime | None
    completed_at: datetime | None

    @classmethod
    def from_record(cls, row: asyncpg.Record) -> GatewayEvent:
        raw_payload = row["payload"]
        if isinstance(raw_payload, dict):
            payload = raw_payload
        elif isinstance(raw_payload, str):
            payload = json.loads(raw_payload)
        else:
            payload = {}

        raw_result = row["result"]
        if isinstance(raw_result, str):
            result = json.loads(raw_result)
        else:
            result = raw_result

        return cls(
            id=row["id"],
            source=EventSource(row["source"]),
            status=EventStatus(row["status"]),
            session_key=row["session_key"],
            payload=payload,
            result=result,
            error=row["error"],
            correlation_id=str(row["correlation_id"]),
            created_at=row["created_at"],
            started_at=row["started_at"],
            completed_at=row["completed_at"],
        )


class Gateway:
    """Centralized event router. Thin wrapper over gateway_events table."""

    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    # -- Submit (both modes) ----------------------------------------

    async def record(
        self,
        source: EventSource,
        session_key: str,
        payload: dict | None = None,
    ) -> int:
        """Record an event that will be processed inline (chat mode).

        Status is set to 'recorded' -- it never enters the queue.
        """
        return await self.pool.fetchval(
            "SELECT gateway_submit($1, $2, $3, 'recorded'::event_status)",
            source.value,
            session_key,
            json.dumps(payload or {}),
        )

    async def submit(
        self,
        source: EventSource,
        session_key: str,
        payload: dict | None = None,
    ) -> int:
        """Submit an event to the queue for async processing."""
        event_id = await self.pool.fetchval(
            "SELECT gateway_submit($1, $2, $3)",
            source.value,
            session_key,
            json.dumps(payload or {}),
        )
        # Wake up listeners via pg_notify
        await self.pool.execute(
            "SELECT pg_notify('gateway_events', $1)",
            str(event_id),
        )
        return event_id

    # -- Consume (queue mode only) ----------------------------------

    async def dequeue(
        self,
        sources: list[EventSource],
    ) -> GatewayEvent | None:
        """Atomically claim the next pending event. Returns None if empty."""
        row = await self.pool.fetchrow(
            "SELECT * FROM gateway_dequeue($1)",
            [s.value for s in sources],
        )
        if row and row["id"] is not None:
            return GatewayEvent.from_record(row)
        return None

    async def complete(self, event_id: int, result: dict | None = None) -> None:
        """Mark an event as completed with an optional result summary."""
        await self.pool.execute(
            "SELECT gateway_complete($1, $2::jsonb)",
            event_id,
            json.dumps(result) if result else None,
        )

    async def fail(self, event_id: int, error: str) -> None:
        """Mark an event as failed with an error message."""
        await self.pool.execute(
            "SELECT gateway_fail($1, $2)",
            event_id,
            error,
        )

    # -- Reclaim ----------------------------------------------------

    async def reclaim(self, stale_after: timedelta | str = timedelta(minutes=10)) -> int:
        """Reset stale processing events back to pending.

        Call on startup to recover from worker crashes.
        """
        if isinstance(stale_after, str):
            count = await self.pool.fetchval(
                "SELECT gateway_reclaim($1::text::interval)",
                stale_after,
            )
            return count or 0

        count = await self.pool.fetchval(
            "SELECT gateway_reclaim($1::interval)",
            stale_after,
        )
        return count or 0

    # -- Query ------------------------------------------------------

    async def recent(
        self,
        source: EventSource | None = None,
        limit: int = 50,
    ) -> list[GatewayEvent]:
        """Recent events for dashboard/debugging."""
        if source:
            rows = await self.pool.fetch(
                "SELECT * FROM gateway_events WHERE source = $1 "
                "ORDER BY created_at DESC LIMIT $2",
                source.value,
                limit,
            )
        else:
            rows = await self.pool.fetch(
                "SELECT * FROM gateway_events "
                "ORDER BY created_at DESC LIMIT $1",
                limit,
            )
        return [GatewayEvent.from_record(r) for r in rows]


# Type alias for event handler callbacks
EventHandler = Callable[[GatewayEvent], Awaitable[dict[str, Any] | None]]


class GatewayConsumer:
    """Dequeues events from the gateway and dispatches to registered handlers.

    Usage:
        consumer = GatewayConsumer(pool)
        consumer.register(EventSource.HEARTBEAT, handle_heartbeat)
        consumer.register(EventSource.MAINTENANCE, handle_maintenance)
        await consumer.run()
    """

    def __init__(
        self,
        pool: asyncpg.Pool,
        poll_interval: float = 1.0,
    ):
        self.pool = pool
        self.gateway = Gateway(pool)
        self.poll_interval = poll_interval
        self.running = False
        self._handlers: dict[EventSource, EventHandler] = {}
        self._on_stop: Callable[[], None] | None = None

    def register(self, source: EventSource, handler: EventHandler) -> None:
        """Register a handler for a specific event source."""
        self._handlers[source] = handler

    @property
    def sources(self) -> list[EventSource]:
        """Event sources this consumer will dequeue."""
        return list(self._handlers.keys())

    async def run(self) -> None:
        """Main consumer loop: dequeue -> dispatch -> complete/fail."""
        self.running = True

        # Reclaim stale events from previous crashes
        try:
            reclaimed = await self.gateway.reclaim()
            if reclaimed:
                logger.info("Reclaimed %d stale processing events", reclaimed)
        except Exception as exc:
            logger.warning("Reclaim failed (non-fatal): %s", exc)

        logger.info(
            "GatewayConsumer started (sources: %s)",
            ", ".join(s.value for s in self.sources),
        )

        try:
            while self.running:
                try:
                    event = await self.gateway.dequeue(self.sources)
                    if event is None:
                        await asyncio.sleep(self.poll_interval)
                        continue

                    await self._dispatch(event)

                except Exception as exc:
                    logger.error("Consumer loop error: %s", exc)
                    await asyncio.sleep(self.poll_interval)
        finally:
            logger.info("GatewayConsumer stopped")

    async def _dispatch(self, event: GatewayEvent) -> None:
        """Dispatch an event to its registered handler."""
        handler = self._handlers.get(event.source)
        if handler is None:
            logger.warning(
                "No handler for event source %s (event %d)",
                event.source.value,
                event.id,
            )
            await self.gateway.fail(event.id, f"No handler for source: {event.source.value}")
            return

        try:
            result = await handler(event)
            await self.gateway.complete(event.id, result)
            logger.info(
                "Event %d (%s) completed",
                event.id,
                event.source.value,
            )
        except Exception as exc:
            logger.error(
                "Event %d (%s) failed: %s",
                event.id,
                event.source.value,
                exc,
            )
            await self.gateway.fail(event.id, str(exc))

    def stop(self) -> None:
        """Signal the consumer to stop."""
        self.running = False
