import json

import pytest

from tests.utils import _coerce_json

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_get_config_by_prefixes_and_delete_config_key(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT set_config('heartbeat.test.alpha', '1'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.test.beta', '2'::jsonb)")
            await conn.execute("SELECT set_config('agent.misc', '3'::jsonb)")

            rows = await conn.fetch(
                "SELECT key, value FROM get_config_by_prefixes(ARRAY['heartbeat.test.'])"
            )
            keys = {row["key"] for row in rows}
            assert keys == {"heartbeat.test.alpha", "heartbeat.test.beta"}

            deleted = await conn.fetchval(
                "SELECT delete_config_key('heartbeat.test.alpha')"
            )
            assert deleted is True
            assert await conn.fetchval(
                "SELECT get_config('heartbeat.test.alpha')"
            ) is None
        finally:
            await tr.rollback()


async def test_get_state_set_state_roundtrip(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            payload = {"alpha": 1, "beta": "two"}
            await conn.execute(
                "SELECT set_state('test.state', $1::jsonb)",
                json.dumps(payload),
            )
            stored = _coerce_json(await conn.fetchval("SELECT get_state('test.state')"))
            assert stored == payload
        finally:
            await tr.rollback()


async def test_heartbeat_state_update_trigger_updates_state(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                UPDATE heartbeat_state
                SET current_energy = 7,
                    heartbeat_count = 42,
                    is_paused = TRUE
                WHERE id = 1
                """
            )
            state = _coerce_json(await conn.fetchval("SELECT get_state('heartbeat_state')"))
            assert state["current_energy"] == 7
            assert state["heartbeat_count"] == 42
            assert state["is_paused"] is True
        finally:
            await tr.rollback()


async def test_maintenance_state_update_trigger_updates_state(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                UPDATE maintenance_state
                SET is_paused = TRUE,
                    last_subconscious_heartbeat = 3
                WHERE id = 1
                """
            )
            state = _coerce_json(await conn.fetchval("SELECT get_state('maintenance_state')"))
            assert state["is_paused"] is True
            assert state["last_subconscious_heartbeat"] == 3
        finally:
            await tr.rollback()


async def test_get_init_status_advance_stage_and_complete(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                UPDATE heartbeat_state
                SET init_stage = 'not_started',
                    init_data = '{}'::jsonb,
                    init_started_at = NULL,
                    init_completed_at = NULL
                WHERE id = 1
                """
            )
            status = _coerce_json(await conn.fetchval("SELECT get_init_status()"))
            assert status["stage"] == "not_started"
            assert status["is_complete"] is False

            status = _coerce_json(
                await conn.fetchval(
                    "SELECT advance_init_stage('mode', $1::jsonb)",
                    json.dumps({"mode": "persona"}),
                )
            )
            assert status["stage"] == "mode"
            assert status["data_collected"]["mode"] == "persona"
            assert await conn.fetchval("SELECT is_init_complete()") is False

            await conn.fetchval("SELECT advance_init_stage('complete', '{}'::jsonb)")
            assert await conn.fetchval("SELECT is_init_complete()") is True
        finally:
            await tr.rollback()


async def test_build_external_call_and_outbox_message(db_pool):
    async with db_pool.acquire() as conn:
        call = _coerce_json(
            await conn.fetchval(
                "SELECT build_external_call('think', $1::jsonb)",
                json.dumps({"foo": "bar"}),
            )
        )
        assert call["call_type"] == "think"
        assert call["input"]["foo"] == "bar"
        assert call["call_id"]

        msg = _coerce_json(
            await conn.fetchval(
                "SELECT build_outbox_message('user', $1::jsonb)",
                json.dumps({"message": "hi"}),
            )
        )
        assert msg["kind"] == "user"
        assert msg["payload"]["message"] == "hi"
        assert msg["message_id"]


async def test_should_run_subconscious_decider_and_mark_run(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT set_config('maintenance.subconscious_enabled', 'true'::jsonb)"
            )
            await conn.execute(
                "SELECT set_config('maintenance.subconscious_interval_seconds', '3600'::jsonb)"
            )
            await conn.execute(
                "SELECT set_config('agent.consent_status', $1::jsonb)",
                json.dumps("consent"),
            )
            await conn.execute(
                """
                UPDATE heartbeat_state
                SET heartbeat_count = 5,
                    init_stage = 'complete'
                WHERE id = 1
                """
            )
            await conn.execute(
                """
                UPDATE maintenance_state
                SET is_paused = FALSE,
                    last_subconscious_heartbeat = 3,
                    last_subconscious_run_at = CURRENT_TIMESTAMP - INTERVAL '2 hours'
                WHERE id = 1
                """
            )

            should_run = await conn.fetchval("SELECT should_run_subconscious_decider()")
            assert should_run is True

            await conn.execute("SELECT mark_subconscious_decider_run()")
            row = await conn.fetchrow(
                """
                SELECT last_subconscious_heartbeat, last_subconscious_run_at
                FROM maintenance_state
                WHERE id = 1
                """
            )
            assert row["last_subconscious_heartbeat"] == 5
            assert row["last_subconscious_run_at"] is not None
        finally:
            await tr.rollback()
