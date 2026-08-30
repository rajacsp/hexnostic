"""
Hexis Tools System - Usage Query Tool (H.4)

Allows the agent to query API usage and cost data from the api_usage table.
Wraps the usage_summary() and usage_daily() SQL functions.
"""

from __future__ import annotations

import json
import logging
from typing import Any, TYPE_CHECKING

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)


class QueryUsageHandler(ToolHandler):
    """Query API usage and cost data."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="query_usage",
            description=(
                "Query API usage statistics and costs. "
                "View spend by provider/model, daily trends, or overall summary. "
                "Answers questions like 'How much did I spend this week?', "
                "'Which model costs the most?', 'Show 30-day trend'."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "period": {
                        "type": "string",
                        "enum": ["day", "week", "month", "quarter", "year"],
                        "default": "month",
                        "description": "Time period to query",
                    },
                    "view": {
                        "type": "string",
                        "enum": ["summary", "daily", "top_models"],
                        "default": "summary",
                        "description": "View type: 'summary' (grouped totals), 'daily' (day-by-day breakdown), 'top_models' (ranked by cost)",
                    },
                    "source": {
                        "type": "string",
                        "enum": ["chat", "heartbeat", "cron", "sub_agent", "maintenance"],
                        "description": "Filter by usage source",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
            allowed_contexts={ToolContext.HEARTBEAT, ToolContext.CHAT, ToolContext.MCP},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result(
                "Database pool not available",
                ToolErrorType.MISSING_CONFIG,
            )
        try:
            async with pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT query_usage_tool($1::jsonb)", json.dumps(arguments)
                )
            payload = json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(payload, dict) and "success" in payload:
                if payload.get("success"):
                    return ToolResult.success_result(
                        payload.get("output"),
                        display_output=payload.get("display_output"),
                    )
                return ToolResult.error_result(
                    payload.get("error") or "Failed to query usage",
                    ToolErrorType.EXECUTION_FAILED,
                )
            return ToolResult.error_result(
                "Failed to query usage: unexpected payload", ToolErrorType.EXECUTION_FAILED
            )
        except Exception as exc:
            logger.exception("Failed to query usage")
            return ToolResult.error_result(
                f"Failed to query usage: {exc}", ToolErrorType.EXECUTION_FAILED
            )


def create_usage_tools() -> list[ToolHandler]:
    """Create usage query tools."""
    return [QueryUsageHandler()]
