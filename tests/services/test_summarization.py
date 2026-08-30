"""Unit tests for the summarization worker (services/summarization.py), with the
LLM + DB mocked -- verifies claim -> LLM -> apply/fail wiring."""
from __future__ import annotations

import pytest

from services import summarization


class _FakeConn:
    def __init__(self, rows):
        self._rows = rows
        self.applied: list = []
        self.failed: list = []

    async def fetchval(self, query, *args):
        if "summarize_batch_size" in query:
            return 8
        if "apply_memory_summary" in query:
            self.applied.append(args)
            return '{"lessons_created": 1}'
        if "fail_memory_summarization" in query:
            self.failed.append(args)
            return None
        return None

    async def fetch(self, query, *args):
        if "claim_memory_summarization_batch" in query:
            rows, self._rows = self._rows, []
            return rows
        return []


@pytest.mark.asyncio
async def test_worker_summarizes_and_applies(monkeypatch):
    async def fake_chat_json(**kwargs):
        return ({"summary": "a gist", "lessons": [{"content": "x", "kind": "semantic"}]}, "{}")

    async def fake_llm_config(conn, key, fallback_key=None):
        return {"provider": "test"}

    monkeypatch.setattr(summarization, "chat_json", fake_chat_json)
    monkeypatch.setattr(summarization, "load_llm_config", fake_llm_config)

    conn = _FakeConn([{"memory_id": "m1", "content": "full content"}])
    result = await summarization.run_memory_summarization_step(conn)
    assert result["summarized"] == 1
    assert result.get("failed", 0) == 0
    assert conn.applied and conn.applied[0][1] == "a gist"   # summary passed to apply_memory_summary
    assert not conn.failed


@pytest.mark.asyncio
async def test_worker_never_wipes_on_empty_summary(monkeypatch):
    async def fake_chat_json(**kwargs):
        return ({"summary": "   ", "lessons": []}, "{}")   # unusable

    async def fake_llm_config(conn, key, fallback_key=None):
        return {}

    monkeypatch.setattr(summarization, "chat_json", fake_chat_json)
    monkeypatch.setattr(summarization, "load_llm_config", fake_llm_config)

    conn = _FakeConn([{"memory_id": "m1", "content": "full content"}])
    result = await summarization.run_memory_summarization_step(conn)
    assert result["failed"] == 1
    assert conn.failed and not conn.applied     # failed (retry), never applied an empty summary


@pytest.mark.asyncio
async def test_worker_skips_when_queue_empty(monkeypatch):
    conn = _FakeConn([])
    result = await summarization.run_memory_summarization_step(conn)
    assert result.get("skipped") is True
