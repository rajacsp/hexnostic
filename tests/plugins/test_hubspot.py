"""Tests for HubSpot integration tools (A.5)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.hubspot.tools import (
    ListHubSpotDealsHandler,
    GetHubSpotDealHandler,
    create_hubspot_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestListHubSpotDealsSpec:
    def test_spec_name(self):
        assert ListHubSpotDealsHandler().spec.name == "hubspot_list_deals"

    def test_spec_category(self):
        assert ListHubSpotDealsHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert ListHubSpotDealsHandler().spec.is_read_only is True

    def test_spec_optional(self):
        assert ListHubSpotDealsHandler().spec.optional is True

    def test_spec_has_limit_param(self):
        props = ListHubSpotDealsHandler().spec.parameters["properties"]
        assert "limit" in props
        assert props["limit"]["type"] == "integer"

    def test_spec_has_stage_param(self):
        props = ListHubSpotDealsHandler().spec.parameters["properties"]
        assert "stage" in props


class TestGetHubSpotDealSpec:
    def test_spec_name(self):
        assert GetHubSpotDealHandler().spec.name == "hubspot_get_deal"

    def test_spec_category(self):
        assert GetHubSpotDealHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert GetHubSpotDealHandler().spec.is_read_only is True

    def test_spec_required_params(self):
        assert "deal_id" in GetHubSpotDealHandler().spec.parameters["required"]


class TestHubSpotAuthFailure:
    @pytest.mark.asyncio
    async def test_list_deals_no_key(self):
        handler = ListHubSpotDealsHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_list_deals_empty_key(self):
        handler = ListHubSpotDealsHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_get_deal_no_key(self):
        handler = GetHubSpotDealHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"deal_id": "123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestHubSpotFactory:
    def test_factory_count(self):
        tools = create_hubspot_tools()
        assert len(tools) == 2

    def test_factory_names(self):
        names = {t.spec.name for t in create_hubspot_tools()}
        assert names == {"hubspot_list_deals", "hubspot_get_deal"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_hubspot_tools(api_key_resolver=resolver)
        for tool in tools:
            assert tool._api_key_resolver is resolver
