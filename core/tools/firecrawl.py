"""
Hexis Tools System - Firecrawl Integration (E.9)

Tool for scraping web pages using the Firecrawl API.
Returns clean markdown content from any URL.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from .api_keys import resolve_api_key

logger = logging.getLogger(__name__)

_BASE_URL = "https://api.firecrawl.dev"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class FirecrawlScrapeHandler(ToolHandler):
    """Scrape a web page using the Firecrawl API."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="firecrawl_scrape",
            description="Scrape a web page and return clean markdown content using Firecrawl.",
            parameters={
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL of the page to scrape",
                    },
                    "formats": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Output formats (default ['markdown']). Options: markdown, html, rawHtml, links, screenshot",
                    },
                },
                "required": ["url"],
            },
            category=ToolCategory.WEB,
            energy_cost=3,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="firecrawl",
            env_names=("FIRECRAWL_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Firecrawl API key not configured. Set FIRECRAWL_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        url = arguments["url"]
        formats = arguments.get("formats", ["markdown"])

        body = {
            "url": url,
            "formats": formats,
        }

        try:
            data = await request_json(
                "firecrawl",
                "POST",
                f"{_BASE_URL}/v1/scrape",
                headers=_headers(token),
                json_body=body,
                timeout=30.0,
                attempts=3,
                max_delay=20.0,
                retry_unsafe_methods=True,
            )
            if not isinstance(data, dict):
                return ToolResult.error_result(
                    "Firecrawl returned an invalid payload.",
                    ToolErrorType.HTTP_ERROR,
                )

            result_data = data.get("data", data)
            content = result_data.get("markdown", result_data.get("content", ""))
            metadata = result_data.get("metadata", {})

            return ToolResult.success_result(
                {
                    "url": url,
                    "content": content,
                    "title": metadata.get("title", ""),
                    "description": metadata.get("description", ""),
                    "format": formats[0] if formats else "markdown",
                },
                display_output=f"Scraped: {metadata.get('title', url)}",
            )
        except IntegrationHttpError as e:
            kind = (
                ToolErrorType.AUTH_FAILED if e.error_kind == "auth_failed"
                else ToolErrorType.RATE_LIMITED if e.error_kind == "rate_limited"
                else ToolErrorType.NETWORK_ERROR if e.error_kind == "network"
                else ToolErrorType.FETCH_TIMEOUT if e.error_kind == "timeout"
                else ToolErrorType.HTTP_ERROR
            )
            return ToolResult.error_result(format_provider_error("Firecrawl", e), kind)
        except Exception as e:
            return ToolResult.error_result(f"Firecrawl API error: {e}")


def create_firecrawl_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Firecrawl scraping tools."""
    return [
        FirecrawlScrapeHandler(api_key_resolver),
    ]
