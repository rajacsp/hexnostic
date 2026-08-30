"""Line-based prompt helpers (questionary) for the Hexis CLI wizard.

Keyboard-first, native-terminal prompts: arrow-key selects, text entry with
readline, confirms. Ctrl+C raises ``KeyboardInterrupt`` (via ``unsafe_ask``) so
the caller's handler exits cleanly — the way a terminal program should behave.
"""
from __future__ import annotations

import re

import questionary
from questionary import Choice, Style

# Match the Hexis palette (burnt orange + teal).
_STYLE = Style([
    ("qmark", "fg:#d8774f bold"),
    ("question", "bold"),
    ("pointer", "fg:#d8774f bold"),
    ("highlighted", "fg:#d8774f bold"),
    ("selected", "fg:#3c6f64"),
    ("answer", "fg:#3c6f64 bold"),
    ("instruction", "fg:#8a8a8a"),
])

_MARKUP = re.compile(r"\[/?[^\]]*\]")


def _plain(s: str) -> str:
    """Strip Rich markup so questionary shows clean labels."""
    return _MARKUP.sub("", s).strip()


# All prompts are async (``ask_async``) so they run in the caller's already-
# running event loop — the wizard is async (asyncpg), and questionary's sync
# API would try to start a nested loop and fail.

async def select_index(message: str, options: list[str], *, default: int = 1) -> int:
    """Arrow-key select over *options*; returns the 1-based index chosen."""
    choices = [Choice(title=_plain(o), value=i) for i, o in enumerate(options, 1)]
    default_choice = choices[default - 1] if 1 <= default <= len(choices) else None
    return await questionary.select(
        _plain(message), choices=choices, default=default_choice,
        style=_STYLE, qmark="?", instruction="(↑/↓, Enter)",
    ).unsafe_ask_async()


async def select_value(message: str, pairs: list[tuple[str, object]], *, default_value=None):
    """Arrow-key select; *pairs* are (label, value). Returns the chosen value."""
    choices = [Choice(title=_plain(label), value=val) for label, val in pairs]
    default_choice = next((c for c in choices if c.value == default_value), None)
    return await questionary.select(
        _plain(message), choices=choices, default=default_choice,
        style=_STYLE, qmark="?", instruction="(↑/↓, Enter)",
    ).unsafe_ask_async()


async def text(message: str, *, default: str = "") -> str:
    return await questionary.text(_plain(message), default=default or "",
                                  style=_STYLE, qmark="?").unsafe_ask_async()


async def autocomplete(message: str, options: list[str], *, default: str = "") -> str:
    """Type-to-filter over *options* but any free-typed value is accepted."""
    return await questionary.autocomplete(
        _plain(message), choices=list(options), default=default or "",
        style=_STYLE, qmark="?", ignore_case=True,
    ).unsafe_ask_async()


async def confirm(message: str, *, default: bool = False) -> bool:
    return await questionary.confirm(_plain(message), default=default,
                                     style=_STYLE, qmark="?").unsafe_ask_async()


async def password(message: str) -> str:
    return await questionary.password(_plain(message), style=_STYLE,
                                      qmark="?").unsafe_ask_async()
