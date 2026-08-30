"""
Hexis Plugin System - Base Types

Defines the plugin interface and the API object plugins receive.
"""

from __future__ import annotations

import json
import logging
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TYPE_CHECKING

from core.tools.base import ToolHandler, ToolSpec
from core.tools.hooks import HookEvent, HookHandler

if TYPE_CHECKING:
    import asyncpg


_PLUGIN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


class PluginValidationError(ValueError):
    """A plugin manifest cannot be trusted as a load-time contract."""


@dataclass
class PluginManifest:
    """Plugin metadata and configuration schema."""

    id: str
    name: str
    version: str = "0.0.0"
    description: str = ""
    config_schema: dict[str, Any] = field(default_factory=dict)
    # Ownership contract (#99): the tool names this plugin owns. When
    # non-empty, runtime registrations must match exactly — a mismatch is a
    # loud load failure, never a silent drift.
    tools: list[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PluginManifest":
        if not isinstance(data, dict):
            raise PluginValidationError("manifest must be a JSON object")
        raw_id = data.get("id", "")
        raw_name = data.get("name", "")
        raw_version = data.get("version", "0.0.0")
        raw_description = data.get("description", "")
        for field_name, value in (
            ("id", raw_id),
            ("name", raw_name),
            ("version", raw_version),
            ("description", raw_description),
        ):
            if not isinstance(value, str):
                raise PluginValidationError(f"{field_name} must be a string")
        raw_schema = data.get("config_schema", {})
        if not isinstance(raw_schema, dict):
            raise PluginValidationError("config_schema must be a JSON object")
        raw_tools = data.get("tools", [])
        if not isinstance(raw_tools, list) or not all(isinstance(x, str) for x in raw_tools):
            raise PluginValidationError("tools must be a list of tool-name strings")
        manifest = cls(
            id=raw_id,
            name=raw_name,
            version=raw_version,
            description=raw_description,
            config_schema=dict(raw_schema),
            tools=list(raw_tools),
        )
        manifest.validate()
        return manifest

    @classmethod
    def from_json_file(cls, path: Path) -> "PluginManifest":
        """Load manifest from a plugin.json file."""
        text = path.read_text(encoding="utf-8")
        data = json.loads(text)
        return cls.from_dict(data)

    def validate(self) -> None:
        """Validate metadata and the declared configuration JSON Schema."""

        errors: list[str] = []
        if not isinstance(self.id, str) or not _PLUGIN_ID_RE.fullmatch(self.id):
            errors.append(
                "id must be 1-64 lowercase letters, digits, hyphens, or underscores"
            )
        if not isinstance(self.name, str) or not self.name.strip():
            errors.append("name must be a non-empty string")
        if not isinstance(self.version, str) or not _SEMVER_RE.fullmatch(self.version):
            errors.append("version must be semantic versioning (for example, 1.2.3)")
        if not isinstance(self.description, str):
            errors.append("description must be a string")
        if not isinstance(self.config_schema, dict):
            errors.append("config_schema must be a JSON object")
        elif self.config_schema:
            if self.config_schema.get("type") != "object":
                errors.append("config_schema root type must be 'object'")
            try:
                from jsonschema.validators import validator_for

                validator_for(self.config_schema).check_schema(self.config_schema)
            except Exception as exc:
                errors.append(f"config_schema is not valid JSON Schema: {exc}")
        if errors:
            raise PluginValidationError("; ".join(errors))

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "description": self.description,
            "config_schema": self.config_schema,
            "tools": list(self.tools),
        }


@dataclass
class _RegisteredTool:
    """Internal: a tool handler registered by a plugin."""
    handler: ToolHandler
    optional: bool


@dataclass
class _RegisteredHook:
    """Internal: a hook registered by a plugin."""
    event: HookEvent
    handler: HookHandler


class _OptionalToolWrapper(ToolHandler):
    """Wraps a ToolHandler to force its spec.optional = True."""

    def __init__(self, inner: ToolHandler):
        self._inner = inner
        self._spec: ToolSpec | None = None

    @property
    def spec(self) -> ToolSpec:
        if self._spec is None:
            from dataclasses import replace
            self._spec = replace(self._inner.spec, optional=True)
        return self._spec

    async def execute(self, arguments: dict[str, Any], context: Any) -> Any:
        return await self._inner.execute(arguments, context)

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        return self._inner.validate(arguments)


class HexisPluginApi:
    """
    API object passed to plugins during registration.

    Provides methods to register tools, hooks, and skills.
    Plugins use this to declare their capabilities without
    directly touching the tool registry.
    """

    def __init__(
        self,
        plugin_id: str,
        pool: "asyncpg.Pool",
        plugin_config: dict[str, Any] | None = None,
    ):
        self._plugin_id = plugin_id
        self._pool = pool
        self._plugin_config = plugin_config or {}
        self._logger = logging.getLogger(f"plugin.{plugin_id}")
        self._tools: list[_RegisteredTool] = []
        self._hooks: list[_RegisteredHook] = []
        self._skill_dirs: list[Path] = []

    @property
    def plugin_id(self) -> str:
        return self._plugin_id

    @property
    def pool(self) -> "asyncpg.Pool":
        """Database connection pool."""
        return self._pool

    @property
    def config(self) -> dict[str, Any]:
        """Plugin-specific configuration from the database."""
        return self._plugin_config

    @property
    def logger(self) -> logging.Logger:
        """Namespaced logger for this plugin."""
        return self._logger

    def register_tool(self, handler: ToolHandler, *, optional: bool = False) -> None:
        """
        Register a tool handler.

        Args:
            handler: Tool handler implementing ToolHandler
            optional: If True, tool requires explicit allowlist inclusion
        """
        if optional:
            handler = _OptionalToolWrapper(handler)
        self._tools.append(_RegisteredTool(handler=handler, optional=optional))
        self._logger.debug("Registered tool: %s (optional=%s)", handler.spec.name, optional)

    def register_hook(self, event: HookEvent, handler: HookHandler) -> None:
        """Register a lifecycle hook."""
        self._hooks.append(_RegisteredHook(event=event, handler=handler))
        self._logger.debug("Registered hook: %s", event.value)

    def register_skill_dir(self, path: Path) -> None:
        """Register a directory containing skill markdown files."""
        if path.exists() and path.is_dir():
            self._skill_dirs.append(path)
            self._logger.debug("Registered skill dir: %s", path)

    # --- Accessors for the plugin loader ---

    def _get_tools(self) -> list[_RegisteredTool]:
        return self._tools

    def _get_hooks(self) -> list[_RegisteredHook]:
        return self._hooks

    def _get_skill_dirs(self) -> list[Path]:
        return self._skill_dirs


class HexisPlugin(ABC):
    """
    Base class for Hexis plugins.

    Subclasses must implement:
    - manifest: Property returning PluginManifest
    - register: Method called with HexisPluginApi to register capabilities
    """

    @property
    @abstractmethod
    def manifest(self) -> PluginManifest:
        """Return the plugin manifest with id, name, version, etc."""
        ...

    @abstractmethod
    def register(self, api: HexisPluginApi) -> None:
        """
        Register tools, hooks, and skills with the plugin API.

        Called once during plugin loading. The plugin should use
        api.register_tool(), api.register_hook(), etc.
        """
        ...
