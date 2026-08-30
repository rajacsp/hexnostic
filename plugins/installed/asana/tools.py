"""
Hexis Tools System - Asana Integration (E.4)

Tools for managing Asana tasks and projects.
Uses the Asana REST API with a personal access token.
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

_BASE_URL = "https://app.asana.com/api/1.0"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class CreateAsanaTaskHandler(ToolHandler):
    """Create a new task in Asana."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="asana_create_task",
            description="Create a new task in Asana. Specify name, optional project, assignee, due date, and notes.",
            parameters={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Task name",
                    },
                    "notes": {
                        "type": "string",
                        "description": "Task description/notes",
                    },
                    "project_gid": {
                        "type": "string",
                        "description": "Project GID to add the task to",
                    },
                    "assignee": {
                        "type": "string",
                        "description": "Assignee (email or 'me')",
                    },
                    "due_on": {
                        "type": "string",
                        "description": "Due date in YYYY-MM-DD format",
                    },
                    "workspace_gid": {
                        "type": "string",
                        "description": "Workspace GID (required if no project specified)",
                    },
                },
                "required": ["name"],
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
            config_key="asana",
            env_names=("ASANA_ACCESS_TOKEN", "ASANA_API_KEY"),
        )
        if not token:
            return ToolResult.error_result(
                "Asana API key not configured. Set ASANA_ACCESS_TOKEN.",
                ToolErrorType.AUTH_FAILED,
            )

        data: dict[str, Any] = {"name": arguments["name"]}
        for key in ("notes", "assignee", "due_on"):
            if arguments.get(key):
                data[key] = arguments[key]
        if arguments.get("project_gid"):
            data["projects"] = [arguments["project_gid"]]
        if arguments.get("workspace_gid"):
            data["workspace"] = arguments["workspace_gid"]

        try:
            payload = await request_json(
                "asana",
                "POST",
                f"{_BASE_URL}/tasks",
                headers=_headers(token),
                json_body={"data": data},
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=False,
            )
            result = payload.get("data", {}) if isinstance(payload, dict) else {}
            return ToolResult.success_result(
                {
                    "gid": result.get("gid"),
                    "name": result.get("name"),
                    "permalink_url": result.get("permalink_url"),
                    "due_on": result.get("due_on"),
                },
                display_output=f"Created Asana task: {result.get('name')}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Asana", e)
        except Exception as e:
            return ToolResult.error_result(f"Asana API error: {e}")


class ListAsanaProjectsHandler(ToolHandler):
    """List Asana projects in a workspace."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="asana_list_projects",
            description="List projects from Asana workspace.",
            parameters={
                "type": "object",
                "properties": {
                    "workspace_gid": {
                        "type": "string",
                        "description": "Workspace GID (uses default if not specified)",
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
            config_key="asana",
            env_names=("ASANA_ACCESS_TOKEN", "ASANA_API_KEY"),
        )
        if not token:
            return ToolResult.error_result(
                "Asana API key not configured.",
                ToolErrorType.AUTH_FAILED,
            )

        params: dict[str, str] = {"opt_fields": "name,color,due_on,permalink_url"}
        if arguments.get("workspace_gid"):
            params["workspace"] = arguments["workspace_gid"]

        try:
            payload = await request_json(
                "asana",
                "GET",
                f"{_BASE_URL}/projects",
                headers=_headers(token),
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )
            projects = payload.get("data", []) if isinstance(payload, dict) else []
            formatted = []
            for p in projects:
                formatted.append({
                    "gid": p.get("gid"),
                    "name": p.get("name"),
                    "permalink_url": p.get("permalink_url"),
                })
            return ToolResult.success_result(
                {"projects": formatted, "count": len(formatted)},
                display_output=f"Found {len(formatted)} project(s)",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Asana", e)
        except Exception as e:
            return ToolResult.error_result(f"Asana API error: {e}")


def create_asana_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Asana integration tools."""
    return [
        CreateAsanaTaskHandler(api_key_resolver),
        ListAsanaProjectsHandler(api_key_resolver),
    ]
