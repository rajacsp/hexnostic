"""
Tests for Phase 3: Browser Automation

Covers BrowserHandler: navigate, click, type, screenshot, extract, evaluate,
wait, close actions. All tests mock Playwright since it may not be installed.
"""

from __future__ import annotations

import base64
import uuid
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolSpec,
)
from core.tools.browser import (
    BrowserHandler,
    _BrowserSession,
    _session_browsers,
    cleanup_browser_session,
    create_browser_tools,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Helpers
# ============================================================================


def _make_context(session_id: str | None = None) -> ToolExecutionContext:
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id=str(uuid.uuid4()),
        session_id=session_id or f"test-browser-{uuid.uuid4().hex[:8]}",
    )


def _mock_page() -> AsyncMock:
    """Create a mock Playwright page with common async methods."""
    page = AsyncMock()
    page.url = "https://example.com"
    page.title = AsyncMock(return_value="Example Domain")
    page.goto = AsyncMock(return_value=MagicMock(status=200))
    page.click = AsyncMock()
    page.fill = AsyncMock()
    page.screenshot = AsyncMock(return_value=b"\x89PNG\r\n\x1a\nfake_image_data")
    page.inner_text = AsyncMock(return_value="Hello World")
    page.evaluate = AsyncMock(return_value=42)
    page.wait_for_selector = AsyncMock()
    page.close = AsyncMock()
    return page


def _mock_session_with_page(page: AsyncMock) -> _BrowserSession:
    """Create a _BrowserSession pre-loaded with a mock page."""
    session = _BrowserSession()
    session._page = page
    session._browser = AsyncMock()
    session._playwright = AsyncMock()
    return session


@pytest.fixture(autouse=True)
def _cleanup_sessions():
    """Ensure session dict is clean before/after each test."""
    _session_browsers.clear()
    yield
    _session_browsers.clear()


# ============================================================================
# Spec validation
# ============================================================================


class TestBrowserSpec:
    def test_spec_basics(self):
        handler = BrowserHandler()
        spec = handler.spec
        assert spec.name == "browser"
        assert spec.category == ToolCategory.BROWSER
        assert spec.energy_cost == 4
        assert spec.requires_approval is True
        assert spec.supports_parallel is False
        assert spec.is_read_only is False

    def test_spec_allowed_contexts(self):
        handler = BrowserHandler()
        spec = handler.spec
        assert ToolContext.CHAT in spec.allowed_contexts
        assert ToolContext.HEARTBEAT in spec.allowed_contexts
        assert ToolContext.MCP not in spec.allowed_contexts

    def test_spec_actions_enum(self):
        handler = BrowserHandler()
        spec = handler.spec
        actions = spec.parameters["properties"]["action"]["enum"]
        assert set(actions) == {
            "navigate", "click", "type", "screenshot",
            "extract", "evaluate", "wait", "close",
        }

    def test_spec_required_fields(self):
        handler = BrowserHandler()
        spec = handler.spec
        assert spec.parameters["required"] == ["action"]

    def test_openai_function_format(self):
        handler = BrowserHandler()
        fn = handler.spec.to_openai_function()
        assert fn["type"] == "function"
        assert fn["function"]["name"] == "browser"
        assert "parameters" in fn["function"]

    def test_cdp_endpoint_stored(self):
        handler = BrowserHandler(cdp_endpoint="ws://localhost:9222")
        assert handler._cdp_endpoint == "ws://localhost:9222"


# ============================================================================
# Navigate action
# ============================================================================


class TestNavigateAction:
    async def test_navigate_success(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "navigate", "url": "https://example.com"}, ctx)

        assert result.success is True
        assert result.output["status"] == 200
        assert result.output["title"] == "Example Domain"
        assert result.output["url"] == "https://example.com"
        page.goto.assert_awaited_once()

    async def test_navigate_missing_url(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "navigate"}, ctx)

        assert result.success is False
        assert "URL is required" in result.error

    async def test_navigate_none_response(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        page.goto = AsyncMock(return_value=None)
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "navigate", "url": "https://example.com"}, ctx)

        assert result.success is True
        assert result.output["status"] == "unknown"


# ============================================================================
# Click action
# ============================================================================


class TestClickAction:
    async def test_click_success(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "click", "selector": "#btn"}, ctx)

        assert result.success is True
        assert result.output["clicked"] == "#btn"
        page.click.assert_awaited_once_with("#btn", timeout=30000)

    async def test_click_missing_selector(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "click"}, ctx)

        assert result.success is False
        assert "Selector is required" in result.error


# ============================================================================
# Type action
# ============================================================================


class TestTypeAction:
    async def test_type_success(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute(
            {"action": "type", "selector": "#input", "text": "hello"},
            ctx,
        )

        assert result.success is True
        assert result.output["typed"] == "hello"
        assert result.output["into"] == "#input"
        page.fill.assert_awaited_once_with("#input", "hello", timeout=30000)

    async def test_type_missing_selector(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "type", "text": "hello"}, ctx)

        assert result.success is False
        assert "Selector is required" in result.error


# ============================================================================
# Screenshot action
# ============================================================================


class TestScreenshotAction:
    async def test_screenshot_returns_base64(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        raw_bytes = b"\x89PNG\r\n\x1a\nsome_image_data_here"
        page.screenshot = AsyncMock(return_value=raw_bytes)
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "screenshot"}, ctx)

        assert result.success is True
        assert result.output["screenshot_base64"] == base64.b64encode(raw_bytes).decode("utf-8")
        assert result.output["size_bytes"] == len(raw_bytes)
        page.screenshot.assert_awaited_once_with(full_page=True)


# ============================================================================
# Extract action
# ============================================================================


class TestExtractAction:
    async def test_extract_with_selector(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        page.inner_text = AsyncMock(return_value="Extracted text")
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "extract", "selector": ".content"}, ctx)

        assert result.success is True
        assert result.output["text"] == "Extracted text"
        assert result.output["selector"] == ".content"
        page.inner_text.assert_awaited_once_with(".content", timeout=30000)

    async def test_extract_full_page(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        page.inner_text = AsyncMock(return_value="Full page text")
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "extract"}, ctx)

        assert result.success is True
        assert result.output["selector"] == "body"
        page.inner_text.assert_awaited_once_with("body", timeout=30000)

    async def test_extract_truncates_long_text(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        long_text = "x" * 15000
        page.inner_text = AsyncMock(return_value=long_text)
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "extract", "selector": "body"}, ctx)

        assert result.success is True
        assert len(result.output["text"]) == 10000 + len("...[truncated]")
        assert result.output["text"].endswith("...[truncated]")


# ============================================================================
# Evaluate action
# ============================================================================


class TestEvaluateAction:
    async def test_evaluate_returns_result(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        page.evaluate = AsyncMock(return_value={"key": "value"})
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute(
            {"action": "evaluate", "script": "document.title"},
            ctx,
        )

        assert result.success is True
        assert result.output["result"] == {"key": "value"}
        page.evaluate.assert_awaited_once_with("document.title")

    async def test_evaluate_missing_script(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "evaluate"}, ctx)

        assert result.success is False
        assert "Script is required" in result.error


# ============================================================================
# Wait action
# ============================================================================


class TestWaitAction:
    async def test_wait_success(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "wait", "selector": "#loaded"}, ctx)

        assert result.success is True
        assert result.output["found"] == "#loaded"
        page.wait_for_selector.assert_awaited_once_with("#loaded", timeout=30000)

    async def test_wait_missing_selector(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "wait"}, ctx)

        assert result.success is False
        assert "Selector is required" in result.error

    async def test_wait_custom_timeout(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute(
            {"action": "wait", "selector": "#el", "timeout": 5000},
            ctx,
        )

        assert result.success is True
        page.wait_for_selector.assert_awaited_once_with("#el", timeout=5000)


# ============================================================================
# Close action
# ============================================================================


class TestCloseAction:
    async def test_close_success(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "close"}, ctx)

        assert result.success is True
        assert result.output == "Browser closed"
        # Session should be removed
        assert ctx.session_id not in _session_browsers

    async def test_close_nonexistent_session(self):
        handler = BrowserHandler()
        ctx = _make_context()

        result = await handler.execute({"action": "close"}, ctx)

        assert result.success is True
        assert result.output == "Browser closed"


# ============================================================================
# Unknown action
# ============================================================================


class TestUnknownAction:
    async def test_unknown_action(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "destroy"}, ctx)

        assert result.success is False
        assert "Unknown browser action: destroy" in result.error
        assert "Valid actions:" in result.error


# ============================================================================
# Error handling
# ============================================================================


class TestErrorHandling:
    async def test_playwright_not_installed(self):
        handler = BrowserHandler()
        ctx = _make_context()
        # No pre-loaded session → ensure_page will try to import playwright

        with patch.dict("sys.modules", {"playwright": None, "playwright.async_api": None}):
            # Force a fresh session that will fail on import
            session = _BrowserSession()
            _session_browsers[ctx.session_id] = session
            # Directly mock ensure_page to raise RuntimeError (simulating ImportError path)
            session.ensure_page = AsyncMock(
                side_effect=RuntimeError(
                    "playwright is not installed. Install with: pip install playwright && playwright install chromium"
                )
            )

            result = await handler.execute({"action": "navigate", "url": "https://example.com"}, ctx)

        assert result.success is False
        assert result.error_type == ToolErrorType.MISSING_DEPENDENCY
        assert "playwright is not installed" in result.error

    async def test_browser_launch_failure(self):
        handler = BrowserHandler()
        ctx = _make_context()
        session = _BrowserSession()
        session.ensure_page = AsyncMock(side_effect=ConnectionError("refused"))
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "navigate", "url": "https://example.com"}, ctx)

        assert result.success is False
        assert "Failed to start browser" in result.error

    async def test_action_exception_caught(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        page.click = AsyncMock(side_effect=TimeoutError("Element not found within 30000ms"))
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "click", "selector": "#missing"}, ctx)

        assert result.success is False
        assert "Element not found" in result.error

    async def test_long_error_truncated(self):
        handler = BrowserHandler()
        ctx = _make_context()
        page = _mock_page()
        long_error = "x" * 1000
        page.click = AsyncMock(side_effect=Exception(long_error))
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await handler.execute({"action": "click", "selector": "#el"}, ctx)

        assert result.success is False
        assert len(result.error) <= 504  # 500 + "..."


# ============================================================================
# Session management
# ============================================================================


class TestSessionManagement:
    async def test_sessions_isolated(self):
        page1 = _mock_page()
        page2 = _mock_page()
        page1.url = "https://page1.com"
        page2.url = "https://page2.com"

        session1 = _mock_session_with_page(page1)
        session2 = _mock_session_with_page(page2)

        ctx1 = _make_context("session-1")
        ctx2 = _make_context("session-2")

        _session_browsers["session-1"] = session1
        _session_browsers["session-2"] = session2

        handler = BrowserHandler()

        r1 = await handler.execute({"action": "navigate", "url": "https://page1.com"}, ctx1)
        r2 = await handler.execute({"action": "navigate", "url": "https://page2.com"}, ctx2)

        assert r1.success and r2.success
        assert r1.output["url"] == "https://page1.com"
        assert r2.output["url"] == "https://page2.com"

    async def test_cleanup_removes_session(self):
        page = _mock_page()
        browser = AsyncMock()
        playwright = AsyncMock()
        session = _BrowserSession()
        session._page = page
        session._browser = browser
        session._playwright = playwright
        _session_browsers["cleanup-test"] = session

        await cleanup_browser_session("cleanup-test")

        assert "cleanup-test" not in _session_browsers
        page.close.assert_awaited_once()
        browser.close.assert_awaited_once()
        playwright.stop.assert_awaited_once()

    async def test_cleanup_nonexistent_session_no_error(self):
        # Should not raise
        await cleanup_browser_session("does-not-exist")


# ============================================================================
# CDP endpoint
# ============================================================================


class TestCDPEndpoint:
    async def test_cdp_endpoint_passed_to_session(self):
        handler = BrowserHandler(cdp_endpoint="ws://browser:9222")
        ctx = _make_context()

        # Mock the session's ensure_page to verify cdp_endpoint is forwarded
        session = _BrowserSession()
        session.ensure_page = AsyncMock(return_value=_mock_page())
        _session_browsers[ctx.session_id] = session

        await handler.execute({"action": "navigate", "url": "https://example.com"}, ctx)

        session.ensure_page.assert_awaited_once_with("ws://browser:9222")


# ============================================================================
# Factory function
# ============================================================================


class TestFactory:
    def test_create_browser_tools_default(self):
        tools = create_browser_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], BrowserHandler)
        assert tools[0]._cdp_endpoint is None

    def test_create_browser_tools_with_cdp(self):
        tools = create_browser_tools(cdp_endpoint="ws://localhost:9222")
        assert len(tools) == 1
        assert tools[0]._cdp_endpoint == "ws://localhost:9222"


# ============================================================================
# Registry integration
# ============================================================================


class TestRegistryIntegration:
    async def test_browser_in_default_registry(self, db_pool):
        from core.tools.registry import create_default_registry

        registry = create_default_registry(db_pool)
        specs = await registry.get_specs(ToolContext.CHAT)
        tool_names = [s["function"]["name"] for s in specs]
        assert "browser" in tool_names

    async def test_browser_not_in_mcp_context(self, db_pool):
        from core.tools.registry import create_default_registry

        registry = create_default_registry(db_pool)
        specs = await registry.get_specs(ToolContext.MCP)
        tool_names = [s["function"]["name"] for s in specs]
        assert "browser" not in tool_names

    async def test_execute_via_registry(self, db_pool):
        from core.tools.registry import create_default_registry

        registry = create_default_registry(db_pool)
        ctx = _make_context()

        # Pre-load a mock session so it doesn't try to launch real Playwright
        page = _mock_page()
        session = _mock_session_with_page(page)
        _session_browsers[ctx.session_id] = session

        result = await registry.execute(
            "browser",
            {"action": "navigate", "url": "https://example.com"},
            ctx,
        )

        assert result.success is True
        assert result.output["status"] == 200


# ============================================================================
# Validate method
# ============================================================================


class TestValidation:
    def test_validate_valid_args(self):
        handler = BrowserHandler()
        errors = handler.validate({"action": "navigate", "url": "https://example.com"})
        assert errors == []

    def test_validate_missing_action(self):
        handler = BrowserHandler()
        errors = handler.validate({})
        assert any("action" in e for e in errors)

    def test_validate_wrong_type(self):
        handler = BrowserHandler()
        errors = handler.validate({"action": 123})
        assert any("string" in e for e in errors)
