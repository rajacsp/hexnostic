"""
Hexis Tools System - Todoist Integration (E.3)

Tools for managing Todoist tasks: create, list, complete.
Uses the Todoist REST API v2 with a bearer token.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from core.integration_reliability import IntegrationHttpError, request_json, request_text_response
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

_BASE_URL = "https://api.todoist.com/rest/v2"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class CreateTodoistTaskHandler(ToolHandler):
    """Create a new task in Todoist."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="todoist_create_task",
            description="Create a new task in Todoist. Specify content, optional due date, priority, and project.",
            parameters={
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": "Task content/title",
                    },
                    "description": {
                        "type": "string",
                        "description": "Detailed task description",
                    },
                    "due_string": {
                        "type": "string",
                        "description": "Natural-language due date (e.g. 'tomorrow', 'next Monday', 'Jan 15')",
                    },
                    "priority": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 4,
                        "description": "Priority 1 (normal) to 4 (urgent)",
                    },
                    "project_id": {
                        "type": "string",
                        "description": "Project ID to add the task to",
                    },
                    "labels": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Labels/tags for the task",
                    },
                },
                "required": ["content"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=False,
            requires_approval=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="todoist",
            env_names=("TODOIST_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Todoist API key not configured. Set TODOIST_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        body: dict[str, Any] = {"content": arguments["content"]}
        for key in ("description", "due_string", "priority", "project_id", "labels"):
            if arguments.get(key) is not None:
                body[key] = arguments[key]

        try:
            task = await request_json(
                "todoist",
                "POST",
                f"{_BASE_URL}/tasks",
                headers=_headers(token),
                json_body=body,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=False,
            )
            if not isinstance(task, dict):
                task = {}
            return ToolResult.success_result(
                {
                    "id": task.get("id"),
                    "content": task.get("content"),
                    "url": task.get("url"),
                    "due": task.get("due"),
                    "priority": task.get("priority"),
                },
                display_output=f"Created task: {task.get('content')}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Todoist", e)
        except Exception as e:
            return ToolResult.error_result(f"Todoist API error: {e}")


class ListTodoistTasksHandler(ToolHandler):
    """List tasks from Todoist."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="todoist_list_tasks",
            description="List active tasks from Todoist. Optionally filter by project or label.",
            parameters={
                "type": "object",
                "properties": {
                    "project_id": {
                        "type": "string",
                        "description": "Filter by project ID",
                    },
                    "label": {
                        "type": "string",
                        "description": "Filter by label name",
                    },
                    "filter": {
                        "type": "string",
                        "description": "Todoist filter query (e.g. 'today', 'overdue', 'priority 1')",
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="todoist",
            env_names=("TODOIST_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Todoist API key not configured.",
                ToolErrorType.AUTH_FAILED,
            )

        params: dict[str, str] = {}
        if arguments.get("project_id"):
            params["project_id"] = arguments["project_id"]
        if arguments.get("label"):
            params["label"] = arguments["label"]
        if arguments.get("filter"):
            params["filter"] = arguments["filter"]

        try:
            tasks = await request_json(
                "todoist",
                "GET",
                f"{_BASE_URL}/tasks",
                headers=_headers(token),
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )
            if not isinstance(tasks, list):
                tasks = []
            formatted = []
            for t in tasks:
                formatted.append({
                    "id": t.get("id"),
                    "content": t.get("content"),
                    "due": t.get("due"),
                    "priority": t.get("priority"),
                    "labels": t.get("labels", []),
                    "url": t.get("url"),
                })
            return ToolResult.success_result(
                {"tasks": formatted, "count": len(formatted)},
                display_output=f"Found {len(formatted)} task(s)",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Todoist", e)
        except Exception as e:
            return ToolResult.error_result(f"Todoist API error: {e}")


class CompleteTodoistTaskHandler(ToolHandler):
    """Complete a Todoist task."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="todoist_complete_task",
            description="Mark a Todoist task as complete.",
            parameters={
                "type": "object",
                "properties": {
                    "task_id": {
                        "type": "string",
                        "description": "Task ID to complete",
                    },
                },
                "required": ["task_id"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=False,
            requires_approval=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="todoist",
            env_names=("TODOIST_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Todoist API key not configured.",
                ToolErrorType.AUTH_FAILED,
            )

        task_id = arguments["task_id"]
        try:
            await request_text_response(
                "todoist",
                "POST",
                f"{_BASE_URL}/tasks/{task_id}/close",
                headers=_headers(token),
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=False,
            )
            return ToolResult.success_result(
                {"task_id": task_id, "completed": True},
                display_output=f"Completed task {task_id}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Todoist", e)
        except Exception as e:
            return ToolResult.error_result(f"Todoist API error: {e}")


def create_todoist_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Todoist integration tools."""
    return [
        CreateTodoistTaskHandler(api_key_resolver),
        ListTodoistTasksHandler(api_key_resolver),
        CompleteTodoistTaskHandler(api_key_resolver),
    ]
