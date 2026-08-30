from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _coerce_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def test_worker_runtime_records_liveness_and_task_runs(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            worker_id = await conn.fetchval(
                """
                SELECT register_worker_instance(
                    'maintenance',
                    'test-instance',
                    '{"process_id": 123, "host_name": "test-host"}'::jsonb
                )
                """
            )
            await conn.fetchval(
                "SELECT mark_worker_instance_seen($1::uuid, 'running')",
                worker_id,
            )
            run_id = await conn.fetchval(
                """
                SELECT start_worker_task_run(
                    $1::uuid,
                    'recmem_embedding',
                    '{"test": true}'::jsonb
                )
                """,
                worker_id,
            )
            await conn.fetchval(
                "SELECT complete_worker_task_run($1::uuid, '{\"embedded\": 2}'::jsonb)",
                run_id,
            )

            runtime = await conn.fetchrow(
                "SELECT * FROM worker_runtime_status WHERE id = $1::uuid",
                worker_id,
            )
            assert runtime is not None
            assert runtime["mode"] == "maintenance"
            assert runtime["status"] == "running"
            assert runtime["last_success_at"] is not None
            assert runtime["current_task_run_id"] is None

            task = await conn.fetchrow(
                "SELECT * FROM worker_task_status WHERE task_type = 'recmem_embedding'"
            )
            assert task is not None
            assert task["latest_status"] == "completed"
            assert _coerce_json(task["latest_result"])["embedded"] == 2
            assert task["failures_since_success"] == 0
        finally:
            await tr.rollback()


async def test_worker_runtime_records_observed_task_outcome(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            worker_id = await conn.fetchval(
                "SELECT register_worker_instance('maintenance', 'test-instance', '{}'::jsonb)"
            )
            run_id = await conn.fetchval(
                """
                SELECT record_worker_task_outcome(
                    $1::uuid,
                    'source_chunk_embedding',
                    'completed',
                    CURRENT_TIMESTAMP - INTERVAL '2 seconds',
                    CURRENT_TIMESTAMP,
                    '{"claimed": 4, "embedded": 4}'::jsonb,
                    NULL,
                    '{}'::jsonb
                )
                """,
                worker_id,
            )
            assert run_id is not None

            task = await conn.fetchrow(
                "SELECT * FROM worker_task_status WHERE task_type = 'source_chunk_embedding'"
            )
            assert task is not None
            assert task["latest_status"] == "completed"
            assert _coerce_json(task["latest_result"])["embedded"] == 4

            runtime = await conn.fetchrow(
                "SELECT last_success_at, last_error_at FROM worker_instances WHERE id = $1::uuid",
                worker_id,
            )
            assert runtime["last_success_at"] is not None
            assert runtime["last_error_at"] is None
        finally:
            await tr.rollback()


async def test_worker_runtime_recovers_stale_runs(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            worker_id = await conn.fetchval(
                "SELECT register_worker_instance('maintenance', 'test-instance', '{}'::jsonb)"
            )
            run_id = await conn.fetchval(
                "SELECT start_worker_task_run($1::uuid, 'memory_embedding', '{}'::jsonb)",
                worker_id,
            )
            await conn.execute(
                """
                UPDATE worker_instances
                SET last_seen_at = CURRENT_TIMESTAMP - INTERVAL '20 minutes'
                WHERE id = $1::uuid
                """,
                worker_id,
            )
            await conn.execute(
                """
                UPDATE worker_task_runs
                SET started_at = CURRENT_TIMESTAMP - INTERVAL '20 minutes'
                WHERE id = $1::uuid
                """,
                run_id,
            )

            raw = await conn.fetchval("SELECT recover_interrupted_worker_runs('10 minutes')")
            recovered = _coerce_json(raw)
            assert recovered["stale_workers"] == 1
            assert recovered["unknown_runs"] == 1

            runtime = await conn.fetchrow(
                "SELECT status, current_task_run_id FROM worker_instances WHERE id = $1::uuid",
                worker_id,
            )
            run = await conn.fetchrow(
                "SELECT status, finished_at, error FROM worker_task_runs WHERE id = $1::uuid",
                run_id,
            )
            assert runtime["status"] == "stale"
            assert runtime["current_task_run_id"] is None
            assert run["status"] == "unknown"
            assert run["finished_at"] is not None
            assert "worker stopped" in run["error"]
        finally:
            await tr.rollback()


async def test_worker_start_storm_detection_records_backoff(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            latest = None
            for i in range(4):
                latest = _coerce_json(
                    await conn.fetchval(
                        """
                        SELECT record_worker_start_and_check_storm(
                            'maintenance',
                            'storm-test',
                            jsonb_build_object('process_id', $1::int, 'host_name', 'test-host'),
                            2,
                            120,
                            300
                        )
                        """,
                        9000 + i,
                    )
                )
            assert latest is not None
            assert latest["storm"] is True
            assert latest["count"] == 4
            assert latest["backoff_seconds"] > 0

            row = await conn.fetchrow(
                """
                SELECT starts_last_2m, latest_start_at
                FROM worker_start_storm_status
                WHERE mode = 'maintenance' AND instance_name = 'storm-test'
                """
            )
            assert row is not None
            assert row["starts_last_2m"] == 4
            assert row["latest_start_at"] is not None
        finally:
            await tr.rollback()
