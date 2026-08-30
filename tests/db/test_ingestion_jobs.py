"""Durable ingestion jobs (#87 stage 2): the queue's claim/backoff/cancel
policy, all in SQL.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _enqueue(conn, content="Job pin content long enough.", chash=None, kind="text"):
    return await conn.fetchval(
        "SELECT enqueue_ingestion_job($1, '{\"title\": \"pin\"}'::jsonb, $2, $3)",
        kind, content, chash,
    )


async def test_enqueue_caps_and_idempotency(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT set_config('ingest.job_max_content_chars', '50'::jsonb)")
            # Each expected raise runs in a savepoint so the outer transaction
            # survives the abort.
            with pytest.raises(Exception, match="the job cap is 50"):
                async with conn.transaction():
                    await _enqueue(conn, content="x" * 51)
            job_a = await _enqueue(conn, chash="hash-idem")
            job_b = await _enqueue(conn, chash="hash-idem")
            with pytest.raises(Exception, match="kind must be text, url, or artifact"):
                async with conn.transaction():
                    await _enqueue(conn, kind="carrier_pigeon")
            with pytest.raises(Exception, match="require content"):
                async with conn.transaction():
                    await conn.fetchval(
                        "SELECT enqueue_ingestion_job('text', '{}'::jsonb, NULL, NULL)"
                    )
        finally:
            await tr.rollback()

    assert job_a == job_b  # active-hash enqueue is idempotent


async def test_claim_complete_lifecycle(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            job_id = await _enqueue(conn)
            claimed = json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(5)"))
            assert [c["id"] for c in claimed] == [str(job_id)]
            assert claimed[0]["status"] == "in_progress"
            again = json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(5)"))
            assert again == []  # claimed jobs are not re-claimed while fresh
            done = json.loads(await conn.fetchval(
                "SELECT complete_ingestion_job($1, '{\"memories_created\": 4}'::jsonb)", job_id
            ))
            status = json.loads(await conn.fetchval("SELECT get_ingestion_job($1)", job_id))
        finally:
            await tr.rollback()

    assert done["status"] == "completed"
    assert status["result"]["memories_created"] == 4
    assert "content" not in status  # get never hauls the payload text back


async def test_fail_backs_off_then_goes_terminal(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            job_id = await _enqueue(conn)
            await conn.execute(
                "UPDATE ingestion_jobs SET max_attempts = 2 WHERE id = $1", job_id
            )
            json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)"))
            first = json.loads(await conn.fetchval(
                "SELECT fail_ingestion_job($1, 'boom one')", job_id
            ))
            assert first["status"] == "pending"
            assert first["retry_in_seconds"] == 60  # base * 2^0
            # Not due yet — backoff holds it out of the claimable set.
            assert json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)")) == []
            await conn.execute(
                "UPDATE ingestion_jobs SET next_attempt_at = CURRENT_TIMESTAMP WHERE id = $1",
                job_id,
            )
            json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)"))
            second = json.loads(await conn.fetchval(
                "SELECT fail_ingestion_job($1, 'boom two')", job_id
            ))
        finally:
            await tr.rollback()

    assert second["status"] == "failed"  # attempts exhausted → terminal


async def test_stale_claim_is_reclaimed(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            job_id = await _enqueue(conn)
            json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)"))
            await conn.execute(
                "UPDATE ingestion_jobs SET claimed_at = CURRENT_TIMESTAMP - INTERVAL '2 hours' WHERE id = $1",
                job_id,
            )
            reclaimed = json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)"))
            attempts = await conn.fetchval(
                "SELECT attempts FROM ingestion_jobs WHERE id = $1", job_id
            )
        finally:
            await tr.rollback()

    assert [c["id"] for c in reclaimed] == [str(job_id)]
    assert attempts == 2  # crash recovery counts as a fresh attempt


async def test_progress_heartbeat_and_cancel(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            job_id = await _enqueue(conn)
            json.loads(await conn.fetchval("SELECT claim_ingestion_jobs(1)"))
            flag = await conn.fetchval(
                "SELECT update_ingestion_job_progress($1, '{\"sections_done\": 3}'::jsonb)",
                job_id,
            )
            assert flag is False  # no cancel requested yet
            cancel = json.loads(await conn.fetchval(
                "SELECT cancel_ingestion_job($1)", job_id
            ))
            assert cancel["status"] == "cancel_requested"
            flag2 = await conn.fetchval(
                "SELECT update_ingestion_job_progress($1, '{\"sections_done\": 4}'::jsonb)",
                job_id,
            )
            assert flag2 is True  # the worker sees the cancel on its heartbeat
            final = json.loads(await conn.fetchval(
                "SELECT fail_ingestion_job($1, 'cancelled by operator')", job_id
            ))
        finally:
            await tr.rollback()

    assert final["status"] == "cancelled"
