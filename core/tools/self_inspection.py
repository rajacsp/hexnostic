"""Read-only tools for inspecting Hexis source and its live PostgreSQL schema."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
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


_SOURCE_ROOT = Path(__file__).resolve().parents[2]
_SOURCE_SUFFIXES = {
    ".css",
    ".html",
    ".js",
    ".json",
    ".md",
    ".py",
    ".sh",
    ".sql",
    ".toml",
    ".ts",
    ".tsx",
    ".yaml",
    ".yml",
}
_IGNORED_PARTS = {
    ".git",
    ".next",
    ".venv",
    "__pycache__",
    "node_modules",
}


def _source_path(raw_path: str) -> Path | None:
    path = Path(raw_path or ".")
    if path.is_absolute():
        return None
    resolved = (_SOURCE_ROOT / path).resolve()
    try:
        resolved.relative_to(_SOURCE_ROOT)
    except ValueError:
        return None
    if any(part in _IGNORED_PARTS for part in resolved.parts):
        return None
    return resolved


def _is_source_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in _SOURCE_SUFFIXES and path.name != ".env"


def _iter_source_files(path: Path, pattern: str):
    if path.is_file():
        if _is_source_file(path):
            yield path
        return
    for current_root, directories, filenames in os.walk(path):
        directories[:] = sorted(
            directory
            for directory in directories
            if directory not in _IGNORED_PARTS and not directory.startswith(".")
        )
        current = Path(current_root)
        for filename in sorted(filenames):
            candidate = current / filename
            if not _is_source_file(candidate):
                continue
            relative = candidate.relative_to(path)
            if relative.match(pattern):
                yield candidate


def _json_safe(value: Any) -> Any:
    if isinstance(value, (bytes, bytearray, memoryview)):
        data = bytes(value)
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.hex()
    if isinstance(value, dict):
        return {str(key): _json_safe(val) for key, val in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    return value


def _record_rows(rows) -> list[dict[str, Any]]:
    return [_json_safe(dict(row)) for row in rows]


class InspectSourceHandler(ToolHandler):
    """Browse and search the checked-out Hexis source tree."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="inspect_source",
            description=(
                "Browse Hexis's own checked-out source tree. List source files, read a bounded line range, "
                "or search — the query matches both file paths and file contents, so a document is findable "
                "by name. Read-only, scoped to the Hexis repository."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["list", "read", "search"],
                        "description": "Inspection operation.",
                    },
                    "path": {
                        "type": "string",
                        "default": ".",
                        "description": "Repository-relative file or directory path.",
                    },
                    "query": {
                        "type": "string",
                        "description": "Literal text to find for search.",
                    },
                    "file_pattern": {
                        "type": "string",
                        "default": "*",
                        "description": "Glob used by list/search, such as '*.py' or '*.sql'.",
                    },
                    "offset": {
                        "type": "integer",
                        "default": 0,
                        "minimum": 0,
                        "description": "Zero-based first line for read.",
                    },
                    "limit": {
                        "type": "integer",
                        "default": 100,
                        "minimum": 1,
                        "maximum": 500,
                        "description": "Maximum lines, files, or matches returned.",
                    },
                },
                "required": ["action"],
            },
            category=ToolCategory.FILESYSTEM,
            energy_cost=1,
            is_read_only=True,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        action = str(arguments.get("action") or "")
        raw_path = str(arguments.get("path") or ".")
        path = _source_path(raw_path)
        if path is None:
            return ToolResult.error_result(
                "Path must stay within the Hexis source tree.",
                ToolErrorType.PATH_NOT_ALLOWED,
            )

        limit = min(500, max(1, int(arguments.get("limit") or 100)))
        if action == "read":
            result = self._read(path, raw_path, int(arguments.get("offset") or 0), limit)
            if result.success and isinstance(result.output, dict) and await self._retention_hint_enabled(context):
                result.output["retention"] = (
                    "This content is in-context only — nothing was ingested or "
                    "remembered. If it is identity-, relationship-, goal-, or "
                    "strategy-relevant, store the salient claims with remember or "
                    "slow_ingest; otherwise deliberately let it go."
                )
            return result
        if action == "list":
            return self._list(path, raw_path, str(arguments.get("file_pattern") or "*"), limit)
        if action == "search":
            return self._search(
                path,
                raw_path,
                str(arguments.get("query") or ""),
                str(arguments.get("file_pattern") or "*"),
                limit,
            )
        return ToolResult.error_result("Unknown source inspection action.", ToolErrorType.INVALID_PARAMS)

    async def _retention_hint_enabled(self, context: ToolExecutionContext) -> bool:
        """Config gate for the retention reminder; defaults on when unreadable —
        the hint is advisory and losing it silently would defeat its purpose."""
        registry = getattr(context, "registry", None)
        pool = getattr(registry, "pool", None)
        if pool is None:
            return True
        try:
            async with pool.acquire() as conn:
                return bool(await conn.fetchval(
                    "SELECT COALESCE(get_config_bool('inspection.retention_hint_enabled'), TRUE)"
                ))
        except Exception:
            return True

    def _read(self, path: Path, raw_path: str, offset: int, limit: int) -> ToolResult:
        if not _is_source_file(path):
            return ToolResult.error_result(
                f"Not a readable source file: {raw_path}",
                ToolErrorType.FILE_NOT_FOUND,
            )
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            return ToolResult.error_result(str(exc), ToolErrorType.PERMISSION_DENIED)
        selected = lines[offset : offset + limit]
        content = "\n".join(
            f"{line_number}: {line}"
            for line_number, line in enumerate(selected, start=offset + 1)
        )
        if len(content) > 50_000:
            content = content[:50_000] + "\n[truncated]"
        relative = str(path.relative_to(_SOURCE_ROOT))
        return ToolResult.success_result(
            {
                "path": relative,
                "offset": offset,
                "lines_read": len(selected),
                "total_lines": len(lines),
                "content": content,
            },
            f"Read {len(selected)} line(s) from {relative}",
        )

    def _list(self, path: Path, raw_path: str, pattern: str, limit: int) -> ToolResult:
        if not path.is_dir():
            return ToolResult.error_result(
                f"Not a source directory: {raw_path}",
                ToolErrorType.DIRECTORY_NOT_FOUND,
            )
        entries: list[dict[str, Any]] = []
        for candidate in _iter_source_files(path, pattern):
            entries.append(
                {
                    "path": str(candidate.relative_to(_SOURCE_ROOT)),
                    "type": "file",
                    "size": candidate.stat().st_size,
                }
            )
            if len(entries) >= limit:
                break
        return ToolResult.success_result(
            {"path": raw_path, "entries": entries, "count": len(entries)},
            f"Listed {len(entries)} source entries",
        )

    def _search(
        self, path: Path, raw_path: str, query: str, pattern: str, limit: int
    ) -> ToolResult:
        if not query.strip():
            return ToolResult.error_result("Search query is required.", ToolErrorType.INVALID_PARAMS)
        needle = query.casefold()
        matches: list[dict[str, Any]] = []
        files_searched = 0
        for candidate in _iter_source_files(path, pattern):
            files_searched += 1
            relative = str(candidate.relative_to(_SOURCE_ROOT))
            # Filenames are matches too (#49): "philosophy" must find
            # philosophy.md even when the document only says "philosophical".
            if needle in relative.casefold():
                matches.append({
                    "path": relative,
                    "line": 0,
                    "text": "[filename match]",
                })
                if len(matches) >= limit:
                    break
            try:
                lines = candidate.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line_number, line in enumerate(lines, start=1):
                if needle not in line.casefold():
                    continue
                matches.append(
                    {
                        "path": str(candidate.relative_to(_SOURCE_ROOT)),
                        "line": line_number,
                        "text": line[:500],
                    }
                )
                if len(matches) >= limit:
                    break
            if len(matches) >= limit:
                break
        return ToolResult.success_result(
            {
                "path": raw_path,
                "query": query,
                "matches": matches,
                "count": len(matches),
                "files_searched": files_searched,
                "truncated": len(matches) >= limit,
            },
            f"Found {len(matches)} source match(es)",
        )


class InspectDatabaseSchemaHandler(ToolHandler):
    """Inspect live PostgreSQL metadata without accepting arbitrary SQL."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="inspect_database_schema",
            description=(
                "Inspect Hexis's live PostgreSQL schema without running arbitrary SQL. Get an overview, "
                "search relations/columns/functions, describe a table or view, or read a stored function definition."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["overview", "search", "describe_relation", "get_function"],
                    },
                    "schema": {"type": "string", "default": "public"},
                    "query": {"type": "string", "description": "Name fragment for search."},
                    "relation": {"type": "string", "description": "Table, view, or materialized view name."},
                    "function": {"type": "string", "description": "Stored function name."},
                    "limit": {"type": "integer", "default": 50, "minimum": 1, "maximum": 100},
                },
                "required": ["action"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Database pool not available.", ToolErrorType.MISSING_CONFIG
            )
        action = str(arguments.get("action") or "")
        schema = str(arguments.get("schema") or "public")
        limit = min(100, max(1, int(arguments.get("limit") or 50)))
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", schema):
            return ToolResult.error_result("Invalid schema name.", ToolErrorType.INVALID_PARAMS)
        try:
            async with pool.acquire() as conn:
                if action == "overview":
                    return await self._overview(conn, schema, limit)
                if action == "search":
                    return await self._search(conn, schema, str(arguments.get("query") or ""), limit)
                if action == "describe_relation":
                    return await self._describe_relation(
                        conn, schema, str(arguments.get("relation") or "")
                    )
                if action == "get_function":
                    return await self._get_function(
                        conn, schema, str(arguments.get("function") or ""), limit
                    )
        except Exception as exc:
            return ToolResult.error_result(
                f"Schema inspection failed: {exc}", ToolErrorType.EXECUTION_FAILED
            )
        return ToolResult.error_result("Unknown schema inspection action.", ToolErrorType.INVALID_PARAMS)

    async def _overview(self, conn, schema: str, limit: int) -> ToolResult:
        relations = await conn.fetch(
            """
            SELECT c.relname AS name,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
                        WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view'
                        WHEN 'S' THEN 'sequence' ELSE c.relkind::text END AS kind
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
            ORDER BY kind, name
            LIMIT $2
            """,
            schema,
            limit,
        )
        function_count = await conn.fetchval(
            """
            SELECT count(*)
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1
            """,
            schema,
        )
        return ToolResult.success_result(
            {
                "schema": schema,
                "relations": _record_rows(relations),
                "relation_count_returned": len(relations),
                "function_count": int(function_count or 0),
            },
            f"Inspected schema {schema}",
        )

    async def _search(self, conn, schema: str, query: str, limit: int) -> ToolResult:
        if not query.strip():
            return ToolResult.error_result("Search query is required.", ToolErrorType.INVALID_PARAMS)
        pattern = f"%{query}%"
        rows = await conn.fetch(
            """
            WITH objects AS (
                SELECT 'relation'::text AS object_type, c.relname AS object_name,
                       NULL::text AS parent_name,
                       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
                            WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view'
                            ELSE c.relkind::text END AS detail
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm')
                  AND c.relname ILIKE $2
                UNION ALL
                SELECT 'column', a.attname, c.relname, pg_catalog.format_type(a.atttypid, a.atttypmod)
                FROM pg_catalog.pg_attribute a
                JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = $1 AND a.attnum > 0 AND NOT a.attisdropped
                  AND (a.attname ILIKE $2 OR c.relname ILIKE $2)
                UNION ALL
                SELECT 'function', p.proname, NULL,
                       pg_catalog.pg_get_function_identity_arguments(p.oid)
                FROM pg_catalog.pg_proc p
                JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = $1 AND p.proname ILIKE $2
            )
            SELECT * FROM objects
            ORDER BY object_type, object_name, parent_name
            LIMIT $3
            """,
            schema,
            pattern,
            limit,
        )
        return ToolResult.success_result(
            {"schema": schema, "query": query, "matches": _record_rows(rows)},
            f"Found {len(rows)} schema match(es)",
        )

    async def _describe_relation(self, conn, schema: str, relation: str) -> ToolResult:
        if not relation:
            return ToolResult.error_result("Relation name is required.", ToolErrorType.INVALID_PARAMS)
        relation_row = await conn.fetchrow(
            """
            SELECT c.oid, c.relkind,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
                        WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view'
                        ELSE c.relkind::text END AS kind
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
              AND c.relkind IN ('r', 'p', 'v', 'm')
            """,
            schema,
            relation,
        )
        if relation_row is None:
            return ToolResult.error_result(
                f"Relation not found: {schema}.{relation}", ToolErrorType.FILE_NOT_FOUND
            )
        oid = relation_row["oid"]
        columns = await conn.fetch(
            """
            SELECT a.attnum AS position, a.attname AS name,
                   pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
                   a.attnotnull AS not_null,
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid) AS default_expression
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d
              ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            oid,
        )
        constraints = await conn.fetch(
            """
            SELECT conname AS name, contype AS type,
                   pg_catalog.pg_get_constraintdef(oid, true) AS definition
            FROM pg_catalog.pg_constraint
            WHERE conrelid = $1
            ORDER BY conname
            """,
            oid,
        )
        indexes = await conn.fetch(
            """
            SELECT indexname AS name, indexdef AS definition
            FROM pg_catalog.pg_indexes
            WHERE schemaname = $1 AND tablename = $2
            ORDER BY indexname
            """,
            schema,
            relation,
        )
        view_definition = None
        if relation_row["relkind"] in {"v", "m"}:
            view_definition = await conn.fetchval(
                "SELECT pg_catalog.pg_get_viewdef($1::oid, true)", oid
            )
        return ToolResult.success_result(
            {
                "schema": schema,
                "relation": relation,
                "kind": relation_row["kind"],
                "columns": _record_rows(columns),
                "constraints": _record_rows(constraints),
                "indexes": _record_rows(indexes),
                "view_definition": view_definition,
            },
            f"Described {schema}.{relation}",
        )

    async def _get_function(self, conn, schema: str, function: str, limit: int) -> ToolResult:
        if not function:
            return ToolResult.error_result("Function name is required.", ToolErrorType.INVALID_PARAMS)
        rows = await conn.fetch(
            """
            SELECT p.proname AS name,
                   pg_catalog.pg_get_function_identity_arguments(p.oid) AS arguments,
                   pg_catalog.pg_get_function_result(p.oid) AS result_type,
                   l.lanname AS language,
                   left(pg_catalog.pg_get_functiondef(p.oid), 50000) AS definition
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = $1 AND p.proname = $2
            ORDER BY arguments
            LIMIT $3
            """,
            schema,
            function,
            min(limit, 10),
        )
        if not rows:
            return ToolResult.error_result(
                f"Function not found: {schema}.{function}", ToolErrorType.FILE_NOT_FOUND
            )
        return ToolResult.success_result(
            {"schema": schema, "function": function, "overloads": _record_rows(rows)},
            f"Read {len(rows)} definition(s) for {schema}.{function}",
        )


class InspectConfigHandler(ToolHandler):
    """Read the agent's own (allowlisted, redacted) configuration."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="inspect_config",
            description=(
                "Read your own configuration — the settings that govern your "
                "cognition: memory formation (extraction.*), belief revision "
                "(belief.*), heartbeat cadence (heartbeat.*), retention, guardrails, "
                "and more. Only allowlisted, non-secret keys are visible; values "
                "with secret-like names are redacted. Use this to understand why "
                "your own behavior is what it is."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "prefix": {
                        "type": "string",
                        "description": "Optional key prefix filter, e.g. 'extraction.' or 'belief.'.",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Database pool not available.", ToolErrorType.MISSING_CONFIG
            )
        prefix = str(arguments.get("prefix") or "") or None
        async with pool.acquire() as conn:
            raw = await conn.fetchval("SELECT inspect_agent_config($1::text)", prefix)
        settings = json.loads(raw) if isinstance(raw, str) else (raw or {})
        return ToolResult.success_result(
            {"settings": settings, "count": len(settings)},
            f"{len(settings)} setting(s)" + (f" under '{prefix}'" if prefix else ""),
        )


class ReviewRecentActionsHandler(ToolHandler):
    """The agent's verbatim action log."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="review_recent_actions",
            description=(
                "Your verbatim action log: the tool calls you actually made "
                "(successes and failures, with energy and timing), straight from "
                "the audit trail. Use it to check what you actually did rather "
                "than what you remember doing — memory is selective; this is not."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "hours": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 168,
                        "default": 24,
                        "description": "Look-back window in hours.",
                    },
                    "limit": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 100,
                        "default": 30,
                        "description": "Maximum actions to return (newest first).",
                    },
                    "context": {
                        "type": "string",
                        "enum": ["chat", "heartbeat", "mcp"],
                        "description": "Optional filter by execution context.",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Database pool not available.", ToolErrorType.MISSING_CONFIG
            )
        async with pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT get_recent_actions($1::int, $2::int, $3::text)",
                int(arguments.get("hours") or 24),
                int(arguments.get("limit") or 30),
                str(arguments.get("context") or "") or None,
            )
        report = json.loads(raw) if isinstance(raw, str) else (raw or {})
        summary = report.get("summary") or {}
        return ToolResult.success_result(
            report,
            format(
                f"{summary.get('total', 0)} action(s) in the last "
                f"{summary.get('window_hours', '?')}h, {summary.get('failures', 0)} failed"
            ),
        )


class ReviewRecentChangesHandler(ToolHandler):
    """The substrate-change journal (#93) — what was changed about the agent."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="review_recent_changes",
            description=(
                "The change journal for your own substrate: migrations to your "
                "cognition, rebuilds of your running code, edits to the prompts "
                "that instruct you, and operator config decisions. Use it to "
                "recognize when something about you changed — continuity of "
                "self survives being maintained by seeing the seams."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "days": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 90,
                        "default": 7,
                        "description": "Look-back window in days.",
                    },
                    "limit": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 100,
                        "default": 20,
                        "description": "Maximum entries to return (newest first).",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Database pool not available.", ToolErrorType.MISSING_CONFIG
            )
        days = int(arguments.get("days") or 7)
        async with pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT recent_changes(CURRENT_TIMESTAMP - make_interval(days => $1), $2)",
                days,
                int(arguments.get("limit") or 20),
            )
        changes = json.loads(raw) if isinstance(raw, str) else (raw or [])
        return ToolResult.success_result(
            {"changes": changes, "count": len(changes), "window_days": days},
            f"{len(changes)} substrate change(s) in the last {days} day(s)",
        )


def create_self_inspection_tools() -> list[ToolHandler]:
    return [
        InspectSourceHandler(),
        InspectDatabaseSchemaHandler(),
        InspectConfigHandler(),
        ReviewRecentActionsHandler(),
        ReviewRecentChangesHandler(),
    ]
