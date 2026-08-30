from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_appraisal_depth_scales_with_salience(db_pool):
    async with db_pool.acquire() as conn:
        skim_raw = await conn.fetchval(
            "SELECT appraisal_depth_for_stimulus($1, '{}'::jsonb)",
            "hey, nice weather",
        )
        deep_raw = await conn.fetchval(
            "SELECT appraisal_depth_for_stimulus($1, '{}'::jsonb)",
            "Urgent emergency: I may need a lawyer and this is critical. What should I remember?",
        )
    skim = json.loads(skim_raw) if isinstance(skim_raw, str) else skim_raw
    deep = json.loads(deep_raw) if isinstance(deep_raw, str) else deep_raw

    assert skim["depth"] == "skim"
    assert deep["depth"] == "deep"
    assert deep["salience"] > skim["salience"]
    assert deep["limits"]["memory_limit"] > skim["limits"]["memory_limit"]
    assert deep["limits"]["max_tokens"] > skim["limits"]["max_tokens"]
