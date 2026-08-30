"""Scheduling tool tests.

The DB owns cron parsing, validation, and next-fire math (cron_next_fire,
parse_schedule_input, build_schedule_delivery — db/19 and db/36) and the
manage_schedule dispatcher (manage_schedule_tool). The former croniter helpers
and the Python compatibility fallback were deleted.
"""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.cron import ManageScheduleHandler, create_cron_tools

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _ctx(pool) -> ToolExecutionContext:
    registry = MagicMock()
    registry.pool = pool
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


async def _dispatch(db_pool, args: dict):
    return await ManageScheduleHandler().execute(args, _ctx(db_pool))


async def _cleanup(db_pool, prefix: str) -> None:
    async with db_pool.acquire() as conn:
        await conn.execute("DELETE FROM scheduled_tasks WHERE name LIKE $1", f"{prefix}%")


# ---------------------------------------------------------------------------
# cron_next_fire: real cron math in SQL
# ---------------------------------------------------------------------------

class TestCronNextFireSql:
    CASES = [
        ("0 9 * * *", "UTC", "2026-07-16 10:00:00+00", "2026-07-17 09:00:00+00"),
        ("*/15 * * * *", "UTC", "2026-07-16 10:07:00+00", "2026-07-16 10:15:00+00"),
        # 2026-07-17 is a Friday; after 10:00 the next weekday 09:00 is Monday.
        ("0 9 * * 1-5", "UTC", "2026-07-17 10:00:00+00", "2026-07-20 09:00:00+00"),
        ("30 14 1 * *", "UTC", "2026-07-16 10:00:00+00", "2026-08-01 14:30:00+00"),
        # Feb 29 only exists in 2028.
        ("0 0 29 2 *", "UTC", "2026-07-16 10:00:00+00", "2028-02-29 00:00:00+00"),
        # Vixie OR-rule: dom 15 OR Wednesday — next Wednesday comes first.
        ("0 12 15 * 3", "UTC", "2026-07-16 10:00:00+00", "2026-07-22 12:00:00+00"),
        # 9am America/New_York in July is 13:00 UTC.
        ("0 9 * * *", "America/New_York", "2026-07-16 12:00:00+00", "2026-07-16 13:00:00+00"),
        ("5 0 * 8 SUN", "UTC", "2026-07-16 10:00:00+00", "2026-08-02 00:05:00+00"),
        ("0 9,18 * * *", "UTC", "2026-07-16 10:00:00+00", "2026-07-16 18:00:00+00"),
    ]

    @pytest.mark.parametrize("expr,tz,after,expected", CASES)
    async def test_next_fire(self, db_pool, expr, tz, after, expected):
        async with db_pool.acquire() as conn:
            got = await conn.fetchval(
                "SELECT cron_next_fire($1, $2, $3::text::timestamptz)::text", expr, tz, after
            )
        assert got == expected, (expr, got)

    @pytest.mark.parametrize("expr", ["99 9 * * *", "not a cron", "* * *", "0 9 * * MOO", "5-1 * * * *"])
    async def test_invalid_expressions_raise(self, db_pool, expr):
        import asyncpg

        async with db_pool.acquire() as conn:
            with pytest.raises(asyncpg.exceptions.PostgresError):
                await conn.fetchval("SELECT cron_next_fire($1)", expr)


# ---------------------------------------------------------------------------
# parse_schedule_input: shorthand + cron detection + validation
# ---------------------------------------------------------------------------

class TestParseScheduleInputSql:
    async def _parse(self, db_pool, args: dict) -> dict:
        async with db_pool.acquire() as conn:
            raw = await conn.fetchval("SELECT parse_schedule_input($1::jsonb)", json.dumps(args))
        return json.loads(raw) if isinstance(raw, str) else raw

    async def test_cron_expression_detected_with_real_next_run(self, db_pool):
        parsed = await self._parse(db_pool, {"schedule": "0 9 * * *"})
        assert parsed["schedule_kind"] == "cron"
        assert parsed["schedule"]["cron"] == "0 9 * * *"
        # The placeholder era is over: _next_run is the true next fire.
        assert parsed["schedule"]["_next_run"].split(" ")[1].startswith("09:00")

    async def test_daily_shorthand(self, db_pool):
        parsed = await self._parse(db_pool, {"schedule": "daily:07:00"})
        assert parsed["schedule_kind"] == "daily"

    async def test_interval_shorthand(self, db_pool):
        parsed = await self._parse(db_pool, {"schedule": "every:5m"})
        assert parsed["schedule_kind"] == "interval"
        assert parsed["schedule"]["every_minutes"] == 5

    async def test_once_shorthand(self, db_pool):
        parsed = await self._parse(db_pool, {"schedule": "once:+2h"})
        assert parsed["schedule_kind"] == "once"

    async def test_invalid_cron_rejected(self, db_pool):
        import asyncpg

        async with db_pool.acquire() as conn:
            with pytest.raises(asyncpg.exceptions.PostgresError):
                await conn.fetchval(
                    "SELECT parse_schedule_input($1::jsonb)",
                    json.dumps({"schedule_kind": "cron", "schedule": '{"cron": "99 99 * * *"}'}),
                )


# ---------------------------------------------------------------------------
# build_schedule_delivery
# ---------------------------------------------------------------------------

class TestBuildDeliverySql:
    async def _build(self, db_pool, args: dict) -> dict:
        async with db_pool.acquire() as conn:
            raw = await conn.fetchval("SELECT build_schedule_delivery($1::jsonb)", json.dumps(args))
        return json.loads(raw) if isinstance(raw, str) else raw

    async def test_default_outbox(self, db_pool):
        assert await self._build(db_pool, {}) == {"mode": "outbox"}

    async def test_channel_delivery(self, db_pool):
        delivery = await self._build(db_pool, {
            "delivery_mode": "channel",
            "delivery_channel": "telegram",
            "delivery_target_id": "chat-123",
            "delivery_topic": "cron-updates",
        })
        assert delivery == {"mode": "channel", "channel": "telegram", "target_id": "chat-123", "topic": "cron-updates"}

    async def test_webhook_delivery(self, db_pool):
        delivery = await self._build(db_pool, {
            "delivery_mode": "webhook",
            "delivery_webhook_url": "https://example.com/hook",
        })
        assert delivery == {"mode": "webhook", "url": "https://example.com/hook"}

    async def test_silent_delivery(self, db_pool):
        assert await self._build(db_pool, {"delivery_mode": "silent"}) == {"mode": "silent"}


# ---------------------------------------------------------------------------
# Spec
# ---------------------------------------------------------------------------

class TestManageScheduleSpec:
    def test_spec_name(self):
        spec = ManageScheduleHandler().spec
        assert spec.name == "manage_schedule"

    def test_spec_category(self):
        spec = ManageScheduleHandler().spec
        assert spec.category == ToolCategory.MEMORY

    def test_spec_includes_cron(self):
        spec = ManageScheduleHandler().spec
        assert "cron" in spec.description.lower()

    def test_spec_includes_stats_action(self):
        spec = ManageScheduleHandler().spec
        assert "stats" in spec.description

    def test_spec_has_delivery_params(self):
        spec = ManageScheduleHandler().spec
        props = spec.parameters["properties"]
        assert "delivery_mode" in props
        assert "delivery_channel" in props
        assert "delivery_topic" in props
        assert "delivery_target_id" in props
        assert "delivery_webhook_url" in props

    def test_spec_delivery_modes(self):
        spec = ManageScheduleHandler().spec
        modes = spec.parameters["properties"]["delivery_mode"]["enum"]
        assert "outbox" in modes
        assert "channel" in modes
        assert "webhook" in modes
        assert "silent" in modes


# ---------------------------------------------------------------------------
# The dispatcher end-to-end (manage_schedule_tool through the handler)
# ---------------------------------------------------------------------------

class TestScheduleDispatcher:
    async def test_create_cron_task_gets_real_next_run(self, db_pool):
        prefix = "cron-dispatch-create"
        try:
            result = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-morning",
                "schedule": "0 9 * * 1-5",
                "action_kind": "queue_user_message",
                "message": "Morning standup",
                "delivery_mode": "channel",
                "delivery_channel": "telegram",
                "delivery_target_id": "chat-1",
            })
            assert result.success, result.error
            assert result.output["schedule_kind"] == "cron"
            assert result.output["delivery"]["channel"] == "telegram"
            async with db_pool.acquire() as conn:
                next_run = await conn.fetchval(
                    "SELECT next_run_at FROM scheduled_tasks WHERE id = $1::uuid",
                    result.output["task_id"],
                )
            # Real cron math: weekday 09:00 UTC, never a bare now+1min placeholder.
            assert next_run.hour == 9 and next_run.minute == 0
            assert next_run.isoweekday() <= 5
        finally:
            await _cleanup(db_pool, prefix)

    async def test_invalid_cron_expression_rejected(self, db_pool):
        prefix = "cron-dispatch-bad"
        try:
            result = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-task",
                "schedule_kind": "cron",
                "schedule": '{"cron": "not a cron"}',
                "action_kind": "queue_user_message",
                "message": "test",
            })
            assert not result.success
        finally:
            await _cleanup(db_pool, prefix)

    async def test_create_channel_requires_target_id(self, db_pool):
        result = await _dispatch(db_pool, {
            "action": "create",
            "name": "cron-dispatch-chan",
            "schedule": "daily:09:00",
            "action_kind": "queue_user_message",
            "message": "hi",
            "delivery_mode": "channel",
            "delivery_channel": "telegram",
        })
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_create_webhook_requires_url(self, db_pool):
        result = await _dispatch(db_pool, {
            "action": "create",
            "name": "cron-dispatch-hook",
            "schedule": "daily:09:00",
            "action_kind": "queue_user_message",
            "message": "hi",
            "delivery_mode": "webhook",
        })
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_update_channel_requires_target_id(self, db_pool):
        prefix = "cron-dispatch-upd"
        try:
            created = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-task",
                "schedule": "daily:09:00",
                "action_kind": "queue_user_message",
                "message": "hi",
            })
            assert created.success, created.error
            result = await _dispatch(db_pool, {
                "action": "update",
                "task_id": created.output["task_id"],
                "delivery_mode": "channel",
                "delivery_channel": "telegram",
            })
            assert not result.success
            assert result.error_type == ToolErrorType.INVALID_PARAMS
        finally:
            await _cleanup(db_pool, prefix)

    async def test_list_shows_nondefault_delivery_and_hides_outbox(self, db_pool):
        prefix = "cron-dispatch-list"
        try:
            routed = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-routed",
                "schedule": "daily:09:00",
                "action_kind": "queue_user_message",
                "message": "hi",
                "delivery_mode": "channel",
                "delivery_channel": "telegram",
                "delivery_target_id": "chat-1",
                "delivery_topic": "cron",
            })
            assert routed.success, routed.error
            plain = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-plain",
                "schedule": "daily:10:00",
                "action_kind": "queue_user_message",
                "message": "hi",
            })
            assert plain.success, plain.error

            result = await _dispatch(db_pool, {"action": "list"})
            assert result.success, result.error
            tasks = {t["name"]: t for t in result.output["tasks"]}
            assert tasks[f"{prefix}-routed"]["delivery"]["channel"] == "telegram"
            assert "delivery" not in tasks[f"{prefix}-plain"]  # default outbox hidden
        finally:
            await _cleanup(db_pool, prefix)

    async def test_stats_aggregate_includes_recent_runs(self, db_pool):
        result = await _dispatch(db_pool, {"action": "stats"})
        assert result.success, result.error
        assert "active_tasks" in result.output
        assert "total_executions" in result.output
        assert isinstance(result.output["recent_runs"], list)

    async def test_stats_per_task(self, db_pool):
        prefix = "cron-dispatch-stats"
        try:
            created = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-task",
                "schedule": "daily:09:00",
                "action_kind": "queue_user_message",
                "message": "hi",
            })
            assert created.success, created.error
            result = await _dispatch(db_pool, {
                "action": "stats",
                "task_id": created.output["task_id"],
            })
            assert result.success, result.error
            assert result.output["name"] == f"{prefix}-task"
            assert result.output["run_count"] == 0
            assert result.output["status"] == "active"
        finally:
            await _cleanup(db_pool, prefix)

    async def test_stats_task_not_found(self, db_pool):
        result = await _dispatch(db_pool, {
            "action": "stats",
            "task_id": "00000000-0000-0000-0000-000000000099",
        })
        assert not result.success

    async def test_cancel(self, db_pool):
        prefix = "cron-dispatch-cancel"
        try:
            created = await _dispatch(db_pool, {
                "action": "create",
                "name": f"{prefix}-task",
                "schedule": "daily:09:00",
                "action_kind": "queue_user_message",
                "message": "hi",
            })
            assert created.success, created.error
            result = await _dispatch(db_pool, {
                "action": "cancel",
                "task_id": created.output["task_id"],
            })
            assert result.success, result.error
            assert result.output["cancelled"] is True
        finally:
            await _cleanup(db_pool, prefix)

    async def test_invalid_action_rejected(self, db_pool):
        result = await _dispatch(db_pool, {"action": "explode"})
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_no_pool_returns_error(self):
        registry = MagicMock()
        registry.pool = None
        result = await ManageScheduleHandler().execute(
            {"action": "list"},
            ToolExecutionContext(tool_context=ToolContext.CHAT, call_id="t", registry=registry),
        )
        assert not result.success
        assert result.error_type == ToolErrorType.MISSING_CONFIG


# ---------------------------------------------------------------------------
# Valid schedule kinds (spec constants)
# ---------------------------------------------------------------------------

class TestValidScheduleKinds:
    def test_cron_in_valid_kinds(self):
        from core.tools.cron import _VALID_SCHEDULE_KINDS
        assert "cron" in _VALID_SCHEDULE_KINDS

    def test_stats_in_valid_actions(self):
        from core.tools.cron import _VALID_ACTIONS
        assert "stats" in _VALID_ACTIONS


# ---------------------------------------------------------------------------
# Recompute cron next runs (worker path)
# ---------------------------------------------------------------------------

class TestRecomputeCronNextRuns:
    """The DB owns cron next-run math (recompute_cron_next_runs, db/36); the
    Python wrapper only delegates. The former croniter fallback was deleted."""

    async def test_recompute_computes_real_cron_time(self, db_pool):
        from core.state import recompute_cron_next_runs

        async with db_pool.acquire() as conn:
            task_id = await conn.fetchval(
                """SELECT create_scheduled_task(
                       'recompute-test', 'cron', $1::jsonb, 'queue_user_message',
                       '{"message": "hi"}'::jsonb, 'UTC')""",
                json.dumps({"cron": "0 9 * * *", "_next_run": "2000-01-01T00:00:00+00:00"}),
            )
            try:
                await conn.execute(
                    "UPDATE scheduled_tasks SET next_run_at = '2000-01-01T00:00:00+00:00' WHERE id = $1",
                    task_id,
                )
                updated = await recompute_cron_next_runs(conn, [str(task_id)])
                assert updated == 1
                next_run = await conn.fetchval(
                    "SELECT next_run_at AT TIME ZONE 'UTC' FROM scheduled_tasks WHERE id = $1", task_id
                )
                # Real cron math, not a now+1min placeholder.
                assert next_run.year >= 2026
                assert next_run.hour == 9 and next_run.minute == 0
            finally:
                await conn.execute("DELETE FROM scheduled_tasks WHERE id = $1", task_id)

    async def test_recompute_empty_ids_skips_db(self):
        from core.state import recompute_cron_next_runs

        mock_conn = AsyncMock()
        updated = await recompute_cron_next_runs(mock_conn, [])
        assert updated == 0
        mock_conn.fetchval.assert_not_called()

    async def test_recompute_delegates_to_sql(self):
        from core.state import recompute_cron_next_runs

        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(return_value=3)
        updated = await recompute_cron_next_runs(mock_conn, ["a", "b", "c"])
        assert updated == 3
        sql = mock_conn.fetchval.call_args[0][0]
        assert "recompute_cron_next_runs" in sql

    async def test_recompute_missing_task(self, db_pool):
        from core.state import recompute_cron_next_runs

        async with db_pool.acquire() as conn:
            updated = await recompute_cron_next_runs(
                conn, ["00000000-0000-0000-0000-00000000dead"]
            )
            assert updated == 0


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

class TestFactory:
    def test_factory_returns_handler(self):
        tools = create_cron_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], ManageScheduleHandler)

    def test_factory_tool_name(self):
        tools = create_cron_tools()
        assert tools[0].spec.name == "manage_schedule"
