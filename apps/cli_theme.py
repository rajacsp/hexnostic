"""Shared CLI theme for Hexis — colors, helpers, reusable widgets.

Colors match the UI CSS variables from hexis-ui/app/globals.css:
  accent: #d8774f  teal: #3c6f64  muted: #4e463d  strong: #b45835
"""
from __future__ import annotations

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from rich.theme import Theme

HEXIS_THEME = Theme(
    {
        "accent": "#d8774f",
        "accent.strong": "#b45835",
        "teal": "#3c6f64",
        "muted": "#4e463d",
        "ok": "green",
        "warn": "yellow",
        "fail": "red",
        "heading": "bold #d8774f",
        "key": "#3c6f64",
        "value": "",
        "dim": "dim",
    }
)

console = Console(theme=HEXIS_THEME)
err_console = Console(theme=HEXIS_THEME, stderr=True)


def heading(text: str) -> None:
    console.print(f"\n[heading]{text}[/heading]")


def success(text: str) -> None:
    console.print(f"[ok]{text}[/ok]")


def warn(text: str) -> None:
    err_console.print(f"[warn]{text}[/warn]")


def error(text: str) -> None:
    err_console.print(f"[fail]{text}[/fail]")


def kv(key: str, value: str, *, pad: int = 0) -> None:
    label = f"{key}:".ljust(pad + 1) if pad else f"{key}:"
    console.print(f"  [key]{label}[/key] {value}")


def make_table(
    *columns: str | tuple[str, dict],
    title: str | None = None,
    show_lines: bool = False,
) -> Table:
    table = Table(
        title=title,
        show_lines=show_lines,
        border_style="muted",
        header_style="bold",
        title_style="heading",
        pad_edge=False,
        expand=False,
    )
    for col in columns:
        if isinstance(col, tuple):
            table.add_column(col[0], **col[1])
        else:
            table.add_column(col)
    return table


def make_panel(content, *, title: str = "", subtitle: str = "") -> Panel:
    return Panel(
        content,
        title=f"[accent]{title}[/accent]" if title else None,
        subtitle=f"[muted]{subtitle}[/muted]" if subtitle else None,
        border_style="muted",
        padding=(1, 2),
    )


def energy_bar(current: float | int, maximum: float | int) -> str:
    current = max(0, min(float(current), float(maximum)))
    maximum = float(maximum)
    width = 20
    filled = int((current / maximum) * width) if maximum > 0 else 0
    bar = "[accent]" + "\u2588" * filled + "[/accent]" + "[muted]" + "\u2591" * (width - filled) + "[/muted]"
    return f"{bar} {current:.0f}/{maximum:.0f}"


def mood_label(mood: str | None, valence: float | None = None) -> str:
    if not mood:
        return "[muted]unknown[/muted]"
    color_map = {
        "enthusiastic": "accent",
        "content": "teal",
        "curious": "teal",
        "calm": "teal",
        "focused": "teal",
        "neutral": "muted",
        "concerned": "warn",
        "subdued": "warn",
        "distressed": "fail",
        "withdrawn": "fail",
    }
    color = color_map.get(mood, "muted")
    val_str = f" [muted](valence: {valence:.2f})[/muted]" if valence is not None else ""
    return f"[{color}]{mood}[/{color}]{val_str}"


def status_badge(ok: bool, label: str = "") -> str:
    if ok:
        return f"[ok]\u2714[/ok] {label}" if label else "[ok]\u2714[/ok]"
    return f"[fail]\u2718[/fail] {label}" if label else "[fail]\u2718[/fail]"


def enabled_badge(enabled: bool) -> str:
    if enabled:
        return "[ok]enabled[/ok]"
    return "[muted]disabled[/muted]"
