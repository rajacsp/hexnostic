"""Tests for video generation tool (G.2)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.video_gen.tools import (
    GenerateVideoHandler,
    create_video_gen_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestGenerateVideoSpec:
    def test_spec_name(self):
        assert GenerateVideoHandler().spec.name == "generate_video"

    def test_spec_category(self):
        assert GenerateVideoHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_not_read_only(self):
        assert GenerateVideoHandler().spec.is_read_only is False

    def test_spec_requires_approval(self):
        assert GenerateVideoHandler().spec.requires_approval is True

    def test_spec_energy_cost(self):
        assert GenerateVideoHandler().spec.energy_cost == 8

    def test_spec_optional(self):
        assert GenerateVideoHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "prompt" in GenerateVideoHandler().spec.parameters["required"]

    def test_spec_has_duration_param(self):
        props = GenerateVideoHandler().spec.parameters["properties"]
        assert "duration" in props
        assert props["duration"]["type"] == "integer"
        assert props["duration"]["minimum"] == 2
        assert props["duration"]["maximum"] == 16

    def test_spec_has_aspect_ratio_param(self):
        props = GenerateVideoHandler().spec.parameters["properties"]
        assert "aspect_ratio" in props
        assert "16:9" in props["aspect_ratio"]["enum"]
        assert "9:16" in props["aspect_ratio"]["enum"]

    def test_spec_aspect_ratio_default(self):
        props = GenerateVideoHandler().spec.parameters["properties"]
        assert props["aspect_ratio"]["default"] == "16:9"

    def test_spec_duration_default(self):
        props = GenerateVideoHandler().spec.parameters["properties"]
        assert props["duration"]["default"] == 4


class TestGenerateVideoAuth:
    @pytest.mark.asyncio
    async def test_no_key(self):
        handler = GenerateVideoHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"prompt": "A sunset over the ocean"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_resolver_returns_none(self):
        handler = GenerateVideoHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"prompt": "A sunset over the ocean"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestGenerateVideoValidation:
    @pytest.mark.asyncio
    async def test_empty_prompt(self):
        handler = GenerateVideoHandler(api_key_resolver=lambda: "test-key")
        ctx = _make_context()
        result = await handler.execute({"prompt": ""}, ctx)
        assert not result.success
        assert "required" in result.error.lower()

    @pytest.mark.asyncio
    async def test_whitespace_prompt(self):
        handler = GenerateVideoHandler(api_key_resolver=lambda: "test-key")
        ctx = _make_context()
        result = await handler.execute({"prompt": "   "}, ctx)
        assert not result.success
        assert "required" in result.error.lower()


class TestVideoGenFactory:
    def test_factory_count(self):
        tools = create_video_gen_tools()
        assert len(tools) == 1

    def test_factory_names(self):
        names = {t.spec.name for t in create_video_gen_tools()}
        assert names == {"generate_video"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_video_gen_tools(api_key_resolver=resolver)
        assert tools[0]._api_key_resolver is resolver
