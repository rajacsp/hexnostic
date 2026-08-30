"""
Hexis Tools System — Ingested-document approval tools

Ingested documents are the USER's data (docs/memory_retention_design.md). Hexis
never fades them automatically; instead it asks the user via the outbox and the
user approves/keeps here. These handlers are thin drivers over the DB-native
execute_document_tool; the matching/deletion logic all lives in the database.
"""

from __future__ import annotations

import json
from typing import Any

from .base import (
    ToolCategory,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)


async def _run_document_tool(
    tool_name: str, arguments: dict[str, Any], context: ToolExecutionContext
) -> ToolResult:
    """Dispatch to the DB-native execute_document_tool, surfacing real errors."""
    pool = context.registry.pool if context.registry else None
    if not pool:
        return ToolResult.error_result("No database pool available", ToolErrorType.EXECUTION_FAILED)
    try:
        async with pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT execute_document_tool($1::text, $2::jsonb)",
                tool_name,
                json.dumps(arguments),
            )
        payload = json.loads(raw) if isinstance(raw, str) else raw
        if isinstance(payload, dict) and payload.get("success"):
            return ToolResult.success_result(payload.get("output"), payload.get("display_output"))
        try:
            error_type = ToolErrorType((payload or {}).get("error_type") or ToolErrorType.EXECUTION_FAILED.value)
        except (ValueError, AttributeError):
            error_type = ToolErrorType.EXECUTION_FAILED
        return ToolResult.error_result((payload or {}).get("error") or "Document tool failed", error_type)
    except Exception as e:
        return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)


class ListDocumentFadeRequestsHandler(ToolHandler):
    """List the ingested documents currently awaiting the user's approval to fade."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="list_document_fade_requests",
            description=(
                "List ingested documents you've asked the user about because they seem stale — "
                "the ones awaiting their approval to let fade. Use this to see what's pending "
                "before acting on a reply."
            ),
            parameters={"type": "object", "properties": {}},
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return await _run_document_tool("list_document_fade_requests", arguments, context)


class ResolveDocumentFadeHandler(ToolHandler):
    """Record the user's approve/keep decision on a stale ingested document."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="resolve_document_fade",
            description=(
                "Record the user's decision about a stale ingested document you asked them about. "
                "Only call this once the USER has clearly told you what to do — their data is theirs. "
                "'approve' permanently deletes every memory of that document; 'keep' retains it. "
                "Identify the document by the name/title the user used."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "document": {"type": "string", "description": "The document title/name (or its content hash)."},
                    "decision": {"type": "string", "enum": ["approve", "keep"],
                                 "description": "'approve' to let it fade (delete), 'keep' to retain it."},
                },
                "required": ["document", "decision"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=False,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return await _run_document_tool("resolve_document_fade", arguments, context)


def create_document_tools() -> list[ToolHandler]:
    """The ingested-document approval toolset (the user keeps control of their data)."""
    return [
        ListDocumentFadeRequestsHandler(),
        ResolveDocumentFadeHandler(),
    ]
