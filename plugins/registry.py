"""
Hexis Plugin System - Plugin Registry

Collects all registered capabilities from loaded plugins.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from core.tools.base import ToolHandler
from core.tools.hooks import HookEvent, HookHandler

logger = logging.getLogger(__name__)


@dataclass
class _PluginToolEntry:
    plugin_id: str
    handler: ToolHandler
    optional: bool


@dataclass
class _PluginHookEntry:
    plugin_id: str
    event: HookEvent
    handler: HookHandler


class PluginRegistry:
    """
    Aggregated registry of all capabilities from loaded plugins.

    This is separate from ToolRegistry -- it holds the raw registrations
    which are then applied to the ToolRegistry during startup.
    """

    def __init__(self) -> None:
        self._tools: list[_PluginToolEntry] = []
        self._hooks: list[_PluginHookEntry] = []
        self._skill_dirs: list[Path] = []
        self._loaded_plugins: dict[str, dict[str, Any]] = {}

    def _add_plugin(
        self,
        plugin_id: str,
        manifest_dict: dict[str, Any],
        tools: list[_PluginToolEntry],
        hooks: list[_PluginHookEntry],
        skill_dirs: list[Path],
    ) -> None:
        """Add a loaded plugin's registrations."""
        self._loaded_plugins[plugin_id] = manifest_dict
        self._tools.extend(tools)
        self._hooks.extend(hooks)
        self._skill_dirs.extend(skill_dirs)

    def get_tool_handlers(self) -> list[ToolHandler]:
        """Get all tool handlers from plugins."""
        return [e.handler for e in self._tools]

    def get_hooks(self) -> list[tuple[HookEvent, HookHandler, str]]:
        """Get all hooks as (event, handler, plugin_id) tuples."""
        return [(e.event, e.handler, e.plugin_id) for e in self._hooks]

    def get_skill_dirs(self) -> list[Path]:
        """Get all skill directories from plugins."""
        return list(self._skill_dirs)

    def list_plugins(self) -> list[dict[str, Any]]:
        """List loaded plugins with metadata."""
        return [
            {"id": pid, **meta}
            for pid, meta in self._loaded_plugins.items()
        ]

    def plugin_count(self) -> int:
        return len(self._loaded_plugins)

    def tool_count(self) -> int:
        return len(self._tools)

    def hook_count(self) -> int:
        return len(self._hooks)
