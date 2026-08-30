"""Reusable modal dialogs for the Hexis TUI."""
from __future__ import annotations

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Label, Static


class ConfirmDialog(ModalScreen[bool]):
    """Yes/No confirmation dialog."""

    def __init__(self, title: str, body: str) -> None:
        super().__init__()
        self._title = title
        self._body = body

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self._title, classes="dialog-title")
            yield Static(Text(self._body), classes="dialog-body")
            with Horizontal(classes="dialog-buttons"):
                yield Button("Yes", variant="success", id="yes")
                yield Button("No", variant="error", id="no")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class ErrorDialog(ModalScreen[bool]):
    """Error dialog. Returns True only when the user chooses Retry.

    Body is rendered as Rich ``Text`` so error strings containing brackets
    (paths, tracebacks) never trip markup parsing.
    """

    def __init__(self, title: str, body: str, retry_label: str | None = None) -> None:
        super().__init__()
        self._title = title
        self._body = body
        self._retry_label = retry_label

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self._title, classes="dialog-title")
            yield Static(Text(self._body), classes="dialog-body")
            with Horizontal(classes="dialog-buttons"):
                if self._retry_label:
                    yield Button(self._retry_label, variant="primary", id="retry")
                    yield Button("Quit", variant="error", id="quit")
                else:
                    yield Button("OK", variant="primary", id="ok")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "retry")
