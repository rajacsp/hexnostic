from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _coerce_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def test_agent_turn_state_machine_records_llm_and_tool_results(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            started = _coerce_json(
                await conn.fetchval(
                    "SELECT start_agent_turn($1::text, $2::text, NULL, $3::jsonb)",
                    "chat",
                    "hello",
                    json.dumps({
                        "messages": [{"role": "user", "content": "hello"}],
                        "energy_budget": 5,
                        "max_iterations": 2,
                    }),
                )
            )
            turn_id = started["turn_id"]
            step = _coerce_json(await conn.fetchval("SELECT next_agent_step($1::uuid)", turn_id))
            assert step["action"] == "llm"
            assert step["iteration"] == 1

            applied_llm = _coerce_json(
                await conn.fetchval(
                    "SELECT apply_agent_llm_result($1::uuid, $2::jsonb)",
                    turn_id,
                    json.dumps({"content": "using tool", "tool_calls": [{"name": "echo"}]}),
                )
            )
            assert applied_llm["iterations"] == 1

            applied_tool = _coerce_json(
                await conn.fetchval(
                    "SELECT apply_agent_tool_result($1::uuid, $2::text, $3::jsonb)",
                    turn_id,
                    "call-1",
                    json.dumps({"tool_name": "echo", "success": True, "energy_spent": 2, "model_output": "ok"}),
                )
            )
            assert applied_tool["energy_spent"] == 2

            finished = _coerce_json(
                await conn.fetchval(
                    "SELECT finish_agent_turn($1::uuid, $2::jsonb)",
                    turn_id,
                    json.dumps({"stopped_reason": "completed", "text": "done"}),
                )
            )
            assert finished["status"] == "completed"
            assert finished["stopped_reason"] == "completed"
            event_count = await conn.fetchval("SELECT COUNT(*) FROM agent_turn_events WHERE turn_id = $1::uuid", turn_id)
            assert event_count >= 4
        finally:
            await tr.rollback()


async def test_agent_next_step_stops_on_db_owned_energy_budget(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            started = _coerce_json(
                await conn.fetchval(
                    "SELECT start_agent_turn('heartbeat', 'go', NULL, $1::jsonb)",
                    json.dumps({"energy_budget": 1}),
                )
            )
            turn_id = started["turn_id"]
            await conn.fetchval(
                "SELECT apply_agent_tool_result($1::uuid, 'call-1', $2::jsonb)",
                turn_id,
                json.dumps({"tool_name": "costly", "success": True, "energy_spent": 1}),
            )
            step = _coerce_json(await conn.fetchval("SELECT next_agent_step($1::uuid)", turn_id))
            assert step["action"] == "stop"
            assert step["reason"] == "energy"
        finally:
            await tr.rollback()


async def test_next_step_returns_db_owned_message_log(db_pool):
    """next_agent_step hands back the authoritative agent_turns.messages log,
    and apply_* / append_agent_message accumulate it in replayable format."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            started = _coerce_json(
                await conn.fetchval(
                    "SELECT start_agent_turn($1::text, $2::text, NULL, $3::jsonb)",
                    "chat",
                    "hi",
                    json.dumps({
                        "messages": [
                            {"role": "system", "content": "S"},
                            {"role": "user", "content": "hi"},
                        ],
                        "energy_budget": 10,
                        "max_iterations": 5,
                    }),
                )
            )
            turn_id = started["turn_id"]

            # The step hands back the current message log for the LLM call.
            step = _coerce_json(await conn.fetchval("SELECT next_agent_step($1::uuid)", turn_id))
            assert step["action"] == "llm"
            assert isinstance(step["messages"], list)
            assert step["messages"][-1] == {"role": "user", "content": "hi"}

            # Assistant message with an OpenAI-format tool call, then its result.
            await conn.fetchval(
                "SELECT apply_agent_llm_result($1::uuid, $2::jsonb)",
                turn_id,
                json.dumps({
                    "content": "",
                    "tool_calls": [
                        {"id": "c1", "type": "function",
                         "function": {"name": "recall", "arguments": "{}"}}
                    ],
                }),
            )
            await conn.fetchval(
                "SELECT apply_agent_tool_result($1::uuid, 'c1', $2::jsonb)",
                turn_id,
                json.dumps({"tool_name": "recall", "success": True,
                            "energy_spent": 1, "model_output": "result-text"}),
            )

            step2 = _coerce_json(await conn.fetchval("SELECT next_agent_step($1::uuid)", turn_id))
            roles = [m["role"] for m in step2["messages"]]
            assert roles == ["system", "user", "assistant", "tool"]
            assert step2["messages"][2]["tool_calls"][0]["id"] == "c1"
            # Budgeted turns carry the energy footer on every tool result (#44).
            assert step2["messages"][3]["content"] == "result-text\n\n[energy: 1/10 spent]"

            # append_agent_message adds a user turn (continuation / plan / verify).
            appended = _coerce_json(
                await conn.fetchval(
                    "SELECT append_agent_message($1::uuid, 'user', 'continue')", turn_id
                )
            )
            assert appended["messages"][-1] == {"role": "user", "content": "continue"}
        finally:
            await tr.rollback()


async def test_external_call_kind_resolution_is_db_owned(db_pool):
    async with db_pool.acquire() as conn:
        tool_call = _coerce_json(
            await conn.fetchval(
                "SELECT resolve_external_call_kind($1::jsonb)",
                json.dumps({"call_type": "tool_use", "input": {"tool_name": "recall"}}),
            )
        )
        think_call = _coerce_json(
            await conn.fetchval(
                "SELECT resolve_external_call_kind($1::jsonb)",
                json.dumps({"call_type": "think", "input": {"kind": "reflect"}}),
            )
        )
        assert tool_call["call_type"] == "tool_use"
        assert tool_call["kind"] == "tool_use"
        assert think_call["call_type"] == "think"
        assert think_call["kind"] == "reflect"
        assert think_call["supported"] is True
