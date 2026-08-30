"""Tests for the DB-native transactional outbox (db/42_functions_outbox.sql).

Replaces the broken `INSERT INTO external_calls` path in the queue_user_message
tool: tools durably enqueue via queue_outbox_message; the maintenance worker
claims → publishes → marks published (or requeues on failure).
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


async def test_queue_claim_publish_lifecycle(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await conn.fetchval(
                "SELECT queue_outbox_message($1::text, $2::text, 'tool')",
                "Hello Eric, checking in.", "status",
            )
            assert mid is not None

            # Row is pending with a build_user_message envelope.
            row = await conn.fetchrow("SELECT status, envelope FROM outbox_messages WHERE id = $1", mid)
            assert row["status"] == "pending"
            env = _j(row["envelope"])
            assert env["kind"] == "user"
            assert env["payload"]["message"] == "Hello Eric, checking in."
            assert env["payload"]["intent"] == "status"

            # Claim marks it publishing and returns the envelope for delivery.
            claimed = _j(await conn.fetchval("SELECT claim_pending_outbox(50)"))
            assert [c["id"] for c in claimed] == [str(mid)]
            assert claimed[0]["envelope"]["payload"]["message"] == "Hello Eric, checking in."
            assert await conn.fetchval("SELECT status FROM outbox_messages WHERE id = $1", mid) == "publishing"

            # A second claim returns nothing (already publishing, not stale).
            assert _j(await conn.fetchval("SELECT claim_pending_outbox(50)")) == []

            # Marking published closes it out.
            n = await conn.fetchval("SELECT mark_outbox_published($1::uuid[])", [mid])
            assert n == 1
            assert await conn.fetchval("SELECT status FROM outbox_messages WHERE id = $1", mid) == "published"
        finally:
            await tr.rollback()


async def test_requeue_returns_to_pending(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await conn.fetchval("SELECT queue_outbox_message('retry me', NULL, 'tool')")
            await conn.fetchval("SELECT claim_pending_outbox(50)")  # -> publishing
            n = await conn.fetchval("SELECT requeue_outbox($1::uuid[])", [mid])
            assert n == 1
            assert await conn.fetchval("SELECT status FROM outbox_messages WHERE id = $1", mid) == "pending"
            # It is claimable again.
            claimed = _j(await conn.fetchval("SELECT claim_pending_outbox(50)"))
            assert [c["id"] for c in claimed] == [str(mid)]
        finally:
            await tr.rollback()


async def test_stale_publishing_is_reclaimed(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mid = await conn.fetchval("SELECT queue_outbox_message('stuck', NULL, 'tool')")
            await conn.fetchval("SELECT claim_pending_outbox(50)")  # -> publishing
            # Simulate a publisher that died mid-flight.
            await conn.execute(
                "UPDATE outbox_messages SET claimed_at = CURRENT_TIMESTAMP - interval '10 minutes' WHERE id = $1",
                mid,
            )
            reclaimed = _j(await conn.fetchval("SELECT claim_pending_outbox(50, 60)"))
            assert [c["id"] for c in reclaimed] == [str(mid)]
        finally:
            await tr.rollback()


async def test_empty_message_rejected(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception):
            await conn.fetchval("SELECT queue_outbox_message('   ', NULL, 'tool')")


async def test_channel_delivery_obligation_lifecycle(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            raw = await conn.fetchval(
                """
                SELECT upsert_channel_delivery_obligation(
                    'test-delivery-lifecycle',
                    'outbox-1',
                    'telegram',
                    'chat-1',
                    'eric',
                    NULL,
                    'hello',
                    '{"kind": "text", "value": "hello"}'::jsonb,
                    'direct'
                )
                """
            )
            info = _j(raw)
            assert info["state"] == "pending"
            assert info["already_delivered"] is False

            claimed = _j(
                await conn.fetchval(
                    "SELECT claim_channel_delivery_obligation($1::uuid)",
                    info["id"],
                )
            )
            assert claimed["claimed"] is True
            assert claimed["attempts"] == 1

            delivered = _j(
                await conn.fetchval(
                    "SELECT mark_channel_delivery_obligation_delivered($1::uuid)",
                    info["id"],
                )
            )
            assert delivered["updated"] == 1
            assert await conn.fetchval(
                "SELECT state FROM channel_delivery_obligations WHERE id = $1::uuid",
                info["id"],
            ) == "delivered"

            duplicate = _j(
                await conn.fetchval(
                    """
                    SELECT upsert_channel_delivery_obligation(
                        'test-delivery-lifecycle',
                        'outbox-1',
                        'telegram',
                        'chat-1',
                        'eric',
                        NULL,
                        'hello again',
                        '{"kind": "text", "value": "hello again"}'::jsonb,
                        'direct'
                    )
                    """
                )
            )
            assert duplicate["already_delivered"] is True
        finally:
            await tr.rollback()


async def test_channel_delivery_obligation_recovery_marks_ambiguous_replay(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            raw = await conn.fetchval(
                """
                SELECT upsert_channel_delivery_obligation(
                    'test-delivery-recovery',
                    'outbox-2',
                    'slack',
                    'C123',
                    'eric',
                    'thread-1',
                    'recover me',
                    '{"kind": "text", "value": "recover me"}'::jsonb,
                    'direct'
                )
                """
            )
            info = _j(raw)
            await conn.fetchval(
                "SELECT claim_channel_delivery_obligation($1::uuid)",
                info["id"],
            )
            await conn.execute(
                """
                UPDATE channel_delivery_obligations
                SET updated_at = CURRENT_TIMESTAMP - INTERVAL '10 minutes'
                WHERE id = $1::uuid
                """,
                info["id"],
            )

            recovered = _j(
                await conn.fetchval(
                    """
                    SELECT claim_recoverable_channel_deliveries(
                        10,
                        INTERVAL '2 minutes',
                        3,
                        INTERVAL '7 days'
                    )
                    """
                )
            )
            assert [row["id"] for row in recovered] == [info["id"]]
            assert recovered[0]["needs_marker"] is True
            assert recovered[0]["attempts"] == 2
        finally:
            await tr.rollback()


async def test_channel_delivery_obligation_failed_retry_waits_for_next_attempt(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            raw = await conn.fetchval(
                """
                SELECT upsert_channel_delivery_obligation(
                    'test-delivery-failed-wait',
                    'outbox-3',
                    'discord',
                    'channel-1',
                    'eric',
                    NULL,
                    'retry later',
                    '{"kind": "text", "value": "retry later"}'::jsonb,
                    'direct'
                )
                """
            )
            info = _j(raw)
            await conn.fetchval(
                "SELECT claim_channel_delivery_obligation($1::uuid)",
                info["id"],
            )
            failed = _j(
                await conn.fetchval(
                    """
                    SELECT mark_channel_delivery_obligation_failed(
                        $1::uuid,
                        'rate limited',
                        3600
                    )
                    """,
                    info["id"],
                )
            )
            assert failed["updated"] == 1

            assert _j(
                await conn.fetchval("SELECT claim_recoverable_channel_deliveries(10)")
            ) == []

            await conn.execute(
                """
                UPDATE channel_delivery_obligations
                SET next_attempt_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
                WHERE id = $1::uuid
                """,
                info["id"],
            )
            recovered = _j(
                await conn.fetchval("SELECT claim_recoverable_channel_deliveries(10)")
            )
            assert [row["id"] for row in recovered] == [info["id"]]
            assert recovered[0]["needs_marker"] is True
        finally:
            await tr.rollback()
