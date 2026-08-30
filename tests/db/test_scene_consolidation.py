"""Scene consolidation at session boundaries (#73, RecMem Rev 5 Phase 1):
an idle session's unconsumed units become ONE episode_create task; applied
scenes carry lived time + session; direct promotion is a 0.95 safety valve.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def _stub_get_embedding(conn, axis=1):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(
                array_agg((
                    array_fill(0.0::float, ARRAY[AXIS - 1]) ||
                    ARRAY[1.0::float] ||
                    array_fill(0.0::float, ARRAY[embedding_dimension() - AXIS])
                )::vector),
                ARRAY[]::vector[]
            )
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """.replace("AXIS", str(int(axis)))
    )


async def _seed_session_units(conn, session_id, count, *, minutes_ago=60, embedded=True, axis=1, start=0):
    ids = []
    for idx in range(start, start + count):
        unit_id = await conn.fetchval(
            """
            INSERT INTO subconscious_units (
                session_id, content, user_text, assistant_text,
                embedding, embedding_status, route_status, idempotency_key, turn_at
            )
            VALUES (
                $1::uuid, $2, $3, 'ok',
                CASE WHEN $4 THEN (
                    array_fill(0.0::float, ARRAY[$5::int - 1]) ||
                    ARRAY[1.0::float] ||
                    array_fill(0.0::float, ARRAY[embedding_dimension() - $5::int])
                )::vector ELSE NULL END,
                CASE WHEN $4 THEN 'embedded' ELSE 'pending' END,
                'unrouted', $6,
                CURRENT_TIMESTAMP - ($7::int || ' minutes')::interval + ($8::int || ' seconds')::interval
            )
            RETURNING id
            """,
            session_id,
            f"Eric: scene turn {idx} of {session_id}\n\nSamantha: ok",
            f"scene turn {idx} of {session_id}",
            embedded,
            int(axis),
            f"scene-test:{session_id}:{idx}",
            int(minutes_ago),
            idx * 30,
        )
        ids.append(unit_id)
    return ids


async def test_idle_session_becomes_one_scene_task(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            idle = "aaaaaaa1-0000-4000-8000-000000000001"
            fresh = "aaaaaaa2-0000-4000-8000-000000000002"
            idle_units = await _seed_session_units(conn, idle, 4, minutes_ago=60)
            await _seed_session_units(conn, fresh, 3, minutes_ago=2)

            result = _json(await conn.fetchval("SELECT enqueue_scene_consolidations()"))
            assert result["enqueued"] == 1

            tasks = await conn.fetch(
                """
                SELECT source_unit_ids, task_payload FROM recmem_consolidation_tasks
                WHERE task_type = 'episode_create'
                  AND task_payload->>'reason' = 'session_boundary'
                """
            )
            assert len(tasks) == 1
            payload = _json(tasks[0]["task_payload"])
            assert payload["session_id"] == idle
            assert set(tasks[0]["source_unit_ids"]) == set(idle_units)

            statuses = await conn.fetch(
                "SELECT route_status FROM subconscious_units WHERE id = ANY($1::uuid[])",
                idle_units,
            )
            assert {r["route_status"] for r in statuses} == {"create_queued"}

            # Idempotent: units are consumed, a second pass enqueues nothing.
            again = _json(await conn.fetchval("SELECT enqueue_scene_consolidations()"))
            assert again["enqueued"] == 0
        finally:
            await tr.rollback()


async def test_unembedded_session_defers(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            waiting = "aaaaaaa3-0000-4000-8000-000000000003"
            await _seed_session_units(conn, waiting, 2, minutes_ago=60)
            await _seed_session_units(conn, waiting, 1, minutes_ago=55, embedded=False, start=10)

            result = _json(await conn.fetchval("SELECT enqueue_scene_consolidations()"))
            assert result["enqueued"] == 0
        finally:
            await tr.rollback()


async def test_applied_scene_carries_lived_time_and_session(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn, axis=2)
            session = "aaaaaaa4-0000-4000-8000-000000000004"
            units = await _seed_session_units(conn, session, 3, minutes_ago=90, axis=2)
            _json(await conn.fetchval("SELECT enqueue_scene_consolidations()"))
            task_id = await conn.fetchval(
                "SELECT id FROM recmem_consolidation_tasks WHERE task_payload->>'session_id' = $1",
                session,
            )
            applied = _json(await conn.fetchval(
                "SELECT apply_recmem_episode_create($1::uuid, $2::jsonb)",
                task_id,
                json.dumps([{"content": "We talked through the scene-test plan.", "importance": 0.7}]),
            ))
            assert applied["memory_ids"]
            meta = _json(await conn.fetchval(
                "SELECT metadata->'recmem' FROM memories WHERE id = $1::uuid",
                applied["memory_ids"][0],
            ))
            assert meta["reason"] == "session_boundary"
            assert meta["session_id"] == session
            assert meta["occurred_from"] < meta["occurred_to"]

            linked = await conn.fetchval(
                "SELECT count(*) FROM memory_source_units WHERE memory_id = $1::uuid",
                applied["memory_ids"][0],
            )
            assert linked == len(units)
        finally:
            await tr.rollback()


async def test_direct_promotion_is_a_safety_valve(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn, axis=3)
            # Signal-phrase importance (0.8) stays below the 0.95 valve.
            ordinary = _json(await conn.fetchval(
                "SELECT record_chat_turn_memory('remember that i like teal', 'noted', NULL, 'valve-test-1', '{}'::jsonb)"
            ))
            assert ordinary["direct_promoted"] is False

            exceptional = _json(await conn.fetchval(
                """
                SELECT record_chat_turn_memory('a truly singular moment', 'yes', NULL, 'valve-test-2',
                    '{"importance": 0.96}'::jsonb)
                """
            ))
            assert exceptional["direct_promoted"] is True
        finally:
            await tr.rollback()
