"""Integration test for the consolidation->summarization->distillation loop, driven
by the REAL worker (services/summarization.py) against the REAL database. Only the
LLM *network call* (chat_json) is stubbed -- everything else (claim, apply_memory_summary,
fidelity drop, schema distillation, queue completion) runs for real. This is as close
to the live active-worker path as is possible without LLM credentials; only the model's
text generation is not exercised here.
"""
from __future__ import annotations

import pytest

from services import summarization

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_DUMMY = "array_fill(0.12, ARRAY[embedding_dimension()])::vector"


async def test_summarization_loop_end_to_end(db_pool, monkeypatch):
    async def fake_chat_json(**kwargs):
        # the ONLY stub: stand in for the model's generation
        return ({
            "summary": "A compacted recollection of several market trips.",
            "lessons": [{"content": "the neighbourhood market has fresh cheap apples zqx", "kind": "semantic"}],
        }, "{}")

    async def fake_llm_config(conn, key, fallback_key=None):
        return {"provider": "stub", "model": "stub"}

    monkeypatch.setattr(summarization, "chat_json", fake_chat_json)
    monkeypatch.setattr(summarization, "load_llm_config", fake_llm_config)

    async with db_pool.acquire() as conn:
        await conn.execute("LOAD 'age'")
        tr = conn.transaction()
        await tr.start()
        try:
            # aged episodic memories -> consolidate into a gist queued for summarization
            ids = [await conn.fetchval(
                f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at) "
                f"VALUES ('episodic', $1, {_DUMMY}, 0.3, 0.9, 'active', now()-interval '60 days') RETURNING id",
                f"went to the market and bought things, trip {i}") for i in range(3)]
            gist = await conn.fetchval("SELECT consolidate_memory_group($1::uuid[])", ids)
            assert gist is not None
            assert await conn.fetchval(
                "SELECT status FROM memory_summarization_queue WHERE memory_id=$1", gist) == "pending"
            full_content = await conn.fetchval("SELECT content FROM memories WHERE id=$1", gist)

            # drive the REAL worker step (only chat_json is stubbed)
            result = await summarization.run_memory_summarization_step(conn)
            assert result.get("summarized") == 1

            # the gist was compacted by the real apply_memory_summary: content replaced,
            # fidelity dropped, and it genuinely compressed
            row = await conn.fetchrow("SELECT content, fidelity FROM memories WHERE id=$1", gist)
            assert row["content"] == "A compacted recollection of several market trips."
            assert row["fidelity"] < 1.0
            assert len(full_content) > len(row["content"])
            # the durable lesson was distilled UPWARD into the schema (real create_semantic_memory)
            assert await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM memories WHERE type='semantic' AND content LIKE '%apples zqx%')")
            # the queue task is marked done
            assert await conn.fetchval(
                "SELECT status FROM memory_summarization_queue WHERE memory_id=$1", gist) == "done"
        finally:
            await tr.rollback()
