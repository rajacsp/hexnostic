"""
Hexis Tools System - Scheduled Task Management (Cron)

Allows the agent to create, list, update, and cancel scheduled tasks
through the standard tool_use interface. Wraps the database functions
in db/19_functions_scheduling.sql.
"""

from __future__ import annotations

import json
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

_VALID_ACTIONS = {"create", "list", "update", "cancel", "stats"}
_VALID_SCHEDULE_KINDS = {"once", "interval", "daily", "weekly", "cron"}
_VALID_ACTION_KINDS = {"queue_user_message", "create_goal"}
_VALID_DELIVERY_MODES = {"outbox", "channel", "webhook", "silent"}


# Cron parsing, validation, and next-fire math live in the DB
# (cron_next_fire / parse_schedule_input / manage_schedule_tool); the
# former croniter helpers were deleted.


class ManageScheduleHandler(ToolHandler):
    """Manage scheduled tasks: create, list, update, or cancel recurring/one-shot tasks."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="manage_schedule",
            description=(
                "Manage your scheduled tasks. Actions: "
                "'create' (new task), "
                "'list' (view scheduled tasks), "
                "'update' (modify a task), "
                "'cancel' (disable/delete a task), "
                "'stats' (execution statistics). "
                "Schedule kinds: 'once' (one-shot), 'interval' (recurring), 'daily', 'weekly', "
                "'cron' (standard cron expression like '0 9 * * *'). "
                "Shorthand: 'once:+2h', 'daily:07:00', 'weekly:monday:09:00', 'every:5m', "
                "or standard cron: '*/15 * * * *', '0 9 * * 1-5'. "
                "Use this only for explicit future or recurring work; for an immediate "
                "message to the user, call queue_user_message directly and do not invent a delay. "
                "Action kinds: 'queue_user_message' (send a message prompt to yourself), "
                "'create_goal' (create a goal when the task fires). "
                "Delivery modes: 'outbox' (default), 'channel' (specific channel+topic), "
                "'webhook' (HTTP POST), 'silent' (log only, no notification)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": list(_VALID_ACTIONS),
                        "description": "The scheduling action to perform.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Name for the scheduled task (required for 'create').",
                    },
                    "description": {
                        "type": "string",
                        "description": "Description of what the task does (optional).",
                    },
                    "schedule_kind": {
                        "type": "string",
                        "enum": list(_VALID_SCHEDULE_KINDS),
                        "description": "Schedule type: 'once', 'interval', 'daily', 'weekly'. Can also use shorthand in 'schedule' field.",
                    },
                    "schedule": {
                        "type": "string",
                        "description": (
                            "Schedule specification. Either a shorthand like 'daily:07:00', "
                            "'once:+2h', 'every:5m', 'weekly:monday:09:00' — or a JSON object "
                            "matching the schedule_kind (e.g. {\"time\": \"07:00\"} for daily). "
                            "Do not use a tiny one-shot delay for an immediate send request."
                        ),
                    },
                    "timezone": {
                        "type": "string",
                        "description": "Timezone for the schedule (default: UTC). E.g. 'America/New_York'.",
                    },
                    "action_kind": {
                        "type": "string",
                        "enum": list(_VALID_ACTION_KINDS),
                        "description": (
                            "What to do when the task fires. Default: 'queue_user_message'. "
                            "For immediate user messages, use queue_user_message without scheduling."
                        ),
                    },
                    "message": {
                        "type": "string",
                        "description": "Message/prompt for 'queue_user_message' action_kind (required for create with queue_user_message).",
                    },
                    "goal_title": {
                        "type": "string",
                        "description": "Goal title for 'create_goal' action_kind.",
                    },
                    "task_id": {
                        "type": "string",
                        "description": "Task ID (required for 'update' and 'cancel').",
                    },
                    "status": {
                        "type": "string",
                        "enum": ["active", "paused", "disabled"],
                        "description": "New status (for 'update').",
                    },
                    "max_runs": {
                        "type": "integer",
                        "description": "Maximum number of times the task should run. 1 for one-shot.",
                    },
                    "delivery_mode": {
                        "type": "string",
                        "enum": list(_VALID_DELIVERY_MODES),
                        "description": (
                            "Where to deliver results: 'outbox' (default, normal outbox routing), "
                            "'channel' (specific channel+topic), 'webhook' (HTTP POST to URL), "
                            "'silent' (log only, no notification)."
                        ),
                    },
                    "delivery_channel": {
                        "type": "string",
                        "description": "Channel type for 'channel' delivery (e.g. 'telegram', 'discord').",
                    },
                    "delivery_topic": {
                        "type": "string",
                        "description": "Topic/thread ID for 'channel' delivery.",
                    },
                    "delivery_target_id": {
                        "type": "string",
                        "description": "Target chat/user/channel ID for 'channel' delivery mode.",
                    },
                    "delivery_webhook_url": {
                        "type": "string",
                        "description": "Webhook URL for 'webhook' delivery mode.",
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

        try:
            async with pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT manage_schedule_tool($1::jsonb)",
                    json.dumps(arguments),
                )
            payload = json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(payload, dict) and "success" in payload:
                if payload.get("success"):
                    return ToolResult.success_result(
                        payload.get("output"),
                        display_output=payload.get("display_output"),
                    )
                error_type = payload.get("error_type") or ToolErrorType.EXECUTION_FAILED.value
                try:
                    typed_error = ToolErrorType(error_type)
                except ValueError:
                    typed_error = ToolErrorType.EXECUTION_FAILED
                return ToolResult.error_result(payload.get("error") or "Schedule action failed", typed_error)
            return ToolResult.error_result(
                "Schedule tool returned an unexpected payload",
                ToolErrorType.EXECUTION_FAILED,
            )
        except Exception as exc:
            logger.exception("Schedule tool failed")
            return ToolResult.error_result(
                f"Schedule tool failed: {exc}", ToolErrorType.EXECUTION_FAILED
            )


def create_cron_tools() -> list[ToolHandler]:
    """Create scheduled task management tools."""
    return [ManageScheduleHandler()]
