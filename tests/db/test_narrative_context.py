import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_ensure_current_life_chapter_and_get_narrative_context(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT ensure_current_life_chapter($1::text)", "Foundations")

            context_raw = await conn.fetchval("SELECT get_narrative_context()")
            context = json.loads(context_raw) if isinstance(context_raw, str) else context_raw
            chapter = context.get("current_chapter") or {}
            assert chapter.get("name") == "Foundations"

            self_cfg_raw = await conn.fetchval("SELECT get_config('agent.self')")
            self_cfg = json.loads(self_cfg_raw) if isinstance(self_cfg_raw, str) else self_cfg_raw
            assert self_cfg.get("key") == "self"
        finally:
            await tr.rollback()
