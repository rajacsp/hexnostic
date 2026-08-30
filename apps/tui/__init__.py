"""Hexis TUI — legacy Textual interfaces (kept, but no longer the default).

The CLI now uses line-based paths (apps/hexis_init.py, apps/cli_chat.py). These
Textual apps remain importable via ``HexisInitApp`` / ``HexisChatApp`` but are
imported lazily so that importing sibling helpers (model_catalog, textkit, tips)
never pulls in Textual.
"""
from __future__ import annotations

__all__ = ["HexisInitApp", "HexisChatApp"]


def __getattr__(name: str):
    if name == "HexisInitApp":
        from apps.tui.init_app import HexisInitApp
        return HexisInitApp
    if name == "HexisChatApp":
        from apps.tui.chat_app import HexisChatApp
        return HexisChatApp
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
