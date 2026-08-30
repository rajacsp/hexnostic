"""Tests for Brave Search integration tools (E.8)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.brave_search import (
    BraveSearchHandler,
    create_brave_search_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestBraveSearchSpec:
    def test_spec_name(self):
        assert BraveSearchHandler().spec.name == "brave_search"

    def test_spec_category_is_web(self):
        assert BraveSearchHandler().spec.category == ToolCategory.WEB

    def test_spec_read_only(self):
        assert BraveSearchHandler().spec.is_read_only is True

    def test_spec_energy_cost(self):
        assert BraveSearchHandler().spec.energy_cost == 2

    def test_spec_optional(self):
        assert BraveSearchHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "query" in BraveSearchHandler().spec.parameters["required"]

    def test_spec_has_count_param(self):
        props = BraveSearchHandler().spec.parameters["properties"]
        assert "count" in props
        assert props["count"]["type"] == "integer"


class TestBraveSearchAuthFailure:
    @pytest.mark.asyncio
    async def test_no_key(self):
        handler = BraveSearchHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"query": "test"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_empty_key(self):
        handler = BraveSearchHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"query": "test"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestBraveSearchFactory:
    def test_factory_count(self):
        tools = create_brave_search_tools()
        assert len(tools) == 1

    def test_factory_names(self):
        names = {t.spec.name for t in create_brave_search_tools()}
        assert names == {"brave_search"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_brave_search_tools(api_key_resolver=resolver)
        assert tools[0]._api_key_resolver is resolver
