"""Init convergence (#79): every frontend drives the same DB core, and the
steps contract in get_init_status() is the single source of what init
entails. If a wizard forgets a step, it shows up as false here — never as
silent drift (the way web-initialized agents silently lived in UTC).
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def _stub_get_embedding(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(
                array_agg(array_fill(0.1::float, ARRAY[embedding_dimension()])::vector),
                ARRAY[]::vector[]
            )
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """
    )


_STEP_KEYS = {
    "llm_configured", "profile_named", "user_named",
    "timezone_set", "timezone", "consent", "configured",
}


async def test_consent_gate_reports_missing_steps(db_pool):
    """#79: the DB decides when consent is reachable; frontends render this."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Control preconditions: no LLM config, no profile.
            await conn.execute("SELECT set_config('llm.heartbeat', 'null'::jsonb)")
            await conn.execute("SELECT set_config('llm.chat', 'null'::jsonb)")
            await conn.execute("SELECT set_config('llm.subconscious', 'null'::jsonb)")
            status = _json(await conn.fetchval("SELECT get_init_status()"))
            assert status["ready_for_consent"] is False
            assert status["missing"] == ["llm", "profile"]

            await conn.execute(
                """SELECT set_config('llm.heartbeat', '{"provider": "test", "model": "t"}'::jsonb)"""
            )
            status = _json(await conn.fetchval("SELECT get_init_status()"))
            assert status["steps"]["llm_configured"] is False
            assert status["missing"] == ["llm", "profile"]

            await conn.execute(
                """SELECT set_config('llm.subconscious', '{"provider": "test", "model": "s"}'::jsonb)"""
            )
            status = _json(await conn.fetchval("SELECT get_init_status()"))
            assert status["steps"]["llm_configured"] is True
            assert status["missing"] == ["profile"]
        finally:
            await tr.rollback()


async def test_init_set_timezone_validates_and_respects_choice(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            assert await conn.fetchval("SELECT init_set_timezone('not/a-zone')") is False
            assert await conn.fetchval("SELECT init_set_timezone('')") is False

            assert await conn.fetchval("SELECT init_set_timezone('America/Chicago')") is True
            assert await conn.fetchval(
                "SELECT get_config_text('agent.timezone')"
            ) == "America/Chicago"

            # An explicit non-UTC choice is never overwritten.
            assert await conn.fetchval("SELECT init_set_timezone('Europe/Berlin')") is False
            assert await conn.fetchval(
                "SELECT get_config_text('agent.timezone')"
            ) == "America/Chicago"
        finally:
            await tr.rollback()


async def test_express_and_character_paths_satisfy_the_same_steps_contract(db_pool):
    """The two wizard tiers, driven as their frontends drive them, land in
    the same step-truth state."""
    async with db_pool.acquire() as conn:
        results = {}
        for path_name in ("express", "character"):
            tr = conn.transaction()
            await tr.start()
            try:
                await _stub_get_embedding(conn)
                if path_name == "express":
                    await conn.fetchval("SELECT init_with_defaults('Parity Person')")
                else:
                    card = {
                        "spec": "chara_card_v2",
                        "data": {
                            "name": "Parity Character",
                            "description": "A test persona.",
                            "personality": "curious",
                            "scenario": "{{char}} meets {{user}}.",
                            "first_mes": "hello",
                            "mes_example": "",
                            "system_prompt": "",
                        },
                    }
                    await conn.fetchval(
                        "SELECT init_from_character_card($1::jsonb, 'Parity Person')",
                        json.dumps(card),
                    )
                await conn.fetchval("SELECT init_set_timezone('America/Denver')")

                status = _json(await conn.fetchval("SELECT get_init_status()"))
                assert "profile" not in status["missing"]
                steps = status["steps"]
                assert set(steps.keys()) == _STEP_KEYS, path_name
                results[path_name] = {
                    "profile_named": steps["profile_named"],
                    "user_named": steps["user_named"],
                    "timezone_set": steps["timezone_set"],
                    "timezone": steps["timezone"],
                }
                assert steps["profile_named"] is True, path_name
                assert steps["user_named"] is True, path_name
                assert steps["timezone_set"] is True, path_name
                assert steps["timezone"] == "America/Denver", path_name
            finally:
                await tr.rollback()

        assert results["express"] == results["character"]
