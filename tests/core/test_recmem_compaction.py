from __future__ import annotations

import json
from uuid import uuid4

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.core]


async def _flush(conn, messages: list[dict], session_id: str) -> int:
    """Run the DB-owned pre-compaction flush (flush_channel_history_to_memory, db/34)."""
    raw = await conn.fetchval(
        "SELECT flush_channel_history_to_memory($1::uuid, $2::jsonb)",
        session_id,
        json.dumps(messages),
    )
    doc = json.loads(raw) if isinstance(raw, str) else raw
    return int(doc.get("stored", 0))


async def test_compaction_flush_raw_ingest_dedupes_and_does_not_resurrect_redacted(db_pool):
    session_id = str(uuid4())
    messages = [
        {"role": "user", "content": "remember my compaction fruit is pear"},
        {"role": "assistant", "content": "noted"},
    ]

    async with db_pool.acquire() as conn:
        assert await _flush(conn, messages, session_id) == 1
        assert await _flush(conn, messages, session_id) == 1

    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, status
            FROM subconscious_units
            WHERE source_identity LIKE $1
            """,
            f"compaction:{session_id}:%",
        )
        assert len(rows) == 1
        assert rows[0]["status"] == "active"

        await conn.fetchval("SELECT recmem_redact_unit($1, 'compaction test', true)", rows[0]["id"])

    async with db_pool.acquire() as conn:
        assert await _flush(conn, messages, session_id) == 1

    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, status
            FROM subconscious_units
            WHERE source_identity LIKE $1
            """,
            f"compaction:{session_id}:%",
        )
        assert len(rows) == 1
        assert rows[0]["status"] == "redacted"

    async with db_pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM subconscious_units WHERE source_identity LIKE $1",
            f"compaction:{session_id}:%",
        )
