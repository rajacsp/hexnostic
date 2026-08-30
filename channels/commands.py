"""
Hexis Channel System - Slash Commands

Per-channel command registration and dispatch. Built-in commands provide
agent status, memory recall, goal listing, and energy information.

Commands are prefixed with "/" in channel messages. The manager checks
for commands before routing to the conversation pipeline.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Awaitable, TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)


@dataclass
class ChannelCommand:
    """Definition of a channel command."""

    name: str                                          # e.g. "status"
    description: str
    usage: str = ""                                    # e.g. "/recall <query>"
    handler: Callable[..., Awaitable[str]] | None = None


class CommandRegistry:
    """
    Registry of channel commands.

    Commands are registered at startup and dispatched by the manager
    when a message starts with "/".
    """

    def __init__(self) -> None:
        self._commands: dict[str, ChannelCommand] = {}
        self._register_builtins()

    def register(self, command: ChannelCommand) -> None:
        self._commands[command.name.lower()] = command

    def has(self, name: str) -> bool:
        return name.lower() in self._commands

    def list_commands(self) -> list[ChannelCommand]:
        return list(self._commands.values())

    async def execute(
        self,
        name: str,
        args: str,
        pool: asyncpg.Pool,
    ) -> str | None:
        """Execute a command. Returns the response text, or None if not found."""
        cmd = self._commands.get(name.lower())
        if not cmd or not cmd.handler:
            return None
        try:
            return await cmd.handler(args, pool)
        except Exception:
            logger.exception("Command /%s failed", name)
            return f"Command /{name} failed. Please try again."

    def _register_builtins(self) -> None:
        self.register(ChannelCommand(
            name="status",
            description="Show agent status (energy, uptime, connected channels)",
            usage="/status",
            handler=_handle_status,
        ))
        self.register(ChannelCommand(
            name="recall",
            description="Search memories and return top results",
            usage="/recall <query>",
            handler=_handle_recall,
        ))
        self.register(ChannelCommand(
            name="goals",
            description="List active goals",
            usage="/goals",
            handler=_handle_goals,
        ))
        self.register(ChannelCommand(
            name="energy",
            description="Show current energy level and regeneration rate",
            usage="/energy",
            handler=_handle_energy,
        ))
        self.register(ChannelCommand(
            name="help",
            description="List available commands",
            usage="/help",
            handler=_handle_help,
        ))


def parse_command(text: str) -> tuple[str, str] | None:
    """
    Parse a command from message text.

    Returns (command_name, args_string) or None if not a command.
    """
    text = text.strip()
    if not text.startswith("/"):
        return None

    parts = text[1:].split(None, 1)
    if not parts:
        return None

    name = parts[0].lower()
    args = parts[1] if len(parts) > 1 else ""
    return name, args


# Built-in command handlers


async def _handle_status(args: str, pool: asyncpg.Pool) -> str:
    """Show agent status (rendered by channel_status_summary in the DB)."""
    try:
        async with pool.acquire() as conn:
            return await conn.fetchval("SELECT channel_status_summary()")
    except Exception:
        logger.exception("Status command failed")
        return "Failed to retrieve status."


async def _handle_recall(args: str, pool: asyncpg.Pool) -> str:
    """Search memories."""
    if not args.strip():
        return "Usage: /recall <query>\nExample: /recall what do I know about Python?"

    try:
        from core.agent_api import db_dsn_from_env
        from core.cognitive_memory_api import CognitiveMemory

        dsn = db_dsn_from_env()
        async with CognitiveMemory.connect(dsn) as mem:
            results = await mem.recall(args.strip(), limit=3)

        if not results:
            return f"No memories found for: {args.strip()}"

        lines = [f"**Recall: {args.strip()}**\n"]
        for i, memory in enumerate(results, 1):
            content = memory.content[:200]
            if len(memory.content) > 200:
                content += "..."
            mem_type = memory.type.value if hasattr(memory.type, "value") else str(memory.type)
            lines.append(f"{i}. [{mem_type}] {content}")
        return "\n".join(lines)
    except Exception:
        logger.exception("Recall command failed")
        return "Failed to search memories."


async def _handle_goals(args: str, pool: asyncpg.Pool) -> str:
    """List active goals (rendered by channel_goals_summary in the DB)."""
    try:
        async with pool.acquire() as conn:
            return await conn.fetchval("SELECT channel_goals_summary()")
    except Exception:
        logger.exception("Goals command failed")
        return "Failed to retrieve goals."


async def _handle_energy(args: str, pool: asyncpg.Pool) -> str:
    """Show energy details (rendered by channel_energy_summary in the DB)."""
    try:
        async with pool.acquire() as conn:
            return await conn.fetchval("SELECT channel_energy_summary()")
    except Exception:
        logger.exception("Energy command failed")
        return "Failed to retrieve energy info."


async def _handle_help(args: str, pool: asyncpg.Pool) -> str:
    """List available commands."""
    # This handler gets a reference to the registry via closure
    # For built-in use, we construct a fresh registry to list commands
    registry = CommandRegistry()
    lines = ["**Available Commands**\n"]
    for cmd in registry.list_commands():
        usage = cmd.usage or f"/{cmd.name}"
        lines.append(f"• `{usage}` — {cmd.description}")
    return "\n".join(lines)
