"""
Hexis Tools System — RecMem desk tools

The desk is mid-term working memory: source-document passages deliberately
loaded for multi-step reasoning (load_documents / load_document_chunks).
These tools let the agent see what is on the desk, scroll an item, pin what
stays actively needed, and clear the rest. Clearing ARCHIVES desk material —
the source documents always survive in the filing cabinet.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

from .base import (
    ToolCategory,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)


def _parse_uuid(value: Any, name: str) -> UUID:
    try:
        return UUID(str(value).strip())
    except (TypeError, ValueError):
        raise ValueError(f"{name} must be a uuid")


class ListDeskHandler(ToolHandler):
    """List what is currently on the RecMem desk."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="list_desk",
            description=(
                "List the items currently on the RecMem desk (source passages "
                "loaded via load_documents / load_document_chunks): handles, "
                "provenance, pin state, and access recency. Check this before "
                "re-loading a source you may already have."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20},
                    "offset": {"type": "integer", "minimum": 0, "default": 0},
                    "pinned_only": {"type": "boolean", "default": False},
                    "document_id": {
                        "type": "string",
                        "description": "Optional document UUID to list only that source's desk items.",
                    },
                },
                "required": [],
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        if not context.registry or not context.registry.pool:
            return ToolResult.error_result("Database unavailable", ToolErrorType.EXECUTION_FAILED)

        args = dict(arguments)
        document_id: UUID | None = None
        if str(args.get("document_id") or "").strip():
            try:
                document_id = _parse_uuid(args["document_id"], "document_id")
            except ValueError as exc:
                return ToolResult.error_result(str(exc), ToolErrorType.INVALID_PARAMS)
        try:
            limit = max(1, min(int(args.get("limit") or 20), 100))
            offset = max(0, int(args.get("offset") or 0))
        except (TypeError, ValueError):
            return ToolResult.error_result("limit and offset must be integers", ToolErrorType.INVALID_PARAMS)

        try:
            async with context.registry.pool.acquire() as conn:
                rows = await conn.fetch(
                    """
                    SELECT * FROM list_recmem_desk(
                        $1::int, $2::int, $3::uuid, $4::boolean, NULL, NULL, $5::boolean
                    )
                    """,
                    limit,
                    offset,
                    document_id,
                    bool(args.get("pinned_only")),
                    bool(args.get("exclude_sensitive") or context.is_group),
                )
        except Exception as e:
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)

        items = []
        pinned_count = 0
        total = 0
        for row in rows:
            total = row["total_count"]
            if row["pinned"]:
                pinned_count += 1
            locator = row["locator"]
            if isinstance(locator, str):
                locator = json.loads(locator)
            items.append({
                "desk_unit_id": str(row["desk_unit_id"]),
                "document_id": row["document_id"],
                "chunk_id": row["chunk_id"],
                "chunk_index": row["chunk_index"],
                "title": row["title"],
                "path": row["path"],
                "locator": locator,
                "reason": row["reason"],
                "pinned": row["pinned"],
                "loaded_at": row["loaded_at"].isoformat() if row["loaded_at"] else None,
                "access_count": row["access_count"],
                "last_accessed": row["last_accessed"].isoformat() if row["last_accessed"] else None,
                "char_count": row["char_count"],
                "snippet": row["snippet"],
            })
        return ToolResult.success_result(
            {"items": items, "count": len(items), "total": total, "offset": offset, "limit": limit},
            display_output=f"{total} item(s) on the desk ({pinned_count} pinned in this page)",
        )


class OpenDeskItemHandler(ToolHandler):
    """Open (and scroll) one desk item."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="open_desk_item",
            description=(
                "Read one desk item's content with offset windowing — the desk "
                "scroll surface. Long material never needs to be dumped whole: "
                "follow next_offset to continue, prev/next_desk_unit_id to walk "
                "the same document's other desk items."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "desk_unit_id": {
                        "type": "string",
                        "description": "Desk unit UUID from list_desk or load_documents/load_document_chunks.",
                    },
                    "offset": {"type": "integer", "minimum": 0, "default": 0},
                    "max_chars": {"type": "integer", "minimum": 200, "maximum": 20000, "default": 4000},
                },
                "required": ["desk_unit_id"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        if not context.registry or not context.registry.pool:
            return ToolResult.error_result("Database unavailable", ToolErrorType.EXECUTION_FAILED)

        args = dict(arguments)
        try:
            unit_id = _parse_uuid(args.get("desk_unit_id"), "desk_unit_id")
        except ValueError as exc:
            return ToolResult.error_result(str(exc), ToolErrorType.INVALID_PARAMS)
        try:
            offset = max(0, int(args.get("offset") or 0))
            max_chars = max(200, min(int(args.get("max_chars") or 4000), 20000))
        except (TypeError, ValueError):
            return ToolResult.error_result("offset and max_chars must be integers", ToolErrorType.INVALID_PARAMS)

        try:
            async with context.registry.pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT open_recmem_desk_item($1::uuid, $2::int, $3::int, $4::boolean)",
                    unit_id,
                    offset,
                    max_chars,
                    bool(args.get("exclude_sensitive") or context.is_group),
                )
        except Exception as e:
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)

        payload = json.loads(raw) if isinstance(raw, str) else raw
        if not isinstance(payload, dict):
            return ToolResult.error_result("open_recmem_desk_item returned an invalid payload", ToolErrorType.EXECUTION_FAILED)
        if payload.get("error"):
            return ToolResult.error_result(
                payload.get("hint") or "Desk item not found",
                ToolErrorType.EXECUTION_FAILED,
            )

        display = f"Opened desk item ({payload.get('returned_chars', 0)} chars)"
        if payload.get("truncated"):
            display += f" — continue with offset={payload.get('next_offset')}"
        return ToolResult.success_result(payload, display_output=display)


class PinDeskItemHandler(ToolHandler):
    """Pin a desk item so cleanup keeps it."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="pin_desk_item",
            description=(
                "Pin a desk item you are actively working with: pinned items "
                "survive desk cleanup (clear_desk and idle GC) until unpinned. "
                "Pins do not protect redacted sources."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "desk_unit_id": {"type": "string"},
                    "note": {
                        "type": "string",
                        "description": "Optional note on why this stays pinned.",
                    },
                },
                "required": ["desk_unit_id"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        return await _set_pin(arguments, context, pinned=True)


class UnpinDeskItemHandler(ToolHandler):
    """Unpin a desk item."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="unpin_desk_item",
            description="Unpin a desk item so normal desk cleanup applies to it again.",
            parameters={
                "type": "object",
                "properties": {
                    "desk_unit_id": {"type": "string"},
                },
                "required": ["desk_unit_id"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        return await _set_pin(arguments, context, pinned=False)


async def _set_pin(
    arguments: dict[str, Any],
    context: ToolExecutionContext,
    *,
    pinned: bool,
) -> ToolResult:
    if not context.registry or not context.registry.pool:
        return ToolResult.error_result("Database unavailable", ToolErrorType.EXECUTION_FAILED)
    try:
        unit_id = _parse_uuid(arguments.get("desk_unit_id"), "desk_unit_id")
    except ValueError as exc:
        return ToolResult.error_result(str(exc), ToolErrorType.INVALID_PARAMS)

    pinned_by = context.tool_context.value if context.tool_context else None
    try:
        async with context.registry.pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT pin_recmem_desk_item($1::uuid, $2::boolean, $3::text, $4::text)",
                unit_id,
                pinned,
                pinned_by,
                arguments.get("note"),
            )
    except Exception as e:
        return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)

    payload = json.loads(raw) if isinstance(raw, str) else raw
    if not isinstance(payload, dict):
        return ToolResult.error_result("pin_recmem_desk_item returned an invalid payload", ToolErrorType.EXECUTION_FAILED)
    if payload.get("error"):
        return ToolResult.error_result(
            payload.get("hint") or "Desk item not found",
            ToolErrorType.EXECUTION_FAILED,
        )
    verb = "Pinned" if pinned else "Unpinned"
    return ToolResult.success_result(payload, display_output=f"{verb} desk item")


class ClearDeskHandler(ToolHandler):
    """Archive desk items (sources stay in the filing cabinet)."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="clear_desk",
            description=(
                "Clear desk items when the work is done. Cleared items are "
                "ARCHIVED (never deleted) and the source documents remain in "
                "the filing cabinet, so anything can be re-loaded later. Pinned "
                "items are kept unless include_pinned=true. Scope with "
                "desk_unit_ids or document_id, or pass all=true to clear the "
                "whole (unpinned) desk."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "desk_unit_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Specific desk unit UUIDs to clear.",
                    },
                    "document_id": {
                        "type": "string",
                        "description": "Clear every desk item loaded from this document.",
                    },
                    "all": {
                        "type": "boolean",
                        "default": False,
                        "description": "Clear the entire (unpinned) desk.",
                    },
                    "include_pinned": {
                        "type": "boolean",
                        "default": False,
                        "description": "Also clear pinned items (explicit opt-in).",
                    },
                },
                "required": [],
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        if not context.registry or not context.registry.pool:
            return ToolResult.error_result("Database unavailable", ToolErrorType.EXECUTION_FAILED)

        args = dict(arguments)
        unit_ids: list[UUID] = []
        for item in args.get("desk_unit_ids") or []:
            if not str(item).strip():
                continue
            try:
                unit_ids.append(_parse_uuid(item, "desk_unit_ids"))
            except ValueError as exc:
                return ToolResult.error_result(str(exc), ToolErrorType.INVALID_PARAMS)
        document_id: UUID | None = None
        if str(args.get("document_id") or "").strip():
            try:
                document_id = _parse_uuid(args["document_id"], "document_id")
            except ValueError as exc:
                return ToolResult.error_result(str(exc), ToolErrorType.INVALID_PARAMS)

        if not unit_ids and document_id is None and not bool(args.get("all")):
            return ToolResult.error_result(
                "Provide desk_unit_ids or document_id, or pass all=true to clear the whole desk.",
                ToolErrorType.INVALID_PARAMS,
            )

        try:
            async with context.registry.pool.acquire() as conn:
                raw = await conn.fetchval(
                    """
                    SELECT clear_recmem_desk(
                        $1::uuid[], $2::uuid, NULL, NULL, $3::boolean, $4::boolean
                    )
                    """,
                    unit_ids or None,
                    document_id,
                    bool(args.get("all")),
                    bool(args.get("include_pinned")),
                )
        except Exception as e:
            return ToolResult.error_result(str(e), ToolErrorType.EXECUTION_FAILED)

        payload = json.loads(raw) if isinstance(raw, str) else raw
        if not isinstance(payload, dict):
            return ToolResult.error_result("clear_recmem_desk returned an invalid payload", ToolErrorType.EXECUTION_FAILED)
        if payload.get("error"):
            return ToolResult.error_result(
                payload.get("hint") or "Provide a selector or all=true.",
                ToolErrorType.INVALID_PARAMS,
            )

        cleared = int(payload.get("cleared") or 0)
        kept = int(payload.get("kept_pinned") or 0)
        display = f"Archived {cleared} desk item(s)"
        if kept:
            display += f"; {kept} pinned item(s) kept"
        display += ". Sources remain in the filing cabinet."
        return ToolResult.success_result(payload, display_output=display)


def create_desk_tools() -> list[ToolHandler]:
    """The RecMem desk toolset: list, scroll, pin, clear."""
    return [
        ListDeskHandler(),
        OpenDeskItemHandler(),
        PinDeskItemHandler(),
        UnpinDeskItemHandler(),
        ClearDeskHandler(),
    ]
