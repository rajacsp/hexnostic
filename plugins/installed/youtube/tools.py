"""
Hexis Tools System - YouTube Data API Integration (E.5)

Tools for querying YouTube channel stats and searching videos.
Uses the YouTube Data API v3 with a key query parameter.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from core.integration_reliability import IntegrationHttpError, request_json
from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from core.tools.api_keys import resolve_api_key
from core.tools.integration_http import integration_error_result

logger = logging.getLogger(__name__)

_BASE_URL = "https://www.googleapis.com"


class GetYouTubeChannelStatsHandler(ToolHandler):
    """Get statistics for a YouTube channel."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="youtube_channel_stats",
            description="Get statistics and info for a YouTube channel by channel ID.",
            parameters={
                "type": "object",
                "properties": {
                    "channel_id": {
                        "type": "string",
                        "description": "YouTube channel ID (e.g. 'UC...')",
                    },
                },
                "required": ["channel_id"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        api_key = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="youtube",
            env_names=("YOUTUBE_API_KEY",),
        )
        if not api_key:
            return ToolResult.error_result(
                "YouTube API key not configured. Set YOUTUBE_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        channel_id = arguments["channel_id"]
        params = {
            "key": api_key,
            "id": channel_id,
            "part": "statistics,snippet",
        }

        try:
            data = await request_json(
                "youtube",
                "GET",
                f"{_BASE_URL}/youtube/v3/channels",
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )

            items = data.get("items", []) if isinstance(data, dict) else []
            if not items:
                return ToolResult.error_result(f"Channel not found: {channel_id}")

            channel = items[0]
            snippet = channel.get("snippet", {})
            stats = channel.get("statistics", {})

            return ToolResult.success_result(
                {
                    "channel_id": channel_id,
                    "title": snippet.get("title"),
                    "description": snippet.get("description", "")[:200],
                    "subscriber_count": stats.get("subscriberCount"),
                    "video_count": stats.get("videoCount"),
                    "view_count": stats.get("viewCount"),
                },
                display_output=f"Channel: {snippet.get('title', channel_id)}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("YouTube", e)
        except Exception as e:
            return ToolResult.error_result(f"YouTube API error: {e}")


class GetYouTubeVideoStatsHandler(ToolHandler):
    """Get statistics for a specific YouTube video."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="youtube_video_stats",
            description="Get statistics and metadata for a YouTube video by video ID.",
            parameters={
                "type": "object",
                "properties": {
                    "video_id": {
                        "type": "string",
                        "description": "YouTube video ID (e.g. 'dQw4w9WgXcQ')",
                    },
                },
                "required": ["video_id"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        api_key = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="youtube",
            env_names=("YOUTUBE_API_KEY",),
        )
        if not api_key:
            return ToolResult.error_result(
                "YouTube API key not configured. Set YOUTUBE_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        video_id = arguments["video_id"]
        params = {
            "key": api_key,
            "id": video_id,
            "part": "statistics,snippet,contentDetails",
        }

        try:
            data = await request_json(
                "youtube",
                "GET",
                f"{_BASE_URL}/youtube/v3/videos",
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )

            items = data.get("items", []) if isinstance(data, dict) else []
            if not items:
                return ToolResult.error_result(f"Video not found: {video_id}")

            video = items[0]
            snippet = video.get("snippet", {})
            stats = video.get("statistics", {})
            content_details = video.get("contentDetails", {})

            return ToolResult.success_result(
                {
                    "video_id": video_id,
                    "title": snippet.get("title"),
                    "channel_title": snippet.get("channelTitle"),
                    "published_at": snippet.get("publishedAt"),
                    "duration": content_details.get("duration"),
                    "view_count": stats.get("viewCount"),
                    "like_count": stats.get("likeCount"),
                    "comment_count": stats.get("commentCount"),
                },
                display_output=f"Video: {snippet.get('title', video_id)}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("YouTube", e)
        except Exception as e:
            return ToolResult.error_result(f"YouTube API error: {e}")


class SearchYouTubeVideosHandler(ToolHandler):
    """Search for YouTube videos."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="youtube_search",
            description="Search YouTube for videos by query. Returns video IDs, titles, channels, and descriptions.",
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Maximum number of results (default 5, max 50)",
                    },
                    "order": {
                        "type": "string",
                        "description": "Sort order: relevance, date, viewCount, rating (default 'relevance')",
                    },
                },
                "required": ["query"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        api_key = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="youtube",
            env_names=("YOUTUBE_API_KEY",),
        )
        if not api_key:
            return ToolResult.error_result(
                "YouTube API key not configured. Set YOUTUBE_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        query = arguments["query"]
        max_results = arguments.get("max_results", 5)
        order = arguments.get("order", "relevance")

        params = {
            "key": api_key,
            "q": query,
            "part": "snippet",
            "type": "video",
            "maxResults": max_results,
            "order": order,
        }

        try:
            data = await request_json(
                "youtube",
                "GET",
                f"{_BASE_URL}/youtube/v3/search",
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )

            videos = []
            rows = data.get("items", []) if isinstance(data, dict) else []
            for item in rows:
                snippet = item.get("snippet", {})
                video_id = item.get("id", {}).get("videoId")
                videos.append({
                    "id": video_id,
                    "title": snippet.get("title"),
                    "channel": snippet.get("channelTitle"),
                    "published_at": snippet.get("publishedAt"),
                    "description": snippet.get("description", "")[:200],
                })

            return ToolResult.success_result(
                {"videos": videos, "count": len(videos)},
                display_output=f"Found {len(videos)} video(s) for '{query}'",
            )
        except IntegrationHttpError as e:
            return integration_error_result("YouTube", e)
        except Exception as e:
            return ToolResult.error_result(f"YouTube API error: {e}")


def create_youtube_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create YouTube Data API tools."""
    return [
        GetYouTubeChannelStatsHandler(api_key_resolver),
        GetYouTubeVideoStatsHandler(api_key_resolver),
        SearchYouTubeVideosHandler(api_key_resolver),
    ]
