from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_channel_presence_records_short_lived_typing_summary(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            raw = await conn.fetchval(
                """
                SELECT record_channel_presence(
                    'telegram', 'chat-1', 'typing', 'outbound', 'user-1',
                    'telegram:chat-1:user-1', '{"reason":"reply"}'::jsonb, 30
                )
                """
            )
            payload = json.loads(raw) if isinstance(raw, str) else raw
            summary_raw = await conn.fetchval("SELECT channel_presence_summary('telegram')")
            summary = json.loads(summary_raw) if isinstance(summary_raw, str) else summary_raw

            assert payload["presence_kind"] == "typing"
            assert payload["expires_at"] is not None
            assert any(item["presence_kind"] == "typing" and item["channel_id"] == "chat-1" for item in summary)
        finally:
            await tr.rollback()
