"""
Hexis Tools System - Browser Automation

Playwright-based browser control for page navigation, interaction,
screenshots, and data extraction. Supports local Playwright or
remote CDP endpoints for containerized browsers.
"""

from __future__ import annotations

import asyncio
import base64
import logging
from typing import Any

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

logger = logging.getLogger(__name__)

# Per-session browser state
_session_browsers: dict[str, "_BrowserSession"] = {}


class _BrowserSession:
    """Manages a single browser session."""

    def __init__(self) -> None:
        self._playwright: Any = None
        self._browser: Any = None
        self._page: Any = None

    async def ensure_page(self, cdp_endpoint: str | None = None) -> Any:
        """Get or create the page, starting browser if needed."""
        if self._page is not None:
            return self._page

        try:
            from playwright.async_api import async_playwright
        except ImportError:
            raise RuntimeError(
                "playwright is not installed. Install with: pip install playwright && playwright install chromium"
            )

        self._playwright = await async_playwright().start()

        if cdp_endpoint:
            self._browser = await self._playwright.chromium.connect_over_cdp(cdp_endpoint)
        else:
            self._browser = await self._playwright.chromium.launch(headless=True)

        self._page = await self._browser.new_page()
        return self._page

    async def close(self) -> None:
        """Close browser and cleanup."""
        try:
            if self._page:
                await self._page.close()
        except Exception:
            pass
        try:
            if self._browser:
                await self._browser.close()
        except Exception:
            pass
        try:
            if self._playwright:
                await self._playwright.stop()
        except Exception:
            pass
        self._page = None
        self._browser = None
        self._playwright = None


def _get_session(session_id: str | None) -> _BrowserSession:
    key = session_id or "__default__"
    if key not in _session_browsers:
        _session_browsers[key] = _BrowserSession()
    return _session_browsers[key]


async def cleanup_browser_session(session_id: str) -> None:
    """Close and remove a browser session."""
    key = session_id or "__default__"
    if key in _session_browsers:
        await _session_browsers[key].close()
        del _session_browsers[key]


class BrowserHandler(ToolHandler):
    """Control a web browser via Playwright."""

    def __init__(self, cdp_endpoint: str | None = None) -> None:
        self._cdp_endpoint = cdp_endpoint

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="browser",
            description=(
                "Control a web browser. Actions: navigate (go to URL), click (click element), "
                "type (type text into element), screenshot (capture page), extract (get text from element), "
                "evaluate (run JavaScript), wait (wait for element), close (close browser)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["navigate", "click", "type", "screenshot", "extract", "evaluate", "wait", "close"],
                        "description": "The browser action to perform",
                    },
                    "url": {
                        "type": "string",
                        "description": "URL to navigate to (for 'navigate' action)",
                    },
                    "selector": {
                        "type": "string",
                        "description": "CSS selector for the target element (for click/type/extract/wait)",
                    },
                    "text": {
                        "type": "string",
                        "description": "Text to type (for 'type' action)",
                    },
                    "script": {
                        "type": "string",
                        "description": "JavaScript code to execute (for 'evaluate' action)",
                    },
                    "timeout": {
                        "type": "integer",
                        "description": "Timeout in milliseconds (default 30000)",
                    },
                },
                "required": ["action"],
            },
            category=ToolCategory.BROWSER,
            energy_cost=4,
            is_read_only=False,
            requires_approval=True,
            supports_parallel=False,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        action = arguments.get("action", "")
        timeout = int(arguments.get("timeout", 30000))

        if action == "close":
            await cleanup_browser_session(context.session_id)
            return ToolResult.success_result("Browser closed")

        session = _get_session(context.session_id)

        try:
            page = await session.ensure_page(self._cdp_endpoint)
        except RuntimeError as e:
            return ToolResult.error_result(str(e), ToolErrorType.MISSING_DEPENDENCY)
        except Exception as e:
            return ToolResult.error_result(f"Failed to start browser: {e}")

        try:
            if action == "navigate":
                url = arguments.get("url", "")
                if not url:
                    return ToolResult.error_result("URL is required for navigate action")
                response = await page.goto(url, timeout=timeout, wait_until="domcontentloaded")
                status = response.status if response else "unknown"
                title = await page.title()
                return ToolResult.success_result(
                    {"status": status, "title": title, "url": page.url},
                    display_output=f"Navigated to {page.url} (status {status}, title: {title})",
                )

            elif action == "click":
                selector = arguments.get("selector", "")
                if not selector:
                    return ToolResult.error_result("Selector is required for click action")
                await page.click(selector, timeout=timeout)
                return ToolResult.success_result(
                    {"clicked": selector},
                    display_output=f"Clicked: {selector}",
                )

            elif action == "type":
                selector = arguments.get("selector", "")
                text = arguments.get("text", "")
                if not selector:
                    return ToolResult.error_result("Selector is required for type action")
                await page.fill(selector, text, timeout=timeout)
                return ToolResult.success_result(
                    {"typed": text, "into": selector},
                    display_output=f"Typed '{text}' into {selector}",
                )

            elif action == "screenshot":
                screenshot_bytes = await page.screenshot(full_page=True)
                b64 = base64.b64encode(screenshot_bytes).decode("utf-8")
                return ToolResult.success_result(
                    {"screenshot_base64": b64, "size_bytes": len(screenshot_bytes)},
                    display_output=f"Screenshot captured ({len(screenshot_bytes)} bytes)",
                )

            elif action == "extract":
                selector = arguments.get("selector", "")
                if not selector:
                    # Extract full page text
                    text = await page.inner_text("body", timeout=timeout)
                else:
                    text = await page.inner_text(selector, timeout=timeout)
                # Truncate very long extractions
                if len(text) > 10000:
                    text = text[:10000] + "...[truncated]"
                return ToolResult.success_result(
                    {"text": text, "selector": selector or "body"},
                    display_output=text[:2000],
                )

            elif action == "evaluate":
                script = arguments.get("script", "")
                if not script:
                    return ToolResult.error_result("Script is required for evaluate action")
                result = await page.evaluate(script)
                return ToolResult.success_result(
                    {"result": result},
                    display_output=str(result)[:2000],
                )

            elif action == "wait":
                selector = arguments.get("selector", "")
                if not selector:
                    return ToolResult.error_result("Selector is required for wait action")
                await page.wait_for_selector(selector, timeout=timeout)
                return ToolResult.success_result(
                    {"found": selector},
                    display_output=f"Element found: {selector}",
                )

            else:
                return ToolResult.error_result(
                    f"Unknown browser action: {action}. "
                    f"Valid actions: navigate, click, type, screenshot, extract, evaluate, wait, close"
                )

        except Exception as e:
            error_msg = str(e)
            if len(error_msg) > 500:
                error_msg = error_msg[:500] + "..."
            return ToolResult.error_result(error_msg)


def create_browser_tools(cdp_endpoint: str | None = None) -> list[ToolHandler]:
    """Create browser automation tool handlers."""
    return [BrowserHandler(cdp_endpoint=cdp_endpoint)]
