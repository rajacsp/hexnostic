"""
Hexis Tools System - Hook System

Lifecycle hooks for intercepting and reacting to tool execution events.
Inspired by OpenClaw's plugin hook system, adapted for Hexis's DB-authority model.

Hooks allow plugins and core code to:
- Intercept tool calls (modify params, block execution)
- React to tool results (logging, memory formation)
- Inject context into heartbeat/chat system prompts
- React to policy denials
"""

from __future__ import annotations

import json
import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Awaitable, TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)


class HookEvent(str, Enum):
    """Lifecycle events that hooks can subscribe to."""

    BEFORE_TOOL_CALL = "before_tool_call"
    AFTER_TOOL_CALL = "after_tool_call"
    BEFORE_HEARTBEAT = "before_heartbeat"
    AFTER_HEARTBEAT = "after_heartbeat"
    BEFORE_CHAT = "before_chat"
    AFTER_CHAT = "after_chat"
    MEMORY_CREATED = "memory_created"
    TOOL_DENIED = "tool_denied"
    CHANNEL_MESSAGE_RECEIVED = "channel_message_received"


@dataclass
class HookContext:
    """Context passed to hook handlers."""

    event: HookEvent
    tool_name: str | None = None
    arguments: dict[str, Any] | None = None
    result: Any | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class HookOutcome:
    """What a hook handler can return to affect execution."""

    block: bool = False
    block_reason: str | None = None
    mutated_arguments: dict[str, Any] | None = None
    prepend_context: str | None = None
    append_context: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def passthrough(cls) -> "HookOutcome":
        """No-op outcome that doesn't affect execution."""
        return cls()

    @classmethod
    def blocked(cls, reason: str) -> "HookOutcome":
        """Block the tool call."""
        return cls(block=True, block_reason=reason)

    @classmethod
    def with_args(cls, arguments: dict[str, Any]) -> "HookOutcome":
        """Modify the tool call arguments."""
        return cls(mutated_arguments=arguments)


class HookHandler(ABC):
    """Abstract base class for hook handlers."""

    @abstractmethod
    async def handle(self, context: HookContext) -> HookOutcome | None:
        """
        Handle a hook event.

        Returns:
            HookOutcome to affect execution, or None for no-op.
        """
        ...

    @property
    def priority(self) -> int:
        """Lower priority runs first. Default is 100."""
        return 100


class FunctionHookHandler(HookHandler):
    """Hook handler wrapping an async function."""

    def __init__(
        self,
        fn: Callable[[HookContext], Awaitable[HookOutcome | None]],
        *,
        priority: int = 100,
        name: str | None = None,
    ):
        self._fn = fn
        self._priority = priority
        self._name = name or fn.__name__

    async def handle(self, context: HookContext) -> HookOutcome | None:
        return await self._fn(context)

    @property
    def priority(self) -> int:
        return self._priority

    def __repr__(self) -> str:
        return f"FunctionHookHandler({self._name!r})"


@dataclass
class _HookEntry:
    """Internal: a registered hook handler for an event."""
    handler: HookHandler
    source: str  # "core", plugin ID, etc.


class HookRegistry:
    """Central registry for lifecycle hooks."""

    def __init__(self) -> None:
        self._hooks: dict[HookEvent, list[_HookEntry]] = {
            event: [] for event in HookEvent
        }

    def register(
        self,
        event: HookEvent,
        handler: HookHandler,
        *,
        source: str = "core",
    ) -> None:
        """Register a hook handler for an event."""
        entry = _HookEntry(handler=handler, source=source)
        self._hooks[event].append(entry)
        # Keep sorted by priority (lower first)
        self._hooks[event].sort(key=lambda e: e.handler.priority)
        logger.debug("Hook registered: event=%s source=%s handler=%r", event.value, source, handler)

    def register_function(
        self,
        event: HookEvent,
        fn: Callable[[HookContext], Awaitable[HookOutcome | None]],
        *,
        source: str = "core",
        priority: int = 100,
        name: str | None = None,
    ) -> None:
        """Register a function as a hook handler."""
        handler = FunctionHookHandler(fn, priority=priority, name=name)
        self.register(event, handler, source=source)

    def unregister_all(self, source: str) -> int:
        """Unregister all hooks from a given source. Returns count removed."""
        removed = 0
        for event in HookEvent:
            before = len(self._hooks[event])
            self._hooks[event] = [e for e in self._hooks[event] if e.source != source]
            removed += before - len(self._hooks[event])
        return removed

    async def run(
        self,
        event: HookEvent,
        context: HookContext,
    ) -> HookOutcome:
        """
        Run all hooks for an event.

        For BEFORE_TOOL_CALL: hooks run in priority order. First block wins.
        Argument mutations are chained (each hook sees the previous mutation).

        For other events: all hooks run, outcomes are merged.

        Returns:
            Merged HookOutcome from all handlers.
        """
        entries = self._hooks.get(event, [])
        if not entries:
            return HookOutcome.passthrough()

        merged = HookOutcome()

        for entry in entries:
            try:
                outcome = await entry.handler.handle(context)
                if outcome is None:
                    continue

                # Block takes precedence
                if outcome.block and not merged.block:
                    merged.block = True
                    merged.block_reason = outcome.block_reason
                    # For before_tool_call, stop processing on block
                    if event == HookEvent.BEFORE_TOOL_CALL:
                        return merged

                # Chain argument mutations
                if outcome.mutated_arguments is not None:
                    merged.mutated_arguments = outcome.mutated_arguments
                    # Update context so next hook sees the mutation
                    context.arguments = outcome.mutated_arguments

                # Accumulate context injections
                if outcome.prepend_context:
                    if merged.prepend_context:
                        merged.prepend_context += "\n" + outcome.prepend_context
                    else:
                        merged.prepend_context = outcome.prepend_context

                if outcome.append_context:
                    if merged.append_context:
                        merged.append_context += "\n" + outcome.append_context
                    else:
                        merged.append_context = outcome.append_context

                # Merge metadata
                merged.metadata.update(outcome.metadata)

            except Exception:
                logger.exception(
                    "Hook handler failed: event=%s source=%s handler=%r",
                    event.value, entry.source, entry.handler,
                )
                # Hook failures don't fail the pipeline

        return merged

    def list_hooks(self, event: HookEvent | None = None) -> list[dict[str, Any]]:
        """List registered hooks for debugging."""
        result = []
        events = [event] if event else list(HookEvent)
        for ev in events:
            for entry in self._hooks.get(ev, []):
                result.append({
                    "event": ev.value,
                    "source": entry.source,
                    "handler": repr(entry.handler),
                    "priority": entry.handler.priority,
                })
        return result

    def count(self, event: HookEvent | None = None) -> int:
        """Count registered hooks."""
        if event:
            return len(self._hooks.get(event, []))
        return sum(len(v) for v in self._hooks.values())


class AuditTrailHook(HookHandler):
    """
    Built-in hook that writes every tool execution to the tool_executions table.

    Registered automatically by create_default_registry(). Runs after every
    tool call and records the tool name, arguments, result, and metadata.
    """

    def __init__(self, pool: "asyncpg.Pool") -> None:
        self._pool = pool

    @property
    def priority(self) -> int:
        return 200  # Run after other hooks

    async def handle(self, context: HookContext) -> HookOutcome | None:
        if context.event != HookEvent.AFTER_TOOL_CALL:
            return None

        result = context.result
        if result is None:
            return None

        # Truncate output for storage (~10KB limit)
        output_json = None
        try:
            raw = result.output if hasattr(result, "output") else result
            serialized = json.dumps(raw, default=str)
            if len(serialized) > 10_000:
                # Truncating raw JSON produces invalid JSON; wrap as a string
                serialized = json.dumps(serialized[:10_000] + "...[truncated]")
            output_json = serialized
        except (TypeError, ValueError):
            output_json = None

        success = result.success if hasattr(result, "success") else True
        error = result.error if hasattr(result, "error") else None
        error_type = None
        if hasattr(result, "error_type") and result.error_type is not None:
            error_type = result.error_type.value if hasattr(result.error_type, "value") else str(result.error_type)
        energy_spent = result.energy_spent if hasattr(result, "energy_spent") else 0
        duration = result.duration_seconds if hasattr(result, "duration_seconds") else 0.0

        tool_context = context.metadata.get("tool_context", "unknown")
        call_id = context.metadata.get("call_id", "")
        session_id = context.metadata.get("session_id")

        # Truncate arguments for storage
        args_json = "{}"
        if context.arguments:
            try:
                serialized_args = json.dumps(context.arguments, default=str)
                if len(serialized_args) > 10_000:
                    serialized_args = json.dumps(serialized_args[:10_000] + "...[truncated]")
                args_json = serialized_args
            except (TypeError, ValueError):
                pass

        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    "SELECT record_tool_execution($1::jsonb)",
                    json.dumps({
                        "tool_name": context.tool_name or "unknown",
                        "arguments": json.loads(args_json),
                        "tool_context": tool_context,
                        "call_id": call_id,
                        "session_id": session_id,
                        "success": success,
                        "output": json.loads(output_json) if output_json else None,
                        "error": error,
                        "error_type": error_type,
                        "energy_spent": energy_spent,
                        "duration_seconds": duration,
                    }),
                )
        except Exception:
            # Audit failures must not crash the tool pipeline
            logger.warning("Failed to write tool audit record for %s", context.tool_name, exc_info=True)

        return None
