"""Tests for YouTube Data API tools (E.5)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.youtube.tools import (
    GetYouTubeChannelStatsHandler,
    GetYouTubeVideoStatsHandler,
    SearchYouTubeVideosHandler,
    create_youtube_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestGetYouTubeChannelStatsSpec:
    def test_spec_name(self):
        assert GetYouTubeChannelStatsHandler().spec.name == "youtube_channel_stats"

    def test_spec_category(self):
        assert GetYouTubeChannelStatsHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert GetYouTubeChannelStatsHandler().spec.is_read_only is True

    def test_spec_optional(self):
        assert GetYouTubeChannelStatsHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "channel_id" in GetYouTubeChannelStatsHandler().spec.parameters["required"]


class TestSearchYouTubeVideosSpec:
    def test_spec_name(self):
        assert SearchYouTubeVideosHandler().spec.name == "youtube_search"

    def test_spec_category(self):
        assert SearchYouTubeVideosHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert SearchYouTubeVideosHandler().spec.is_read_only is True

    def test_spec_required_params(self):
        assert "query" in SearchYouTubeVideosHandler().spec.parameters["required"]

    def test_spec_has_max_results_param(self):
        props = SearchYouTubeVideosHandler().spec.parameters["properties"]
        assert "max_results" in props

    def test_spec_has_order_param(self):
        props = SearchYouTubeVideosHandler().spec.parameters["properties"]
        assert "order" in props


class TestGetYouTubeVideoStatsSpec:
    def test_spec_name(self):
        assert GetYouTubeVideoStatsHandler().spec.name == "youtube_video_stats"

    def test_spec_category(self):
        assert GetYouTubeVideoStatsHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert GetYouTubeVideoStatsHandler().spec.is_read_only is True

    def test_spec_required_params(self):
        assert "video_id" in GetYouTubeVideoStatsHandler().spec.parameters["required"]


class TestYouTubeAuthFailure:
    @pytest.mark.asyncio
    async def test_channel_stats_no_key(self):
        handler = GetYouTubeChannelStatsHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"channel_id": "UC123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_channel_stats_empty_key(self):
        handler = GetYouTubeChannelStatsHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"channel_id": "UC123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_search_no_key(self):
        handler = SearchYouTubeVideosHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"query": "test"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_video_stats_no_key(self):
        handler = GetYouTubeVideoStatsHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"video_id": "dQw4w9WgXcQ"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestYouTubeFactory:
    def test_factory_count(self):
        tools = create_youtube_tools()
        assert len(tools) == 3

    def test_factory_names(self):
        names = {t.spec.name for t in create_youtube_tools()}
        assert names == {"youtube_channel_stats", "youtube_video_stats", "youtube_search"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_youtube_tools(api_key_resolver=resolver)
        for tool in tools:
            assert tool._api_key_resolver is resolver
