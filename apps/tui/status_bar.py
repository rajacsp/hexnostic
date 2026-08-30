"""Progressive-disclosure status bar for the chat screen.

One line that pins the busy indicator + model on the left and sheds tail
segments (energy, tools, mood, context) in priority order as the terminal
narrows — instead of truncating mid-segment. Owns its own 1s tick so callers
just push state via ``set_busy`` / ``set_idle`` / ``update``.
"""
from __future__ import annotations

from time import monotonic

from rich.style import Style
from rich.text import Text
from textual.widgets import Static

from apps.tui import textkit
from apps.tui.design import COLORS, GLYPHS


class StatusBar(Static):
    """A single-line, width-aware status readout."""

    DEFAULT_CSS = """
    StatusBar {
        height: 1;
        background: $surface;
        color: $foreground;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__("", **kwargs)
        self._busy = False
        self._label = ""
        self._model = ""
        self._energy: int | None = None
        self._max_energy: int | None = None
        self._tools = 0
        self._mood = ""
        self._ctx_pct: float | None = None
        self._started: float | None = None
        self._idle_at: float | None = None
        self._tick = 0
        self._width = 80

    def on_mount(self) -> None:
        self.set_interval(1.0, self._on_tick)
        # First paint must wait until after layout — reading self.size mid-mount
        # re-enters layout and deadlocks.
        self.call_after_refresh(self._repaint)

    def on_resize(self, event) -> None:
        self._width = event.size.width or 80
        self._repaint()

    def _on_tick(self) -> None:
        self._tick += 1
        self._repaint()

    # ── state in ────────────────────────────────────────────────────────────
    def set_busy(self, label: str = "") -> None:
        if not self._busy or self._started is None:
            self._started = monotonic()
        self._busy = True
        self._label = label
        self._idle_at = None
        self._repaint()

    def set_idle(self) -> None:
        if self._busy:
            self._idle_at = monotonic()
        self._busy = False
        self._label = ""
        self._started = None
        self._repaint()

    def update_state(
        self,
        *,
        model: str | None = None,
        energy: int | None = None,
        max_energy: int | None = None,
        tools: int | None = None,
        mood: str | None = None,
        context: float | None = None,
    ) -> None:
        if model is not None:
            self._model = model
        if energy is not None:
            self._energy = energy
        if max_energy is not None:
            self._max_energy = max_energy
        if tools is not None:
            self._tools = tools
        if mood is not None:
            self._mood = mood
        if context is not None:
            self._ctx_pct = context
        self._repaint()

    # kept as an alias so callers can use the familiar name
    update_status = update_state

    # ── render ──────────────────────────────────────────────────────────────
    def _lead(self) -> Text:
        t = Text(" ", no_wrap=True)
        if self._busy:
            verb = self._label or textkit.rotating(textkit.THINK_VERBS, self._tick // 3)
            t.append(f"{verb}… ", style=Style(color=COLORS["accent"], bold=True))
            if self._started is not None:
                t.append(textkit.format_elapsed(monotonic() - self._started),
                         style=Style(color=COLORS["dim"]))
        else:
            if self._idle_at is not None:
                t.append(f"{GLYPHS['ok']} ", style=Style(color=COLORS["ok"]))
                t.append(textkit.format_elapsed(monotonic() - self._idle_at),
                         style=Style(color=COLORS["dim"]))
            else:
                t.append("ready", style=Style(color=COLORS["dim"]))
        return t

    def _segments(self) -> list[Text]:
        """Tail segments in *descending* priority (first survives longest)."""
        segs: list[Text] = []
        if self._model:
            segs.append(Text(self._model, style=Style(color=COLORS["dim"])))
        if self._energy is not None and self._max_energy:
            e = Text()
            e.append(GLYPHS["energy"], style=Style(color=COLORS["accent"]))
            ratio = self._energy / self._max_energy if self._max_energy else 0
            tok = "ok" if ratio > 0.5 else "warn" if ratio > 0.25 else "danger"
            e.append(f"{self._energy}/{self._max_energy}", style=Style(color=COLORS[tok]))
            segs.append(e)
        if self._tools:
            segs.append(Text(f"⚙ {self._tools}", style=Style(color=COLORS["teal"])))
        if self._mood:
            segs.append(Text(self._mood, style=Style(color=COLORS["teal"])))
        if self._ctx_pct is not None:
            segs.append(Text(f"ctx {self._ctx_pct:.0f}%", style=Style(color=COLORS["dim"])))
        return segs

    def _build(self) -> Text:
        width = self._width
        sep = Text(f" {GLYPHS['sep']} ", style=Style(color=COLORS["muted"]))
        out = self._lead()
        for seg in self._segments():
            if out.cell_len + sep.cell_len + seg.cell_len + 1 > width:
                break
            out.append_text(sep)
            out.append_text(seg)
        return out

    def _repaint(self) -> None:
        self.update(self._build())
