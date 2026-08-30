"""
Hexis Tools System - Backlog Management

A task/todo system that both the agent and user can CRUD.
Supports episodic memory creation when users modify the backlog,
multi-heartbeat continuation via checkpoints, and chat delegation.
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

_VALID_STATUSES = {"todo", "in_progress", "done", "blocked", "cancelled"}
_VALID_PRIORITIES = {"urgent", "high", "normal", "low"}
_VALID_OWNERS = {"agent", "user", "shared"}
_VALID_CREATED_BY = {"agent", "user"}
_VALID_ACTIONS = {"create", "update", "delete", "list", "get", "set_status", "set_checkpoint"}


class ManageBacklogHandler(ToolHandler):
    """Manage a shared backlog of tasks between agent and user."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="manage_backlog",
            description=(
                "Manage a shared task backlog. Actions: "
                "'create' (new task), "
                "'update' (modify fields), "
                "'delete' (remove task), "
                "'list' (view tasks), "
                "'get' (single task detail), "
                "'set_status' (change task status), "
                "'set_checkpoint' (save progress for continuation)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": list(_VALID_ACTIONS),
                        "description": "The backlog action to perform.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Task title (required for 'create').",
                    },
                    "description": {
                        "type": "string",
                        "description": "Task description (optional for 'create'/'update').",
                    },
                    "priority": {
                        "type": "string",
                        "enum": list(_VALID_PRIORITIES),
                        "description": "Priority: urgent, high, normal, low.",
                    },
                    "owner": {
                        "type": "string",
                        "enum": list(_VALID_OWNERS),
                        "description": "Who owns the task: agent, user, shared.",
                    },
                    "status": {
                        "type": "string",
                        "enum": list(_VALID_STATUSES),
                        "description": "Task status (for 'set_status').",
                    },
                    "item_id": {
                        "type": "string",
                        "description": "Backlog item ID (required for update/delete/get/set_status/set_checkpoint).",
                    },
                    "parent_id": {
                        "type": "string",
                        "description": "Parent task ID (optional for 'create', for subtasks).",
                    },
                    "tags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Tags for the task.",
                    },
                    "checkpoint": {
                        "type": "object",
                        "description": "Checkpoint data for multi-heartbeat continuation.",
                    },
                    "note": {
                        "type": "string",
                        "description": "Status change reason (optional for 'set_status').",
                    },
                    "status_filter": {
                        "type": "string",
                        "description": "Filter by status (for 'list').",
                    },
                    "priority_filter": {
                        "type": "string",
                        "description": "Filter by priority (for 'list').",
                    },
                    "owner_filter": {
                        "type": "string",
                        "description": "Filter by owner (for 'list').",
                    },
                },
                "required": ["action"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=False,
            requires_approval=False,
            allowed_contexts={ToolContext.HEARTBEAT, ToolContext.CHAT, ToolContext.MCP},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        action = arguments.get("action", "")
        if action not in _VALID_ACTIONS:
            return ToolResult.error_result(
                f"Invalid action '{action}'. Must be one of: {', '.join(sorted(_VALID_ACTIONS))}",
                ToolErrorType.INVALID_PARAMS,
            )
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result(
                "Database pool not available",
                ToolErrorType.MISSING_CONFIG,
            )
        # execute_backlog_tool (db/38) owns validation, mutation, and result
        # shaping; the former Python compatibility path was deleted.
        try:
            async with pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT execute_backlog_tool($1::jsonb, $2::jsonb)",
                    json.dumps(arguments),
                    json.dumps({"tool_context": context.tool_context.value}),
                )
        except Exception as exc:
            logger.exception("Backlog tool failed")
            return ToolResult.error_result(f"Backlog tool failed: {exc}", ToolErrorType.EXECUTION_FAILED)
        payload = json.loads(raw) if isinstance(raw, str) else raw
        if isinstance(payload, dict) and "success" in payload:
            if payload.get("success"):
                return ToolResult.success_result(payload.get("output"), payload.get("display_output"))
            return ToolResult.error_result(
                payload.get("error") or "Backlog tool failed",
                ToolErrorType(payload.get("error_type") or ToolErrorType.EXECUTION_FAILED.value),
            )
        return ToolResult.error_result(
            "Backlog tool returned an unexpected payload",
            ToolErrorType.EXECUTION_FAILED,
        )


def create_backlog_tools() -> list[ToolHandler]:
    """Create backlog management tools."""
    return [ManageBacklogHandler()]
