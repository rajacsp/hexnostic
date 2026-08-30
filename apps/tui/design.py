"""Hexis TUI design tokens — the single source of truth for color.

Two consumers:
  * `hexis.tcss` uses the Textual theme variables registered here (``$primary``,
    ``$secondary``, ``$muted``, ``$dim`` …) so the stylesheet never hard-codes hex.
  * Python widgets that render Rich renderables import ``COLORS`` / the small
    ``style`` helpers below — never f-string markup on model-supplied text.

Keep the burnt-orange + teal identity; everything else is derived from it.
"""
from __future__ import annotations

from rich.style import Style
from rich.text import Text
from textual.theme import Theme

# ── Palette ──────────────────────────────────────────────────────────────────
# Identity is `accent` (burnt orange) + `teal`. Accent is used with restraint:
# the composer prompt, the active/running affordance, headings — not everywhere.

COLORS: dict[str, str] = {
    # identity
    "accent": "#d8774f",         # burnt orange — headings, user, running spinner
    "accent_strong": "#b45835",  # darker orange — hover / pressed
    "teal": "#3c6f64",           # secondary — labels, assistant name, links
    "teal_dim": "#2d544c",
    # depth (layered shades stand in for openclaw's glass)
    "bg": "#1a1a1a",
    "surface": "#242424",
    "elevated": "#2e2a26",
    # text hierarchy
    "text": "#e0d8d0",           # body
    "strong": "#f4ece2",         # headings / emphasis
    "dim": "#9a8f80",            # readable secondary / metadata
    "muted": "#4e463d",          # borders, rules, very-dim (NOT body text)
    # semantic
    "ok": "#5cba7d",
    "warn": "#d9a441",
    "danger": "#d4574e",
    "info": "#5a8bbf",
}


def c(name: str) -> str:
    """Return a palette hex by token name (raises on typo — fail loud)."""
    return COLORS[name]


# Extra CSS variables beyond Textual's built-ins ($primary/$secondary/$surface/
# $panel/$success/$warning/$error/…). Injected via App.get_css_variables so they
# resolve even on the *first* stylesheet parse (before the theme is activated).
CSS_VARS: dict[str, str] = {
    "muted": COLORS["muted"],
    "dim": COLORS["dim"],
    "elevated": COLORS["elevated"],
    "strong": COLORS["strong"],
    "info": COLORS["info"],
    "teal-dim": COLORS["teal_dim"],
    "accent-strong": COLORS["accent_strong"],
}


# ── Rich helpers (markup-safe) ───────────────────────────────────────────────
# Always build Text with explicit styles; never interpolate model text into a
# markup string (a stray "[" would corrupt or raise MarkupError).

def styled(text: str, token: str, *, bold: bool = False, italic: bool = False,
           dim: bool = False) -> Text:
    """A Rich ``Text`` in a palette color, from *plain* text (no markup parsed)."""
    return Text(text, style=Style(color=COLORS.get(token, token), bold=bold,
                                  italic=italic, dim=dim))


def label(text: str, token: str = "teal") -> Text:
    """A bold field/section label."""
    return styled(text, token, bold=True)


# ── Glyphs ───────────────────────────────────────────────────────────────────

GLYPHS = {
    "prompt": "❯",       # ❯  composer prompt
    "run": "●",          # ●  tool running
    "ok": "✓",           # ✓  done
    "err": "✗",          # ✗  failed
    "caret": "▌",        # ▌  streaming caret
    "bullet": "•",       # •
    "sep": "│",          # │  status-bar separator
    "rail": "┃",         # ┃
    "branch": "├─", # ├─
    "leaf": "└─",   # └─
    "chev_open": "▾",    # ▾
    "chev_closed": "▸",  # ▸
    "energy": "⚡",       # ⚡
    "logo": "⬡",         # ⬡  hexagon wordmark mark
}


# ── Textual theme ────────────────────────────────────────────────────────────
# Built-ins we lean on in CSS: $primary (accent), $secondary (teal),
# $accent (accent_strong), $foreground, $background, $surface, $panel,
# $success/$warning/$error. Extra tokens registered as custom variables below.

hexis_theme = Theme(
    name="hexis",
    primary=COLORS["accent"],
    secondary=COLORS["teal"],
    accent=COLORS["accent_strong"],
    foreground=COLORS["text"],
    background=COLORS["bg"],
    surface=COLORS["surface"],
    panel=COLORS["elevated"],
    success=COLORS["ok"],
    warning=COLORS["warn"],
    error=COLORS["danger"],
    dark=True,
    variables={
        **CSS_VARS,
        # nicer defaults for built-in widgets
        "block-cursor-foreground": COLORS["bg"],
        "block-cursor-background": COLORS["accent"],
        "input-selection-background": COLORS["teal"] + " 35%",
    },
)
