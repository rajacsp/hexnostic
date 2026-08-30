import json

import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


async def test_prompt_module_rendering_replaces_context_values(db_pool):
    async with db_pool.acquire() as conn:
        await conn.fetchval(
            "SELECT upsert_prompt_module($1, $2, $3, $4, '{}'::jsonb)",
            "unit_test_prompt",
            "Hello {{name}} from {{nested.place}}.",
            "test prompt",
            "tests",
        )
        rendered = await conn.fetchval(
            "SELECT render_prompt($1, $2::jsonb)",
            "unit_test_prompt",
            json.dumps({"name": "Hexis", "nested": {"place": "Postgres"}}),
        )

    assert rendered == "Hello Hexis from Postgres."


async def test_llm_task_request_uses_prompt_modules(db_pool):
    async with db_pool.acquire() as conn:
        await conn.fetchval(
            "SELECT upsert_prompt_module($1, $2, NULL, NULL, '{}'::jsonb)",
            "unit_task_system",
            "System for {{agent}}",
        )
        await conn.fetchval(
            """
            SELECT register_llm_task_kind(
                'unit_task',
                'llm.test',
                '["unit_task_system"]'::jsonb,
                '{"type":"object"}'::jsonb,
                '{"max_tokens":12}'::jsonb,
                '{}'::jsonb
            )
            """
        )
        raw = await conn.fetchval(
            "SELECT build_llm_request('unit_task', $1::jsonb)",
            json.dumps({"agent": "Hexis", "user_prompt": "Do work"}),
        )

    request = _json(raw)
    assert request["provider_config_key"] == "llm.test"
    assert request["messages"][0]["content"] == "System for Hexis"
    assert request["messages"][1]["content"] == "Do work"
    assert request["defaults"]["max_tokens"] == 12


async def test_external_driver_call_claim_and_apply(db_pool):
    async with db_pool.acquire() as conn:
        call_id = await conn.fetchval(
            "SELECT enqueue_external_driver_call('unit-driver', $1::jsonb)",
            json.dumps({"job": "run"}),
        )
        claimed_raw = await conn.fetchval("SELECT claim_external_driver_call('unit-driver', 1)")
        claimed = _json(claimed_raw)
        assert len(claimed) == 1
        assert claimed[0]["id"] == str(call_id)
        assert claimed[0]["status"] == "in_progress"

        applied_raw = await conn.fetchval(
            "SELECT apply_external_driver_result($1::uuid, $2::jsonb)",
            call_id,
            json.dumps({"success": True, "value": 42}),
        )
        applied = _json(applied_raw)

    assert applied["status"] == "completed"
    assert applied["result"]["value"] == 42
