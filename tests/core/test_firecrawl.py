"""Tests for Firecrawl integration tools (E.9)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.firecrawl import (
    FirecrawlScrapeHandler,
    create_firecrawl_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestFirecrawlScrapeSpec:
    def test_spec_name(self):
        assert FirecrawlScrapeHandler().spec.name == "firecrawl_scrape"

    def test_spec_category_is_web(self):
        assert FirecrawlScrapeHandler().spec.category == ToolCategory.WEB

    def test_spec_read_only(self):
        assert FirecrawlScrapeHandler().spec.is_read_only is True

    def test_spec_energy_cost(self):
        assert FirecrawlScrapeHandler().spec.energy_cost == 3

    def test_spec_optional(self):
        assert FirecrawlScrapeHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "url" in FirecrawlScrapeHandler().spec.parameters["required"]

    def test_spec_has_formats_param(self):
        props = FirecrawlScrapeHandler().spec.parameters["properties"]
        assert "formats" in props
        assert props["formats"]["type"] == "array"


class TestFirecrawlAuthFailure:
    @pytest.mark.asyncio
    async def test_no_key(self):
        handler = FirecrawlScrapeHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"url": "https://example.com"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_empty_key(self):
        handler = FirecrawlScrapeHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"url": "https://example.com"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestFirecrawlFactory:
    def test_factory_count(self):
        tools = create_firecrawl_tools()
        assert len(tools) == 1

    def test_factory_names(self):
        names = {t.spec.name for t in create_firecrawl_tools()}
        assert names == {"firecrawl_scrape"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_firecrawl_tools(api_key_resolver=resolver)
        assert tools[0]._api_key_resolver is resolver
