"""
Hexis Plugin System

Drop-in extensibility for tools, hooks, and skills.

Plugins are Python packages that implement the HexisPlugin interface.
They are discovered from the plugins/installed/ directory and registered
at startup.

Example usage:

    from plugins import load_plugins

    # Load all plugins and integrate with tool registry
    plugin_registry = await load_plugins(pool)
    for handler in plugin_registry.get_tool_handlers():
        tool_registry.register(handler)
    for event, hook in plugin_registry.get_hooks():
        tool_registry.hooks.register(event, hook, source=...)
"""

from .base import HexisPlugin, HexisPluginApi, PluginManifest, PluginValidationError
from .registry import PluginRegistry
from .loader import load_plugins, discover_plugins

__all__ = [
    "HexisPlugin",
    "HexisPluginApi",
    "PluginManifest",
    "PluginValidationError",
    "PluginRegistry",
    "load_plugins",
    "discover_plugins",
]
