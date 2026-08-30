"""Hexis plugin: Fathom meeting transcripts (list and ingest into memory) (#99 extraction from core)."""

from __future__ import annotations

import os
from pathlib import Path

from plugins.base import HexisPlugin, HexisPluginApi, PluginManifest

from .tools import create_fathom_tools

_MANIFEST = PluginManifest.from_json_file(Path(__file__).parent / "plugin.json")


class Plugin(HexisPlugin):
    @property
    def manifest(self) -> PluginManifest:
        return _MANIFEST

    def register(self, api: HexisPluginApi) -> None:
        def _resolve() -> str | None:
            return os.getenv("FATHOM_API_KEY")

        for handler in create_fathom_tools(api_key_resolver=_resolve):
            api.register_tool(handler)
        api.register_skill_dir(Path(__file__).parent / "skills")
