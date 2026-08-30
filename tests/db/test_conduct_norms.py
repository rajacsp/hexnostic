from __future__ import annotations

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_batch7_conduct_norm_prompt_modules(db_pool):
    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT key, content
            FROM prompt_modules
            WHERE key IN (
                'conversation',
                'conscious_extraction',
                'heartbeat_agentic',
                'heartbeat_task_mode',
                'channel_context',
                'rlm_heartbeat_system'
            )
            """
        )

    modules = {row["key"]: row["content"] for row in rows}

    conversation = modules["conversation"]
    assert "**Execute, verify, report:**" in conversation
    assert "do the work before saying it is done" in conversation
    assert "The most valuable memories reduce future steering" in conversation
    assert "Preserve the mechanism" in conversation

    extraction = modules["conscious_extraction"]
    assert "Steering-reduction criterion" in extraction
    assert "prevent the user from" in extraction
    assert "having to repeat themselves later" in extraction
    assert "**Steering reducers**" in extraction
    assert "memorize the example as a special case" in extraction

    heartbeat = modules["heartbeat_agentic"]
    assert "Verify results against the tool output or source of truth" in heartbeat
    assert "Reaching out spends the user's attention" in heartbeat
    assert "Deduplicate similar nudges" in heartbeat
    assert "Silence is an active, valid act" in heartbeat
    assert "Report completed work in past tense only after execution" in heartbeat

    task_mode = modules["heartbeat_task_mode"]
    assert "check the result against the source of truth" in task_mode
    assert "Report only completed, verified work" in task_mode
    assert "Don't skip verification or report success before checking your work" in task_mode

    channel = modules["channel_context"]
    assert "Silence can be the correct contribution" in channel
    assert "clear the" in channel
    assert "interruption bar" in channel

    rlm = modules["rlm_heartbeat_system"]
    assert "Execute, verify, then decide" in rlm
    assert "deduplicate similar nudges" in rlm
    assert "It is valid to choose silence" in rlm
