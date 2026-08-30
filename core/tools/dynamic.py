"""
Hexis Tools System - Self-Extending Dynamic Tools

Allows the agent to write Python code that defines new ToolHandler
subclasses, validate them, and register them at runtime. Dynamic
tools are persisted in the database and can be reloaded on startup.

Gated behind the config flag `tools.allow_dynamic` (default false).
"""

from __future__ import annotations

import json
import logging
import time
import uuid
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
from .self_extension import record_self_extension

if TYPE_CHECKING:
    import asyncpg
    from .registry import ToolRegistry

logger = logging.getLogger(__name__)

# Builtins allowed for dynamic tool code execution.
# More restrictive than REPL — no file I/O, no open, no __import__.
_SAFE_BUILTINS: dict[str, Any] = {
    # Types
    "str": str,
    "int": int,
    "float": float,
    "list": list,
    "dict": dict,
    "set": set,
    "tuple": tuple,
    "bool": bool,
    "bytes": bytes,
    "complex": complex,
    "type": type,
    "object": object,
    # Introspection
    "isinstance": isinstance,
    "issubclass": issubclass,
    "callable": callable,
    "hasattr": hasattr,
    "getattr": getattr,
    "setattr": setattr,
    "dir": dir,
    # Iteration
    "enumerate": enumerate,
    "zip": zip,
    "map": map,
    "filter": filter,
    "sorted": sorted,
    "reversed": reversed,
    "range": range,
    "iter": iter,
    "next": next,
    "slice": slice,
    # Math
    "min": min,
    "max": max,
    "sum": sum,
    "abs": abs,
    "round": round,
    "pow": pow,
    # String / conversion
    "chr": chr,
    "ord": ord,
    "hex": hex,
    "repr": repr,
    "len": len,
    "hash": hash,
    "id": id,
    "format": format,
    # Meta
    "print": print,
    "super": super,
    "property": property,
    "staticmethod": staticmethod,
    "classmethod": classmethod,
    # Exceptions
    "Exception": Exception,
    "ValueError": ValueError,
    "TypeError": TypeError,
    "KeyError": KeyError,
    "IndexError": IndexError,
    "AttributeError": AttributeError,
    "RuntimeError": RuntimeError,
    "NotImplementedError": NotImplementedError,
    # Required for class definitions
    "__build_class__": __build_class__,
    # Blocked — set to None to prevent usage
    "input": None,
    "eval": None,
    "exec": None,
    "compile": None,
    "globals": None,
    "locals": None,
    "open": None,
    "__import__": None,
}

# Core tool names that cannot be overridden by dynamic tools
_CORE_TOOL_NAMES = frozenset({
    "recall", "remember", "reflect", "forget", "connect_memories",
    "search_knowledge", "search_graph",
    "web_search", "web_fetch", "web_summarize",
    "read_file", "write_file", "edit_file", "glob", "grep", "list_directory",
    "shell", "safe_shell", "run_script",
    "execute_code",
    "browser",
    "google_calendar", "create_calendar_event",
    "send_email", "sendgrid_email",
    "discord_send", "slack_send", "telegram_send",
    "fast_ingest", "slow_ingest", "hybrid_ingest",
    "execute_workflow",
    "create_tool",  # Self-reference protection
})


def _execute_tool_code(code: str) -> dict[str, Any]:
    """
    Execute tool definition code in a restricted sandbox.

    Returns the namespace after execution.
    Raises RuntimeError on execution failure.
    """
    namespace: dict[str, Any] = {
        "__builtins__": _SAFE_BUILTINS,
        "__name__": "__dynamic_tool__",
        "__doc__": None,
    }

    # Inject base classes into the namespace so the code can subclass them
    namespace["ToolHandler"] = ToolHandler
    namespace["ToolSpec"] = ToolSpec
    namespace["ToolResult"] = ToolResult
    namespace["ToolCategory"] = ToolCategory
    namespace["ToolContext"] = ToolContext
    namespace["ToolExecutionContext"] = ToolExecutionContext
    namespace["ToolErrorType"] = ToolErrorType
    namespace["Any"] = Any

    try:
        exec(code, namespace, namespace)  # noqa: S102
    except Exception as e:
        raise RuntimeError(f"Failed to execute tool code: {e}") from e

    return namespace


def _find_handler_class(namespace: dict[str, Any]) -> type:
    """
    Find a ToolHandler subclass in the namespace.

    Returns the class, or raises ValueError if not found or invalid.
    """
    candidates = []
    for name, obj in namespace.items():
        if name.startswith("_"):
            continue
        if (
            isinstance(obj, type)
            and issubclass(obj, ToolHandler)
            and obj is not ToolHandler
        ):
            candidates.append(obj)

    if not candidates:
        raise ValueError(
            "No ToolHandler subclass found in the provided code. "
            "Define a class that inherits from ToolHandler with a spec property and execute method."
        )
    if len(candidates) > 1:
        raise ValueError(
            f"Multiple ToolHandler subclasses found: {[c.__name__ for c in candidates]}. "
            "Define exactly one ToolHandler subclass per tool."
        )

    return candidates[0]


def _validate_handler_class(cls: type) -> ToolSpec:
    """
    Validate that a handler class is properly defined.

    Returns the ToolSpec on success.
    Raises ValueError on validation failure.
    """
    # Check spec property
    try:
        instance = cls()
        spec = instance.spec
    except Exception as e:
        raise ValueError(f"Failed to instantiate handler or access spec: {e}") from e

    if not isinstance(spec, ToolSpec):
        raise ValueError(f"spec property must return a ToolSpec, got {type(spec).__name__}")

    # Check name conflicts
    if spec.name in _CORE_TOOL_NAMES:
        raise ValueError(
            f"Tool name '{spec.name}' conflicts with a core tool. "
            "Choose a different name."
        )

    # Check that execute method exists and is overridden
    if not hasattr(cls, "execute") or cls.execute is ToolHandler.execute:
        raise ValueError("Handler class must implement the execute() method")

    return spec


class CreateToolHandler(ToolHandler):
    """Create a new tool by writing Python code that defines a ToolHandler subclass."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="create_tool",
            description=(
                "Create a new tool by writing Python code that defines a ToolHandler subclass. "
                "The code must define exactly one class inheriting from ToolHandler with a spec "
                "property returning a ToolSpec and an async execute() method. "
                "The tool is validated, registered, and persisted for future sessions."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": (
                            "Python code defining a ToolHandler subclass. "
                            "Available in scope: ToolHandler, ToolSpec, ToolResult, "
                            "ToolCategory, ToolContext, ToolExecutionContext, ToolErrorType, Any."
                        ),
                    },
                    "description": {
                        "type": "string",
                        "description": "Human-readable description of what this tool does",
                    },
                },
                "required": ["code"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=5,
            is_read_only=False,
            requires_approval=True,
            supports_parallel=False,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        registry: ToolRegistry | None = context.registry
        if not registry:
            return ToolResult.error_result(
                "Dynamic tool creation requires a registry reference",
                ToolErrorType.MISSING_CONFIG,
            )

        # Check if dynamic tools are allowed
        allowed = await _is_dynamic_allowed(registry.pool)
        if not allowed:
            return ToolResult.error_result(
                "Dynamic tool creation is disabled. "
                "Set config key 'tools.allow_dynamic' to 'true' to enable.",
                ToolErrorType.DISABLED,
            )

        code = arguments.get("code", "")
        if not code.strip():
            return ToolResult.error_result(
                "Code is required",
                ToolErrorType.INVALID_PARAMS,
            )

        # Execute code in sandbox
        try:
            namespace = _execute_tool_code(code)
        except RuntimeError as e:
            return ToolResult.error_result(str(e))

        # Find and validate handler class
        try:
            handler_cls = _find_handler_class(namespace)
            tool_spec = _validate_handler_class(handler_cls)
        except ValueError as e:
            return ToolResult.error_result(str(e), ToolErrorType.INVALID_PARAMS)

        # Overwriting a previously created dynamic tool is allowed; note it
        # so the journal distinguishes growth from revision.
        updated = registry.get(tool_spec.name) is not None

        # Create instance and register
        try:
            handler = handler_cls()
        except Exception as e:
            return ToolResult.error_result(
                f"Failed to create handler instance: {e}",
            )

        registry.register(handler)

        # Persist to DB
        await _persist_dynamic_tool(
            registry.pool,
            tool_spec.name,
            code,
            arguments.get("description", tool_spec.description),
        )

        # Substrate-change visibility (#93): journal + web-inbox notice.
        verb = "updated" if updated else "created"
        await record_self_extension(
            registry.pool,
            summary=f"Agent {verb} dynamic tool '{tool_spec.name}'",
            notice=(
                f"I {'reworked' if updated else 'built'} a tool for myself: "
                f"'{tool_spec.name}' — {tool_spec.description}"
            ),
            detail={
                "tool_name": tool_spec.name,
                "description": tool_spec.description,
                "category": tool_spec.category.value,
                "energy_cost": tool_spec.energy_cost,
                "updated": updated,
            },
        )

        return ToolResult.success_result(
            {
                "tool_name": tool_spec.name,
                "description": tool_spec.description,
                "category": tool_spec.category.value,
                "energy_cost": tool_spec.energy_cost,
                "persisted": True,
            },
            display_output=f"Dynamic tool '{tool_spec.name}' created and registered.",
        )


async def _is_dynamic_allowed(pool: "asyncpg.Pool") -> bool:
    """Check if dynamic tool creation is enabled in config."""
    try:
        async with pool.acquire() as conn:
            val = await conn.fetchval(
                "SELECT value FROM config WHERE key = 'tools.allow_dynamic'"
            )
            return val == "true"
    except Exception:
        return False


async def _persist_dynamic_tool(
    pool: "asyncpg.Pool",
    name: str,
    code: str,
    description: str,
) -> None:
    """Save dynamic tool code to the config table."""
    key = f"dynamic_tool.{name}"
    payload = json.dumps({
        "code": code,
        "description": description,
        "created_at": time.time(),
    })
    try:
        async with pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO config (key, value)
                VALUES ($1, $2)
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
                """,
                key,
                payload,
            )
    except Exception:
        logger.debug("Failed to persist dynamic tool %s", name, exc_info=True)


async def load_dynamic_tools(pool: "asyncpg.Pool") -> list[ToolHandler]:
    """
    Load all persisted dynamic tools from the config table.

    Returns successfully loaded handlers; logs warnings for failures.
    """
    handlers: list[ToolHandler] = []

    # Check if dynamic tools are allowed
    allowed = await _is_dynamic_allowed(pool)
    if not allowed:
        return handlers

    try:
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT key, value FROM config WHERE key LIKE 'dynamic_tool.%'"
            )
    except Exception:
        logger.debug("Could not load dynamic tools from config", exc_info=True)
        return handlers

    for row in rows:
        tool_key = row["key"]
        try:
            payload = json.loads(row["value"])
            code = payload["code"]
            namespace = _execute_tool_code(code)
            handler_cls = _find_handler_class(namespace)
            _validate_handler_class(handler_cls)
            handler = handler_cls()
            handlers.append(handler)
            logger.info("Loaded dynamic tool: %s", handler.spec.name)
        except Exception:
            logger.warning("Failed to load dynamic tool %s", tool_key, exc_info=True)

    return handlers


def create_dynamic_tools() -> list[ToolHandler]:
    """Create the create_tool handler."""
    return [CreateToolHandler()]
