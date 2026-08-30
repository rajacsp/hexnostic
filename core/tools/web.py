"""
Hexis Tools System - Web Tools

Tools for web operations (search, fetch content).
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from .base import (
    ToolCategory,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from .config import ToolsConfig
from .web_search_providers import (
    WebSearchProviderError,
    WebSearchProviderRegistry,
    create_default_web_search_registry,
    display_output_for_search,
)

logger = logging.getLogger(__name__)

def _validate_url_host(url: str) -> list[str]:
    errors: list[str] = []
    if not url:
        return errors
    import socket
    import urllib.parse
    import ipaddress

    try:
        parsed = urllib.parse.urlparse(url)
        host = parsed.hostname or ""
        if host in ("localhost", "127.0.0.1", "0.0.0.0", "::1"):
            errors.append("Cannot fetch localhost URLs")
        if host:
            # First check if host is already an IP literal
            try:
                ip = ipaddress.ip_address(host)
                if ip.is_private or ip.is_loopback or ip.is_link_local:
                    errors.append("Cannot fetch internal network URLs")
            except ValueError:
                # Host is a hostname — resolve it and check the resolved IP
                try:
                    resolved = socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
                    for family, _, _, _, sockaddr in resolved:
                        resolved_ip = ipaddress.ip_address(sockaddr[0])
                        if resolved_ip.is_private or resolved_ip.is_loopback or resolved_ip.is_link_local:
                            errors.append(f"Hostname '{host}' resolves to internal IP {resolved_ip}")
                            break
                except socket.gaierror:
                    errors.append(f"Cannot resolve hostname: {host}")
    except Exception:
        errors.append("Invalid URL format")
    return errors


class WebSearchHandler(ToolHandler):
    """
    Provider-neutral web search.

    Provides up-to-date information from the web for questions about
    recent events, facts, or topics the agent is uncertain about.
    """

    def __init__(
        self,
        api_key_resolver: Callable[[], str | None] | None = None,
        provider_registry: WebSearchProviderRegistry | None = None,
    ):
        """
        Args:
            api_key_resolver: Optional Tavily API key resolver for legacy callers.
            provider_registry: Optional provider registry override for tests/plugins.
        """
        self._provider_registry = provider_registry or create_default_web_search_registry(
            tavily_api_key_resolver=api_key_resolver,
        )

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="web_search",
            description=(
                "Search the web for current information. Use for questions about "
                "recent events, facts you're uncertain about, or topics that may have "
                "changed since your knowledge cutoff. Returns relevant search results "
                "with titles, URLs, and snippets."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query - be specific and include relevant keywords.",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Maximum number of results to return (default: 5, max: 10).",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 10,
                    },
                },
                "required": ["query"],
            },
            category=ToolCategory.WEB,
            energy_cost=2,
            is_read_only=True,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        query = arguments.get("query", "")
        if not query or not query.strip():
            errors.append("query cannot be empty")
        if len(query) > 1000:
            errors.append("query too long (max 1000 characters)")
        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        # Check network access
        if not context.allow_network:
            return ToolResult.error_result(
                "Network access not allowed in this context",
                ToolErrorType.PERMISSION_DENIED,
            )

        query = arguments["query"]
        max_results = min(arguments.get("max_results", 5), 10)
        try:
            config = await context.registry.get_config() if context.registry else ToolsConfig()
            response, provider_errors = await self._provider_registry.search(
                query=query,
                max_results=max_results,
                config=config,
            )
            output = response.to_dict()
            if provider_errors:
                output["provider_errors"] = provider_errors
            return ToolResult.success_result(
                output=output,
                display_output=display_output_for_search(response),
            )
        except WebSearchProviderError as exc:
            return ToolResult.error_result(str(exc), exc.error_type)
        except TimeoutError:
            return ToolResult.error_result(
                "Search request timed out",
                ToolErrorType.TIMEOUT,
            )
        except Exception as e:
            logger.exception("Web search failed")
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)

class WebFetchHandler(ToolHandler):
    """
    Fetch and extract readable content from a URL.

    Uses trafilatura for intelligent content extraction that removes
    navigation, ads, and other non-content elements.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="web_fetch",
            description=(
                "Fetch content from a URL and extract readable text. Use for reading "
                "articles, documentation, blog posts, or web pages. Automatically "
                "removes navigation, ads, and other non-content elements."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to fetch - must be a valid HTTP or HTTPS URL.",
                    },
                    "max_chars": {
                        "type": "integer",
                        "description": "Maximum characters to return (default: 10000, max: 50000).",
                        "default": 10000,
                        "minimum": 1000,
                        "maximum": 50000,
                    },
                    "include_tables": {
                        "type": "boolean",
                        "description": "Include table content in extraction.",
                        "default": True,
                    },
                    "include_links": {
                        "type": "boolean",
                        "description": "Include hyperlinks in output.",
                        "default": False,
                    },
                },
                "required": ["url"],
            },
            category=ToolCategory.WEB,
            energy_cost=2,
            is_read_only=True,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        url = arguments.get("url", "")

        if not url:
            errors.append("url is required")
        elif not (url.startswith("http://") or url.startswith("https://")):
            errors.append("url must start with http:// or https://")

        # Basic URL validation
        errors.extend(_validate_url_host(url))

        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        # Check network access
        if not context.allow_network:
            return ToolResult.error_result(
                "Network access not allowed in this context",
                ToolErrorType.PERMISSION_DENIED,
            )

        try:
            import trafilatura
        except ImportError:
            return ToolResult.error_result(
                "trafilatura not installed. Install with: pip install trafilatura",
                ToolErrorType.MISSING_DEPENDENCY,
            )

        url = arguments["url"]
        max_chars = min(arguments.get("max_chars", 10000), 50000)
        include_tables = arguments.get("include_tables", True)
        include_links = arguments.get("include_links", False)

        try:
            # Fetch the URL
            downloaded = trafilatura.fetch_url(url)

            if not downloaded:
                return ToolResult.error_result(
                    f"Failed to fetch URL: {url}",
                    ToolErrorType.EXECUTION_FAILED,
                )

            # Extract content
            content = trafilatura.extract(
                downloaded,
                include_tables=include_tables,
                include_links=include_links,
                output_format="txt",
            )

            if not content:
                return ToolResult.error_result(
                    "Failed to extract content from URL - page may be empty or use JavaScript rendering",
                    ToolErrorType.EXECUTION_FAILED,
                )

            # Get metadata
            metadata = trafilatura.extract_metadata(downloaded)
            title = metadata.title if metadata else None
            author = metadata.author if metadata else None
            date = str(metadata.date) if metadata and metadata.date else None

            # Truncate if needed
            truncated = False
            if len(content) > max_chars:
                content = content[:max_chars]
                truncated = True

            output = {
                "url": url,
                "title": title,
                "author": author,
                "date": date,
                "content": content,
                "char_count": len(content),
                "truncated": truncated,
            }

            # Format display output
            display_parts = []
            if title:
                display_parts.append(f"Title: {title}")
            display_parts.append(f"URL: {url}")
            display_parts.append(f"Extracted {len(content)} characters")
            if truncated:
                display_parts.append("(truncated)")

            return ToolResult.success_result(
                output=output,
                display_output="\n".join(display_parts),
            )

        except Exception as e:
            logger.exception(f"Web fetch failed for {url}")
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)


class WebSummarizeHandler(ToolHandler):
    """
    Fetch a URL and summarize its content using LLM.

    Combines web fetch with LLM summarization for efficient
    information extraction.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="web_summarize",
            description=(
                "Fetch a URL and get an AI-generated summary of its content. "
                "Useful when you need the key points from a page without reading "
                "the full content."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to fetch and summarize.",
                    },
                    "focus": {
                        "type": "string",
                        "description": "Optional focus area - what aspect to focus the summary on.",
                    },
                    "max_length": {
                        "type": "string",
                        "enum": ["brief", "standard", "detailed"],
                        "description": "Desired summary length.",
                        "default": "standard",
                    },
                },
                "required": ["url"],
            },
            category=ToolCategory.WEB,
            energy_cost=4,  # Higher cost due to LLM call
            is_read_only=True,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        url = arguments.get("url", "")

        if not url:
            errors.append("url is required")
        elif not (url.startswith("http://") or url.startswith("https://")):
            errors.append("url must start with http:// or https://")
        errors.extend(_validate_url_host(url))

        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        if not context.allow_network:
            return ToolResult.error_result(
                "Network access not allowed in this context",
                ToolErrorType.PERMISSION_DENIED,
            )

        try:
            import trafilatura
        except ImportError:
            return ToolResult.error_result(
                "trafilatura not installed",
                ToolErrorType.MISSING_DEPENDENCY,
            )

        url = arguments["url"]
        focus = arguments.get("focus")
        max_length = arguments.get("max_length", "standard")

        # First fetch the content
        try:
            downloaded = trafilatura.fetch_url(url)
            if not downloaded:
                return ToolResult.error_result(
                    f"Failed to fetch URL: {url}",
                    ToolErrorType.EXECUTION_FAILED,
                )

            content = trafilatura.extract(downloaded, include_tables=True)
            if not content:
                return ToolResult.error_result(
                    "Failed to extract content from URL",
                    ToolErrorType.EXECUTION_FAILED,
                )

            metadata = trafilatura.extract_metadata(downloaded)
            title = metadata.title if metadata else None

        except Exception as e:
            return ToolResult.error_result(
                f"Failed to fetch URL: {e}",
                ToolErrorType.EXECUTION_FAILED,
            )

        # Truncate content for summarization
        max_content = 15000
        if len(content) > max_content:
            content = content[:max_content] + "\n\n[Content truncated for summarization]"

        # Build summarization prompt
        length_guide = {
            "brief": "2-3 sentences",
            "standard": "1-2 paragraphs",
            "detailed": "3-5 paragraphs with key points",
        }

        prompt = f"""Summarize the following web page content in {length_guide.get(max_length, '1-2 paragraphs')}.

Title: {title or 'Unknown'}
URL: {url}
"""
        if focus:
            prompt += f"\nFocus on: {focus}\n"

        prompt += f"\nContent:\n{content}"

        # Summarize with a direct in-process LLM call (the configured provider).
        try:
            from core.llm import chat_completion
            from core.llm_config import load_llm_config

            try:
                llm_config = await load_llm_config(context.registry.pool, preference="cheap")
            except Exception:
                llm_config = await load_llm_config(context.registry.pool)

            response = await chat_completion(
                messages=[{"role": "user", "content": prompt}],
                **{**llm_config, "max_tokens": 500},
            )

            summary = response.get("content", "") if response else ""
            if isinstance(summary, list):  # some providers return content blocks
                summary = "".join(
                    b.get("text", "")
                    for b in summary
                    if isinstance(b, dict) and b.get("type") == "text"
                )
            summary = (summary or "").strip()
            if not summary:
                return ToolResult.error_result(
                    "Summarization returned an empty result",
                    ToolErrorType.EXECUTION_FAILED,
                )

            return ToolResult.success_result(
                output={"url": url, "title": title, "summary": summary, "focus": focus},
                display_output=f"Summary of {title or url}:\n{summary}",
            )

        except Exception as e:
            logger.exception("Web summarize failed")
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)


def create_web_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """
    Create all web tool handlers.

    Args:
        api_key_resolver: Legacy optional callable to resolve a Tavily API key.
            Provider selection and DB-configured keys are handled by the
            web-search provider registry.

    Returns:
        List of web tool handlers.
    """
    return [
        WebSearchHandler(api_key_resolver),
        WebFetchHandler(),
        WebSummarizeHandler(),
    ]
