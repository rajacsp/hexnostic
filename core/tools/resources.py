"""Resource request tools (#84).

A structured channel for the agent to ask the operator for resources — more
energy, a config change, a backup, or anything else — with a rationale. The
DB owns the request lifecycle (db/74): filing queues an outbox notification
to the operator; decisions (hexis requests grant/deny) apply their effects
and surface in the agent's context at the next heartbeat.
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


class RequestResourcesHandler(ToolHandler):
    """File a resource request for the operator to decide."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="request_resources",
            description=(
                "Ask the operator for a resource: an energy boost, a config "
                "change, a fresh backup of your memory, or anything else. "
                "State what you need and why — the rationale is what the "
                "operator reads. Filing is an ask, never an action: the "
                "operator decides, and the decision appears in your context "
                "at a later heartbeat."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "kind": {
                        "type": "string",
                        "enum": ["energy_boost", "config_change", "backup", "other"],
                        "description": "What category of resource you are asking for.",
                    },
                    "rationale": {
                        "type": "string",
                        "description": (
                            "Why you need it — concrete and honest. This is "
                            "what the operator decides on."
                        ),
                    },
                    "target_key": {
                        "type": "string",
                        "description": (
                            "For config_change: the config key you want changed "
                            "(inspect_config shows current values)."
                        ),
                    },
                    "requested_value": {
                        "description": (
                            "The value you are asking for: a number of energy "
                            "points for energy_boost, or the desired config "
                            "value for config_change."
                        ),
                    },
                    "duration": {
                        "type": "string",
                        "description": (
                            "Optionally, how long you need it (e.g. 'one week', "
                            "'until the migration completes')."
                        ),
                    },
                },
                "required": ["kind", "rationale"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=False,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        if not str(arguments.get("rationale") or "").strip():
            errors.append("rationale is required: say what you need and why")
        if arguments.get("kind") == "config_change" and not str(
            arguments.get("target_key") or ""
        ).strip():
            errors.append("config_change requests require target_key")
        return errors

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Database pool not available.", ToolErrorType.MISSING_CONFIG
            )
        requested_value = arguments.get("requested_value")
        try:
            async with pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT file_resource_request($1, $2, $3, $4::jsonb, $5)",
                    str(arguments["kind"]),
                    str(arguments["rationale"]),
                    arguments.get("target_key"),
                    json.dumps(requested_value) if requested_value is not None else None,
                    arguments.get("duration"),
                )
            result = json.loads(raw) if isinstance(raw, str) else (raw or {})
            return ToolResult.success_result(
                result,
                display_output=(
                    f"Filed {arguments['kind']} request "
                    f"{str(result.get('request_id', ''))[:8]}. "
                    "The operator decides; the decision will appear in your context."
                ),
            )
        except Exception as e:
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)


def create_resource_tools() -> list[ToolHandler]:
    return [RequestResourcesHandler()]
