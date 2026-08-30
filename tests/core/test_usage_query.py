"""Tests for usage query tool (H.4)."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.usage_query import QueryUsageHandler, create_usage_tools


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestQueryUsageSpec:
    def test_spec_name(self):
        assert QueryUsageHandler().spec.name == "query_usage"

    def test_spec_category(self):
        assert QueryUsageHandler().spec.category == ToolCategory.MEMORY

    def test_spec_read_only(self):
        assert QueryUsageHandler().spec.is_read_only is True

    def test_spec_has_period_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "period" in props
        assert set(props["period"]["enum"]) == {"day", "week", "month", "quarter", "year"}

    def test_spec_has_view_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "view" in props
        assert set(props["view"]["enum"]) == {"summary", "daily", "top_models"}

    def test_spec_has_source_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "source" in props


class TestQueryUsageViews:
    """query_usage_tool (SQL) owns the view shaping; seeded in-transaction."""

    async def _seeded_view(self, db_pool, args):
        import json

        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                for source, cost in (("chat", 1.25), ("heartbeat", 0.75)):
                    await conn.fetchval(
                        "SELECT record_api_usage('anthropic', 'claude-opus-4-6', 'chat', 1000, 500, 0, 0, $1, NULL, $2)",
                        cost, source,
                    )
                raw = await conn.fetchval(
                    "SELECT query_usage_tool($1::jsonb)", json.dumps(args)
                )
            finally:
                await tr.rollback()
        return json.loads(raw)

    @pytest.mark.asyncio(loop_scope="session")
    async def test_summary_view(self, db_pool):
        payload = await self._seeded_view(db_pool, {"view": "summary", "period": "week"})
        assert payload["success"] is True
        out = payload["output"]
        assert out["period"] == "week"
        assert out["total_calls"] >= 2
        assert out["total_cost_usd"] >= 2.0
        assert any(m["model"] == "claude-opus-4-6" for m in out["by_model"])

    @pytest.mark.asyncio(loop_scope="session")
    async def test_summary_view_source_filter(self, db_pool):
        payload = await self._seeded_view(
            db_pool, {"view": "summary", "period": "week", "source": "heartbeat"}
        )
        assert payload["success"] is True
        assert payload["output"]["total_calls"] == 1

    @pytest.mark.asyncio(loop_scope="session")
    async def test_daily_view(self, db_pool):
        payload = await self._seeded_view(db_pool, {"view": "daily", "period": "week"})
        assert payload["success"] is True
        daily = payload["output"]["daily"]
        assert daily and daily[0]["calls"] >= 2

    @pytest.mark.asyncio(loop_scope="session")
    async def test_top_models_view(self, db_pool):
        payload = await self._seeded_view(db_pool, {"view": "top_models", "period": "week"})
        assert payload["success"] is True
        ranked = payload["output"]["top_models"]
        assert ranked[0]["model"] == "anthropic/claude-opus-4-6"
        assert ranked[0]["cost_usd"] >= 2.0

    @pytest.mark.asyncio(loop_scope="session")
    async def test_handler_dispatches(self, db_pool):
        handler = QueryUsageHandler()
        registry = MagicMock()
        registry.pool = db_pool
        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="usage-dispatch",
            registry=registry,
        )
        result = await handler.execute({"view": "summary", "period": "day"}, ctx)
        assert result.success
        assert result.output["period"] == "day"
        assert "Usage (day):" in (result.display_output or "")


class TestUsageToolFactory:
    def test_factory_count(self):
        assert len(create_usage_tools()) == 1

    def test_factory_name(self):
        assert create_usage_tools()[0].spec.name == "query_usage"
