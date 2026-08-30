from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_chat_turn_energy_costs_tools_and_rewards_connection(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("UPDATE heartbeat_state SET current_energy = 10 WHERE id = 1")
            before_connection = await conn.fetchval(
                "SELECT current_level FROM drives WHERE name = 'connection'"
            )
            result = await conn.fetchval(
                """
                SELECT apply_chat_turn_energy_effects(
                    2,
                    $1::jsonb,
                    '{"surface":"test"}'::jsonb
                )
                """,
                json.dumps({
                    "primary_emotion": "warmth",
                    "valence": 0.7,
                    "intensity": 0.8,
                }),
            )
            payload = json.loads(result) if isinstance(result, str) else result
            after_connection = await conn.fetchval(
                "SELECT current_level FROM drives WHERE name = 'connection'"
            )
            reward_count = await conn.fetchval(
                "SELECT COUNT(*) FROM reward_events WHERE kind = 'social:warmth'"
            )

            assert payload["tool_energy_spent"] == 2
            assert payload["energy_cost"] > 2
            assert payload["after_cost_energy"] < payload["before_energy"]
            assert payload["connection_satisfied"] > 0
            if before_connection is not None and after_connection is not None:
                assert after_connection <= before_connection
            assert int(reward_count) >= 1
        finally:
            await tr.rollback()
