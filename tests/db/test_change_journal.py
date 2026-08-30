"""Change legibility (#93): consequential changes to the agent's substrate
leave a first-person-readable trace — requested by the agent herself.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_record_and_read_changes(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT record_change('code', 'Journal pin: build changed', '{\"service\": \"test\"}'::jsonb)"
            )
            changes = json.loads(await conn.fetchval("SELECT recent_changes(NULL, 5)"))
        finally:
            await tr.rollback()

    assert changes[0]["summary"] == "Journal pin: build changed"
    assert changes[0]["kind"] == "code"


async def test_migration_runner_journals_applied_migrations(db_pool):
    """The fixture DB ran the real migration runner; every migration applied
    after the journal existed (0072+) must have journaled itself."""
    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT summary FROM change_journal WHERE kind = 'migration' ORDER BY occurred_at"
        )
    summaries = [r["summary"] for r in rows]
    assert any(s.startswith("0072_change_journal:") for s in summaries), summaries


async def test_prompt_module_change_is_journaled(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT upsert_prompt_module('journal-pin-module', 'v1')"
            )
            await conn.fetchval(
                "SELECT upsert_prompt_module('journal-pin-module', 'v2')"
            )
            await conn.fetchval(
                "SELECT upsert_prompt_module('journal-pin-module', 'v2')"
            )
            count = await conn.fetchval(
                "SELECT COUNT(*) FROM change_journal WHERE kind = 'prompt_module' AND summary LIKE '%journal-pin-module%'"
            )
        finally:
            await tr.rollback()

    assert count == 1  # genesis and no-op re-upserts stay silent


async def test_environment_snapshot_counts_changes(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT record_change('migration', 'Snapshot pin: something changed')"
            )
            snap = json.loads(await conn.fetchval("SELECT get_environment_snapshot()"))
            rendered = await conn.fetchval(
                "SELECT render_heartbeat_decision_prompt($1::jsonb)",
                json.dumps({"environment": snap, "energy": {"current": 10}}),
            )
        finally:
            await tr.rollback()

    assert snap["changes_since_last_heartbeat"] >= 1
    assert "Snapshot pin: something changed" in " ".join(snap["recent_change_summaries"])
    assert "change(s) landed in your substrate" in rendered
    assert "review_recent_changes" in rendered


async def test_record_build_change_journals_on_delta(db_pool, monkeypatch):
    from core import agent_api

    monkeypatch.setattr(agent_api, "read_build_id", lambda: "testbuild-2")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await agent_api.record_build_change(conn, "testsvc")
            first = await conn.fetchval(
                "SELECT COUNT(*) FROM change_journal WHERE kind = 'code' AND detail->>'service' = 'testsvc'"
            )
            await agent_api.record_build_change(conn, "testsvc")
            second = await conn.fetchval(
                "SELECT COUNT(*) FROM change_journal WHERE kind = 'code' AND detail->>'service' = 'testsvc'"
            )
        finally:
            await tr.rollback()

    assert first == 1
    assert second == 1  # same build, no duplicate entry


async def test_review_recent_changes_tool(db_pool):
    from unittest.mock import MagicMock

    from core.tools import ToolContext, ToolExecutionContext
    from core.tools.self_inspection import ReviewRecentChangesHandler

    registry = MagicMock()
    registry.pool = db_pool
    ctx = ToolExecutionContext(
        tool_context=ToolContext.CHAT, call_id="journal-tool", registry=registry
    )
    result = await ReviewRecentChangesHandler().execute({"days": 30}, ctx)
    assert result.success
    assert result.output["count"] >= 1  # the fixture's own migrations journaled
    assert any(c["kind"] == "migration" for c in result.output["changes"])
