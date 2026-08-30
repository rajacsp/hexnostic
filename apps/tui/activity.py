"""Tool-activity model for the chat transcript.

A small, framework-free record of the tool calls in a turn: status derivation
(running / done / error), a ring-buffered cap so a chatty turn can't flood
scrollback, an output-preview char cap, and secret/path redaction applied
*before* anything is handed to a widget.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from apps.tui import textkit

ENTRY_LIMIT = 100          # ring buffer — keep only the most recent N tools
PREVIEW_LIMIT = 2000       # chars of tool output kept for preview


@dataclass
class ToolEntry:
    name: str
    status: str = "running"          # running | done | error
    duration_ms: int | None = None
    preview: str = ""
    error: str = ""

    @property
    def glyph(self) -> str:
        return {"running": "●", "done": "✓", "error": "✗"}.get(self.status, "•")

    @property
    def token(self) -> str:
        """Palette token name for this entry's status color."""
        return {"running": "accent", "done": "ok", "error": "danger"}.get(
            self.status, "dim"
        )

    def duration_str(self) -> str:
        if self.duration_ms is None:
            return ""
        secs = self.duration_ms / 1000.0
        return f"{secs:.1f}s" if secs >= 0.1 else f"{self.duration_ms}ms"


@dataclass
class ToolActivity:
    """The tool calls made within a single assistant turn."""

    entries: list[ToolEntry] = field(default_factory=list)

    def start(self, name: str) -> ToolEntry:
        entry = ToolEntry(name=name, status="running")
        self.entries.append(entry)
        if len(self.entries) > ENTRY_LIMIT:
            self.entries = self.entries[-ENTRY_LIMIT:]
        return entry

    def complete(
        self,
        name: str,
        *,
        success: bool,
        duration: float | None = None,
        output: str = "",
        error: str = "",
    ) -> ToolEntry:
        # Match the most recent still-running entry with this name.
        entry = next(
            (e for e in reversed(self.entries)
             if e.name == name and e.status == "running"),
            None,
        )
        if entry is None:
            entry = self.start(name)
        entry.status = "done" if success else "error"
        if duration is not None:
            entry.duration_ms = int(duration * 1000)
        if output:
            entry.preview = textkit.truncate(textkit.redact(output), PREVIEW_LIMIT)
        if error:
            entry.error = textkit.truncate(textkit.redact(error), 400)
        return entry

    @property
    def has_error(self) -> bool:
        return any(e.status == "error" for e in self.entries)

    @property
    def running(self) -> bool:
        return any(e.status == "running" for e in self.entries)

    def summary(self) -> str:
        n = len(self.entries)
        noun = "tool" if n == 1 else "tools"
        if self.has_error:
            return f"{n} {noun} · error"
        if self.running:
            return f"{n} {noun} · running"
        return f"{n} {noun}"
