import json

import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_assert_db_brain_ready_reports_extension_status(db_pool):
    async with db_pool.acquire() as conn:
        raw = await conn.fetchval("SELECT assert_db_brain_ready(false)")
    payload = json.loads(raw) if isinstance(raw, str) else raw

    assert payload["ready"] is True
    assert "vector" in payload["required_extensions"]
    assert "pg_cron" in payload["planned_extensions"]
    assert isinstance(payload["planned_extensions_not_installed"], list)
