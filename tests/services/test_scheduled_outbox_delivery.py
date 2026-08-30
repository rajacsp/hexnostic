from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from services.worker_service import MaintenanceWorker
from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_scheduled_outbox_delivers_to_web_inbox_without_channel_worker(db_pool):
    marker = get_test_identifier("scheduled-web-inbox")
    message = f"scheduled inbox note {marker}"
    worker = MaintenanceWorker()
    worker.pool = db_pool
    worker.bridge = None

    async with db_pool.acquire() as conn:
        task_id = await conn.fetchval(
            """
            SELECT create_scheduled_task(
                $1,
                'once',
                $2::jsonb,
                'queue_user_message',
                $3::jsonb,
                'UTC',
                NULL,
                'active',
                1,
                'agent',
                '{"mode": "outbox"}'::jsonb
            )
            """,
            f"scheduled-web-inbox-{marker}",
            json.dumps({"run_at": "2999-01-01T00:00:00Z"}),
            json.dumps({"message": message, "intent": "status"}),
        )
        await conn.execute(
            "UPDATE scheduled_tasks SET next_run_at = NOW() - INTERVAL '1 second' WHERE id = $1",
            task_id,
        )

    try:
        result = await worker._run_scheduled_tasks()
        assert result["ran"] >= 1
        assert result["web_inbox_delivered"] >= 1

        async with db_pool.acquire() as conn:
            delivered = await conn.fetchrow(
                "SELECT message, intent, delivered_at FROM web_inbox WHERE message = $1",
                message,
            )
            task = await conn.fetchrow(
                "SELECT status, run_count, last_run_at FROM scheduled_tasks WHERE id = $1",
                task_id,
            )
        assert delivered["message"] == message
        assert delivered["intent"] == "status"
        assert delivered["delivered_at"] <= datetime.now(timezone.utc)
        assert task["status"] == "disabled"
        assert task["run_count"] == 1
        assert task["last_run_at"] is not None
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM web_inbox WHERE message = $1", message)
            await conn.execute("DELETE FROM scheduled_tasks WHERE id = $1", task_id)
