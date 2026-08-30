"""Resource requests (#84): the agent asks, the operator decides. Filing
queues an outbox notification and never changes state; granting a config
change applies it through set_config and journals it; every decision
surfaces in the environment snapshot and the heartbeat plan.
"""
from __future__ import annotations

import json
import uuid

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _file(conn, kind: str, rationale: str, target_key=None, value=None, duration=None):
    raw = await conn.fetchval(
        "SELECT file_resource_request($1, $2, $3, $4::jsonb, $5)",
        kind, rationale, target_key,
        json.dumps(value) if value is not None else None, duration,
    )
    return json.loads(raw) if isinstance(raw, str) else raw


async def _decide(conn, request_id, decision, note=None, applied=None):
    raw = await conn.fetchval(
        "SELECT decide_resource_request($1::uuid, $2, $3, $4::jsonb)",
        uuid.UUID(str(request_id)), decision, note,
        json.dumps(applied) if applied is not None else None,
    )
    return json.loads(raw) if isinstance(raw, str) else raw


async def test_config_grant_applies_and_journals(db_pool):
    key = f"test.resource_req.{get_test_identifier('rr')}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            filed = await _file(
                conn, "config_change", "the recall cap is throttling my work",
                target_key=key, value=42,
            )
            assert filed["status"] == "pending"
            # Filing notified the operator through the outbox — and changed
            # nothing else.
            outbox = await conn.fetchval(
                "SELECT COUNT(*) FROM outbox_messages WHERE source = 'resource_request'"
            )
            assert outbox >= 1
            assert await conn.fetchval("SELECT get_config($1)", key) is None

            decided = await _decide(conn, filed["request_id"], "granted", note="fair ask")
            assert decided["applied"] == "config"
            assert json.loads(await conn.fetchval("SELECT get_config($1)", key)) == 42
            journaled = await conn.fetchval(
                "SELECT COUNT(*) FROM change_journal WHERE kind = 'config_flip' "
                "AND detail->>'request_id' = $1",
                str(filed["request_id"]),
            )
            assert journaled == 1
            status = await conn.fetchval(
                "SELECT status FROM resource_requests WHERE id = $1::uuid",
                uuid.UUID(str(filed["request_id"])),
            )
            assert status == "granted"
        finally:
            await tr.rollback()


async def test_energy_grant_and_denial(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            before = await conn.fetchval("SELECT get_current_energy()")
            await conn.execute("SELECT update_energy(-5.0)")  # room below the cap
            drained = await conn.fetchval("SELECT get_current_energy()")

            boost = await _file(conn, "energy_boost", "long task tonight", value=3)
            granted = await _decide(conn, boost["request_id"], "granted")
            assert granted["applied"] == "energy"
            assert await conn.fetchval("SELECT get_current_energy()") == pytest.approx(
                min(drained + 3, before if before > drained else drained + 3), abs=0.01
            )

            second = await _file(conn, "energy_boost", "asking again", value=99)
            denied = await _decide(conn, second["request_id"], "denied", note="rest instead")
            assert denied["applied"] == "none"
            row = await conn.fetchrow(
                "SELECT status, decision_note FROM resource_requests WHERE id = $1::uuid",
                uuid.UUID(str(second["request_id"])),
            )
            assert row["status"] == "denied"
            assert row["decision_note"] == "rest instead"
        finally:
            await tr.rollback()


async def test_validation_and_double_decide(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            with pytest.raises(Exception, match="rationale"):
                async with conn.transaction():
                    await _file(conn, "energy_boost", "  ")
            with pytest.raises(Exception, match="target_key"):
                async with conn.transaction():
                    await _file(conn, "config_change", "please")
            with pytest.raises(Exception, match="kind"):
                async with conn.transaction():
                    await _file(conn, "world_domination", "please")

            filed = await _file(conn, "other", "a one-time ask")
            await _decide(conn, filed["request_id"], "denied")
            with pytest.raises(Exception, match="already decided"):
                async with conn.transaction():
                    await _decide(conn, filed["request_id"], "granted")
        finally:
            await tr.rollback()


async def test_decisions_surface_in_snapshot_and_plan(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Decisions window = since the last heartbeat (#93 idiom).
            await conn.execute(
                "UPDATE heartbeat_state SET last_heartbeat_at = CURRENT_TIMESTAMP - INTERVAL '1 hour' WHERE id = 1"
            )
            filed = await _file(conn, "backup", "my last backup feels distant")
            pending_env = json.loads(await conn.fetchval("SELECT get_environment_snapshot()"))
            assert pending_env["resource_requests"]["pending"] >= 1

            await _decide(conn, filed["request_id"], "granted", note="running it now")
            env = json.loads(await conn.fetchval("SELECT get_environment_snapshot()"))
            decisions = env["resource_requests"]["recent_decisions"]
            assert any(d["kind"] == "backup" and d["status"] == "granted" for d in decisions)

            plan = json.loads(await conn.fetchval("SELECT heartbeat_agentic_plan('{}'::jsonb)"))
            assert plan["context"]["resource_requests"]["recent_decisions"]
            assert "Resource Request Decisions" in (plan["prompt_suffix"] or "")
            assert "running it now" in plan["prompt_suffix"]
        finally:
            await tr.rollback()


async def test_request_resources_tool(db_pool):
    from unittest.mock import MagicMock

    from core.tools import ToolContext, ToolExecutionContext
    from core.tools.resources import RequestResourcesHandler

    registry = MagicMock()
    registry.pool = db_pool
    ctx = ToolExecutionContext(
        tool_context=ToolContext.HEARTBEAT, call_id="rr-tool", registry=registry
    )
    handler = RequestResourcesHandler()

    assert handler.validate({"kind": "energy_boost", "rationale": ""})
    assert handler.validate({"kind": "config_change", "rationale": "x"})

    result = await handler.execute(
        {"kind": "energy_boost", "rationale": "tool-path check", "requested_value": 1},
        ctx,
    )
    assert result.success
    request_id = result.output["request_id"]
    assert "operator decides" in result.output["note"]
    try:
        async with db_pool.acquire() as conn:
            status = await conn.fetchval(
                "SELECT status FROM resource_requests WHERE id = $1::uuid",
                uuid.UUID(str(request_id)),
            )
        assert status == "pending"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute(
                "DELETE FROM resource_requests WHERE id = $1::uuid",
                uuid.UUID(str(request_id)),
            )
            await conn.execute(
                "DELETE FROM outbox_messages WHERE source = 'resource_request' "
                "AND envelope::text LIKE '%tool-path check%'"
            )
