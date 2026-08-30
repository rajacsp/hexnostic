"""Hexis Textual theme — kept as a thin re-export of :mod:`apps.tui.design`.

The palette and theme now live in ``design.py`` (single source of truth). This
module remains so existing imports (``from apps.tui.theme import hexis_theme``)
keep working.
"""
from __future__ import annotations

from apps.tui.design import COLORS as HEXIS_COLORS
from apps.tui.design import CSS_VARS, hexis_theme

__all__ = ["hexis_theme", "HEXIS_COLORS", "CSS_VARS"]
