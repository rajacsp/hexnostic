"""Tests for G.1: Image generation tool."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.image_gen import GenerateImageHandler, create_image_gen_tools

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _make_context(db_pool):
    """Build a minimal ToolExecutionContext with a registry stub."""
    from core.tools.base import ToolContext, ToolExecutionContext

    registry = MagicMock()
    registry.pool = db_pool

    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestGenerateImageSpec:
    """Verify tool spec is correct."""

    def test_spec_name(self):
        handler = GenerateImageHandler()
        assert handler.spec.name == "generate_image"

    def test_spec_has_prompt_required(self):
        handler = GenerateImageHandler()
        assert "prompt" in handler.spec.parameters["required"]

    def test_spec_size_enum(self):
        handler = GenerateImageHandler()
        props = handler.spec.parameters["properties"]
        assert "1024x1024" in props["size"]["enum"]
        assert "1792x1024" in props["size"]["enum"]


class TestGenerateImageExecution:
    """Test GenerateImageHandler execution."""

    async def test_empty_prompt_returns_error(self, db_pool):
        handler = GenerateImageHandler()
        ctx = _make_context(db_pool)
        result = await handler.execute({"prompt": ""}, ctx)
        assert not result.success
        assert "required" in result.error.lower()

    async def test_missing_api_key_returns_error(self, db_pool):
        handler = GenerateImageHandler()
        ctx = _make_context(db_pool)
        with patch.dict("os.environ", {}, clear=True):
            # Remove any existing key
            with patch.object(handler, "_resolve_api_key", return_value=None):
                result = await handler.execute({"prompt": "A cat"}, ctx)
        assert not result.success
        assert "api key" in result.error.lower()

    async def test_successful_generation(self, db_pool):
        """Mocked successful image generation."""
        handler = GenerateImageHandler()
        ctx = _make_context(db_pool)

        mock_result = {
            "url": "https://oaidalleapiprodscus.blob.core.windows.net/test-image.png",
            "revised_prompt": "A fluffy orange cat sitting on a windowsill",
        }

        with patch.object(handler, "_resolve_api_key", return_value="sk-test"):
            with patch.object(handler, "_generate", return_value=mock_result):
                result = await handler.execute({
                    "prompt": "A cat on a windowsill",
                    "size": "1024x1024",
                    "quality": "standard",
                }, ctx)

        assert result.success
        assert result.output["url"] == mock_result["url"]
        assert result.output["revised_prompt"] == mock_result["revised_prompt"]
        assert result.output["size"] == "1024x1024"

    async def test_invalid_size_defaults(self, db_pool):
        """Invalid size falls back to 1024x1024."""
        handler = GenerateImageHandler()
        ctx = _make_context(db_pool)

        mock_result = {"url": "https://example.com/img.png", "revised_prompt": "test"}
        with patch.object(handler, "_resolve_api_key", return_value="sk-test"):
            with patch.object(handler, "_generate", return_value=mock_result) as mock_gen:
                await handler.execute({
                    "prompt": "A cat",
                    "size": "invalid",
                }, ctx)
                _, kwargs = mock_gen.call_args
                assert kwargs["size"] == "1024x1024"

    async def test_api_error_returns_failure(self, db_pool):
        """API errors are caught and returned as tool errors."""
        handler = GenerateImageHandler()
        ctx = _make_context(db_pool)

        with patch.object(handler, "_resolve_api_key", return_value="sk-test"):
            with patch.object(handler, "_generate", side_effect=RuntimeError("API error")):
                result = await handler.execute({"prompt": "A cat"}, ctx)

        assert not result.success
        assert "API error" in result.error


class TestCostEstimation:
    """Test image cost estimation."""

    def test_standard_square(self):
        handler = GenerateImageHandler()
        assert handler._estimate_cost("1024x1024", "standard") == 0.040

    def test_hd_square(self):
        handler = GenerateImageHandler()
        assert handler._estimate_cost("1024x1024", "hd") == 0.080

    def test_hd_landscape(self):
        handler = GenerateImageHandler()
        assert handler._estimate_cost("1792x1024", "hd") == 0.120


class TestToolRegistration:
    """Test that image gen tools are registered."""

    async def test_create_image_gen_tools(self):
        tools = create_image_gen_tools()
        assert len(tools) == 1
        assert tools[0].spec.name == "generate_image"

    async def test_registered_in_default_registry(self, db_pool):
        from core.tools import create_default_registry
        registry = create_default_registry(db_pool)
        tool_names = [t.spec.name for t in registry._handlers.values()]
        assert "generate_image" in tool_names
