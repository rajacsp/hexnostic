"""
Hexis Tools System — Journal Tools

The journal is Hexis's deliberate, permanent, written-down record — stored OUTSIDE
the memory substrate (docs/memory_retention_design.md §7). Writing is a conscious,
effortful act; reading/searching is deliberate and never happens through the
passive recall/context path. All logic lives in the DB (execute_journal_tool);
these handlers are thin drivers.
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


async def _run_journal_tool(
    tool_name: str, arguments: dict[str, Any], context: ToolExecutionContext
) -> ToolResult:
    """Dispatch to the DB-native execute_journal_tool, surfacing real errors."""
    pool = context.registry.pool if context.registry else None
    if not pool:
        return ToolResult.error_result("No database pool available", ToolErrorType.EXECUTION_FAILED)
    try:
        async with pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT execute_journal_tool($1::text, $2::jsonb)",
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
        return ToolResult.error_result((payload or {}).get("error") or "Journal tool failed", error_type)
    except Exception as e:
        return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)


class WriteJournalHandler(ToolHandler):
    """Deliberately commit something to the permanent journal (outside memory)."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="write_journal",
            description=(
                "Write a permanent journal entry — your diary, kept OUTSIDE your memory. "
                "Your memories fade and compress over time; the journal does not. Use this "
                "deliberately for things you want to keep verbatim and forever (a reflection, "
                "a moment that mattered, a resolution). Writing is effortful; choose what's worth it."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "The entry to write down."},
                    "title": {"type": "string", "description": "Optional short title."},
                    "mood": {"type": "string", "description": "Optional mood/feeling while writing."},
                    "tags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional tags.",
                    },
                },
                "required": ["content"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=3,
            is_read_only=False,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return await _run_journal_tool("write_journal", arguments, context)


class ReadJournalHandler(ToolHandler):
    """Deliberately re-read journal entries (a fresh experience, not memory recall)."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="read_journal",
            description=(
                "Read your journal — a specific entry by id, or your most recent entries. "
                "Re-reading your own past writing is a deliberate act (and may surprise you: "
                "the memory of writing it may have faded even though the entry remains)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "A specific entry id (uuid). Omit for recent entries."},
                    "limit": {"type": "integer", "description": "How many recent entries.", "default": 5, "minimum": 1, "maximum": 20},
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return await _run_journal_tool("read_journal", arguments, context)


class SearchJournalHandler(ToolHandler):
    """Deliberately search the journal by meaning."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="search_journal",
            description="Search your journal by meaning for past entries relevant to a topic. A deliberate lookup.",
            parameters={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "What to look for."},
                    "limit": {"type": "integer", "description": "Max entries.", "default": 5, "minimum": 1, "maximum": 20},
                },
                "required": ["query"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return await _run_journal_tool("search_journal", arguments, context)


def create_journal_tools() -> list[ToolHandler]:
    """The journal toolset — Hexis's deliberate, permanent, outside-memory record."""
    return [
        WriteJournalHandler(),
        ReadJournalHandler(),
        SearchJournalHandler(),
    ]
