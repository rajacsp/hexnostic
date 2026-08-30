"""
Hexis Plugin System - Loader

Discovery and loading of plugins from the filesystem.

Plugins are discovered from:
1. plugins/installed/ directory (bundled)
2. Additional directories from DB config (plugin.external_dirs)
"""

from __future__ import annotations

import importlib
import json
import logging
import sys
from pathlib import Path
from typing import Any, TYPE_CHECKING

from .base import (
    HexisPlugin,
    HexisPluginApi,
    PluginManifest,
    PluginValidationError,
    _RegisteredHook,
    _RegisteredTool,
)
from .registry import PluginRegistry, _PluginToolEntry, _PluginHookEntry

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)

# Default plugin directory (bundled with repo)
_PLUGINS_DIR = Path(__file__).resolve().parent / "installed"


class PluginConfigError(ValueError):
    """A plugin's stored configuration does not satisfy its manifest."""


def discover_plugins(extra_dirs: list[Path] | None = None, *, include_bundled: bool = True) -> list[Path]:
    """
    Discover plugin directories.

    Each plugin is a subdirectory containing either:
    - plugin.json (manifest) + __init__.py (entry point)
    - Just __init__.py with a class implementing HexisPlugin

    Returns list of plugin directory paths.
    """
    dirs_to_scan = [_PLUGINS_DIR] if include_bundled else []
    if extra_dirs:
        dirs_to_scan.extend(extra_dirs)

    plugins: list[Path] = []
    for base_dir in dirs_to_scan:
        if not base_dir.exists():
            continue
        for child in sorted(base_dir.iterdir()):
            if not child.is_dir():
                continue
            if child.name.startswith((".", "_")):
                continue
            # Must have __init__.py
            if (child / "__init__.py").exists():
                plugins.append(child)

    return plugins


def _load_plugin_module(plugin_dir: Path) -> HexisPlugin | None:
    """Import a plugin package and find the HexisPlugin subclass."""
    module_name = f"_hexis_plugin_{plugin_dir.name}"

    # Add parent to sys.path temporarily if needed
    parent = str(plugin_dir.parent)
    added_to_path = False
    if parent not in sys.path:
        sys.path.insert(0, parent)
        added_to_path = True

    try:
        # Import the package
        spec = importlib.util.spec_from_file_location(
            module_name,
            plugin_dir / "__init__.py",
            submodule_search_locations=[str(plugin_dir)],
        )
        if spec is None or spec.loader is None:
            logger.warning("Could not create module spec for plugin: %s", plugin_dir)
            return None

        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)

        # Look for a HexisPlugin subclass or a 'plugin' attribute
        if hasattr(module, "plugin") and isinstance(module.plugin, HexisPlugin):
            return module.plugin

        # Search for HexisPlugin subclass instances
        for attr_name in dir(module):
            attr = getattr(module, attr_name)
            if isinstance(attr, HexisPlugin):
                return attr

        # Search for HexisPlugin subclass (not instance)
        for attr_name in dir(module):
            attr = getattr(module, attr_name)
            if (
                isinstance(attr, type)
                and issubclass(attr, HexisPlugin)
                and attr is not HexisPlugin
            ):
                return attr()

        logger.warning("No HexisPlugin found in plugin: %s", plugin_dir)
        return None

    except Exception:
        logger.exception("Failed to load plugin: %s", plugin_dir)
        return None
    finally:
        if added_to_path and parent in sys.path:
            sys.path.remove(parent)


async def _load_plugin_config(pool: "asyncpg.Pool", plugin_id: str) -> dict[str, Any]:
    """Load plugin-specific config from the database."""
    async with pool.acquire() as conn:
        raw = await conn.fetchval(
            "SELECT value FROM config WHERE key = $1",
            f"plugin.{plugin_id}",
        )
    if raw is None:
        return {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise PluginConfigError(
                f"plugin.{plugin_id} must contain valid JSON: {exc.msg}"
            ) from exc
    if not isinstance(raw, dict):
        raise PluginConfigError(f"plugin.{plugin_id} must be a JSON object")
    return raw


def _validated_plugin_manifest(
    plugin_obj: HexisPlugin,
    file_manifest: PluginManifest | None = None,
) -> PluginManifest:
    manifest = plugin_obj.manifest
    if not isinstance(manifest, PluginManifest):
        raise PluginValidationError("manifest property must return PluginManifest")
    manifest.validate()

    if file_manifest is not None and file_manifest.to_dict() != manifest.to_dict():
        raise PluginValidationError(
            "plugin.json must exactly match the PluginManifest returned by the plugin"
        )
    return manifest


def _validate_plugin_config(
    manifest: PluginManifest,
    config: dict[str, Any],
) -> None:
    """Validate one live configuration object against its manifest schema."""

    if not isinstance(config, dict):
        raise PluginConfigError(f"plugin.{manifest.id} must be a JSON object")
    if not manifest.config_schema:
        return

    from jsonschema.validators import validator_for

    validator = validator_for(manifest.config_schema)(manifest.config_schema)
    errors = sorted(
        validator.iter_errors(config),
        key=lambda error: tuple(str(part) for part in error.path),
    )
    if not errors:
        return
    details: list[str] = []
    for error in errors[:3]:
        path = ".".join(str(part) for part in error.path) or "<root>"
        if error.validator in {"required", "additionalProperties"}:
            message = error.message
        elif error.validator == "type":
            expected = error.validator_value
            message = f"must be of type {expected}; received {type(error.instance).__name__}"
        elif error.validator == "enum":
            message = f"must be one of {error.validator_value!r}"
        elif error.validator == "minLength":
            message = f"must contain at least {error.validator_value} character(s)"
        elif error.validator == "maxLength":
            message = f"must contain at most {error.validator_value} character(s)"
        elif error.validator == "pattern":
            message = f"must match pattern {error.validator_value!r}"
        else:
            message = f"violates the {error.validator!r} schema constraint"
        details.append(f"{path}: {message}")
    if len(errors) > 3:
        details.append(f"and {len(errors) - 3} more error(s)")
    raise PluginConfigError("; ".join(details))


async def load_plugins(
    pool: "asyncpg.Pool",
    extra_dirs: list[Path] | None = None,
    *,
    include_bundled: bool = True,
) -> PluginRegistry:
    """
    Discover and load all plugins.

    Args:
        pool: Database connection pool
        extra_dirs: Additional directories to scan for plugins

    Returns:
        PluginRegistry with all registered capabilities
    """
    registry = PluginRegistry()

    # Additional plugin directories from DB config (plugin.external_dirs):
    # a JSON array of absolute paths. Unreadable entries are skipped loudly.
    dirs = list(extra_dirs or [])
    try:
        async with pool.acquire() as conn:
            raw = await conn.fetchval("SELECT get_config('plugin.external_dirs')")
        if raw:
            entries = json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(entries, list):
                for entry in entries:
                    path = Path(str(entry)).expanduser()
                    if path.is_dir():
                        dirs.append(path)
                    else:
                        logger.warning("plugin.external_dirs entry is not a directory: %s", entry)
    except Exception:
        logger.warning("Failed to read plugin.external_dirs", exc_info=True)

    plugin_dirs = discover_plugins(dirs, include_bundled=include_bundled)

    if not plugin_dirs:
        logger.debug("No plugins discovered")
        return registry

    seen_ids: set[str] = set()

    for plugin_dir in plugin_dirs:
        file_manifest: PluginManifest | None = None
        manifest_path = plugin_dir / "plugin.json"
        if manifest_path.exists():
            try:
                file_manifest = PluginManifest.from_json_file(manifest_path)
            except Exception as exc:
                logger.error(
                    "Skipping plugin at %s: invalid plugin.json: %s",
                    plugin_dir,
                    exc,
                )
                continue

        # Load the plugin module
        plugin_obj = _load_plugin_module(plugin_dir)
        if plugin_obj is None:
            continue

        try:
            manifest = _validated_plugin_manifest(
                plugin_obj,
                file_manifest=file_manifest,
            )
        except Exception as exc:
            logger.error("Skipping plugin at %s: invalid manifest: %s", plugin_dir, exc)
            continue

        # Check for ID conflicts
        if manifest.id in seen_ids:
            logger.error("Duplicate plugin ID: %s (skipping %s)", manifest.id, plugin_dir)
            continue
        seen_ids.add(manifest.id)

        # Load plugin config from DB
        try:
            plugin_config = await _load_plugin_config(pool, manifest.id)
            _validate_plugin_config(manifest, plugin_config)
        except PluginConfigError as exc:
            logger.error(
                "Skipping plugin %s: invalid config plugin.%s: %s. "
                "Correct or remove that config value, then restart Hexis.",
                manifest.id,
                manifest.id,
                exc,
            )
            continue
        except Exception:
            logger.exception(
                "Skipping plugin %s: could not load config plugin.%s",
                manifest.id,
                manifest.id,
            )
            continue

        # Create API object
        api = HexisPluginApi(
            plugin_id=manifest.id,
            pool=pool,
            plugin_config=plugin_config,
        )

        # Run registration
        try:
            plugin_obj.register(api)
        except Exception:
            logger.exception("Plugin registration failed: %s", manifest.id)
            continue

        # Ownership contract (#99): when the manifest declares owned tools,
        # runtime registrations must match exactly — loud failure over drift.
        if manifest.tools:
            registered_names = {rt.handler.spec.name for rt in api._get_tools()}
            declared = set(manifest.tools)
            if registered_names != declared:
                logger.error(
                    "Skipping plugin %s: tool ownership mismatch — declared %s, registered %s",
                    manifest.id, sorted(declared), sorted(registered_names),
                )
                continue

        # Collect registrations
        tools = [
            _PluginToolEntry(
                plugin_id=manifest.id,
                handler=rt.handler,
                optional=rt.optional,
            )
            for rt in api._get_tools()
        ]
        hooks = [
            _PluginHookEntry(
                plugin_id=manifest.id,
                event=rh.event,
                handler=rh.handler,
            )
            for rh in api._get_hooks()
        ]
        skill_dirs = api._get_skill_dirs()

        registry._add_plugin(
            plugin_id=manifest.id,
            manifest_dict=manifest.to_dict(),
            tools=tools,
            hooks=hooks,
            skill_dirs=skill_dirs,
        )

        logger.info(
            "Loaded plugin: %s v%s (%d tools, %d hooks, %d skill dirs)",
            manifest.id, manifest.version,
            len(tools), len(hooks), len(skill_dirs),
        )

    logger.info(
        "Plugin loading complete: %d plugins, %d tools, %d hooks",
        registry.plugin_count(), registry.tool_count(), registry.hook_count(),
    )
    return registry
