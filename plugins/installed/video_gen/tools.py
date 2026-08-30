"""
Hexis Tools System - Video Generation (G.2)

Allows the agent to generate videos using Runway's Gen-4 Turbo API.
Returns the generation ID, status, and output URL.
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

_BASE_URL = "https://api.dev.runwayml.com/v1"
_RUNWAY_API_VERSION = "2024-11-06"
_VALID_ASPECT_RATIOS = {"16:9", "9:16", "1:1", "4:3", "3:4"}


def _headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-Runway-Version": _RUNWAY_API_VERSION,
    }


class GenerateVideoHandler(ToolHandler):
    """Generate videos using Runway Gen-4 Turbo API."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="generate_video",
            description=(
                "Generate a video from a text prompt using Runway Gen-4 Turbo. "
                "Returns a generation ID and status. The video may take time "
                "to render; poll the status or check back later for the output URL."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": (
                            "Text description of the video to generate. "
                            "Be specific about scene, motion, style, and mood."
                        ),
                    },
                    "duration": {
                        "type": "integer",
                        "description": "Video duration in seconds (2-16, default 4).",
                        "default": 4,
                        "minimum": 2,
                        "maximum": 16,
                    },
                    "aspect_ratio": {
                        "type": "string",
                        "description": "Aspect ratio for the video (default '16:9').",
                        "default": "16:9",
                        "enum": ["16:9", "9:16", "1:1", "4:3", "3:4"],
                    },
                },
                "required": ["prompt"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=8,
            is_read_only=False,
            requires_approval=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="runway",
            env_names=("RUNWAY_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Runway API key not configured. Set RUNWAY_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        prompt = arguments.get("prompt", "").strip()
        if not prompt:
            return ToolResult.error_result("Prompt is required.")

        duration = arguments.get("duration", 4)
        if not isinstance(duration, int) or duration < 2:
            duration = 2
        elif duration > 16:
            duration = 16

        aspect_ratio = arguments.get("aspect_ratio", "16:9")
        if aspect_ratio not in _VALID_ASPECT_RATIOS:
            aspect_ratio = "16:9"

        body = {
            "promptText": prompt,
            "duration": duration,
            "ratio": aspect_ratio,
            "model": "gen4_turbo",
        }

        try:
            data = await request_json(
                "runway",
                "POST",
                f"{_BASE_URL}/generations",
                headers=_headers(token),
                json_body=body,
                timeout=30.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=False,
            )
            if not isinstance(data, dict):
                data = {}

            return ToolResult.success_result(
                {
                    "id": data.get("id"),
                    "status": data.get("status"),
                    "output_url": data.get("output", [None])[0] if isinstance(data.get("output"), list) else data.get("output_url"),
                    "duration": duration,
                    "aspect_ratio": aspect_ratio,
                },
                display_output=(
                    f"Video generation started (id: {data.get('id')}, "
                    f"status: {data.get('status')}, {duration}s, {aspect_ratio})"
                ),
            )
        except IntegrationHttpError as e:
            return integration_error_result("Runway", e)
        except Exception as e:
            return ToolResult.error_result(f"Runway API error: {e}")


def create_video_gen_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create video generation tool handlers."""
    return [GenerateVideoHandler(api_key_resolver)]
