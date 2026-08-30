"""Hexis Init TUI — Textual app for the init wizard."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from textual.app import App

from apps.tui.theme import hexis_theme


@dataclass
class InitState:
    """Accumulated state across wizard screens."""

    # LLM config
    provider: str = ""
    model: str = ""
    endpoint: str = ""
    api_key_env: str = ""
    sub_provider: str = ""
    sub_model: str = ""
    sub_endpoint: str = ""
    sub_key_env: str = ""

    # Path choice
    tier: str = ""  # "express" | "character" | "custom"

    # Express
    user_name: str = "User"

    # Character
    character_cards: list[dict[str, Any]] = field(default_factory=list)
    chosen_card: dict[str, Any] | None = None
    tweaked_ext: dict[str, Any] | None = None

    # Custom
    agent_name: str = "Hexis"
    pronouns: str = "they/them"
    voice: str = "thoughtful and curious"
    description: str = ""
    purpose: str = "To be helpful, to learn, and to grow as an individual."
    personality_traits: dict[str, float] | None = None
    personality_desc: str = "reflective and exploratory"
    values: list[str] = field(default_factory=lambda: ["honesty", "growth", "kindness", "wisdom", "humility"])
    worldview: dict[str, str] = field(default_factory=lambda: {
        "metaphysics": "agnostic",
        "human_nature": "mixed",
        "epistemology": "empiricist",
        "ethics": "virtue ethics",
    })
    boundaries: list[str] = field(default_factory=lambda: [
        "I will not deceive people or falsify evidence.",
        "I will avoid causing harm.",
        "I will protect privacy and sensitive information.",
        "I will be honest about uncertainty.",
    ])
    interests: list[str] = field(default_factory=lambda: ["broad curiosity across domains"])
    goals: list[str] = field(default_factory=lambda: ["Support the user and grow as an individual"])
    relationship_type: str = "partner"

    # Consent result
    consent_decision: str = ""
    consent_reasoning: str = ""
    consent_signature: str = ""
    consent_memories: list[dict[str, Any]] = field(default_factory=list)
    # When the agent refuses consent, the user can change the model and retry;
    # this flag routes the LLM screen straight back to consent (identity is
    # already persisted) instead of re-walking the whole wizard.
    retry_consent: bool = False

    # Final
    final_agent_name: str = ""

    # DB
    dsn: str = ""
    wait_seconds: int = 30


class HexisInitApp(App):
    """Textual TUI for `hexis init`."""

    TITLE = "Hexis Init"
    CSS_PATH = "hexis.tcss"
    BINDINGS = [
        ("ctrl+c", "quit_app", "Quit"),
    ]

    def __init__(self, argv: list[str] | None = None) -> None:
        super().__init__()
        self.register_theme(hexis_theme)
        self.theme = "hexis"
        self.state = InitState()
        self._argv = argv or []
        self._conn: Any = None
        # Set by the final consent screen so the CLI can hand off to chat / ui
        # after init exits: "chat" | "ui" | None.
        self.next_action: str | None = None

    def get_css_variables(self) -> dict[str, str]:
        from apps.tui.design import CSS_VARS
        variables = super().get_css_variables()
        variables.update(CSS_VARS)
        return variables

    def run(self, **kwargs):
        # Keyboard-only by default: don't capture the mouse, so the terminal's
        # native click-drag text selection / copy keeps working. Set
        # HEXIS_TUI_MOUSE=1 to re-enable mouse interaction.
        import os
        kwargs.setdefault("mouse", os.getenv("HEXIS_TUI_MOUSE", "") == "1")
        return super().run(**kwargs)

    async def on_mount(self) -> None:
        load_dotenv()
        from core.agent_api import db_dsn_from_env, ensure_schema_has_config, _connect_with_retry

        # Parse DSN / wait-seconds from forwarded argv
        dsn = None
        wait_seconds = int(os.getenv("POSTGRES_WAIT_SECONDS", "30"))
        i = 0
        while i < len(self._argv):
            if self._argv[i] == "--dsn" and i + 1 < len(self._argv):
                dsn = self._argv[i + 1]
                i += 2
            elif self._argv[i] == "--wait-seconds" and i + 1 < len(self._argv):
                wait_seconds = int(self._argv[i + 1])
                i += 2
            else:
                i += 1

        self.state.dsn = dsn or db_dsn_from_env()
        self.state.wait_seconds = wait_seconds
        await self._attempt_connect()

    async def _attempt_connect(self) -> None:
        from core.agent_api import ensure_schema_has_config, _connect_with_retry

        try:
            await ensure_schema_has_config(self.state.dsn, wait_seconds=self.state.wait_seconds)
            self._conn = await _connect_with_retry(self.state.dsn, wait_seconds=self.state.wait_seconds)
        except Exception as e:
            from apps.tui.dialogs import ErrorDialog

            def _on_choice(retry: bool | None) -> None:
                if retry:
                    self.call_later(self._attempt_connect)
                else:
                    self.exit(1)

            await self.push_screen(
                ErrorDialog("Connection Error", str(e), retry_label="Retry"), _on_choice
            )
            return

        await self._start_wizard()

    async def _start_wizard(self) -> None:
        """If an agent is already configured, offer keep-or-reconfigure first."""
        from apps.tui.init_screens import LLMConfigScreen, ReconfigureScreen

        summary: dict[str, Any] | None = None
        try:
            configured = bool(await self._conn.fetchval("SELECT is_agent_configured()"))
            if configured:
                raw = await self._conn.fetchval("SELECT get_init_profile()")
                profile = json.loads(raw) if isinstance(raw, str) else (raw or {})
                llm = await self._conn.fetchval("SELECT get_config('llm.chat')")
                llm = json.loads(llm) if isinstance(llm, str) else (llm or {})
                summary = {
                    "name": (profile.get("agent", {}) or {}).get("name", "your agent"),
                    "provider": llm.get("provider", "?"),
                    "model": llm.get("model", "?"),
                }
        except Exception:
            summary = None

        if summary is not None:
            await self.push_screen(ReconfigureScreen(summary))
        else:
            await self.push_screen(LLMConfigScreen())

    @property
    def conn(self) -> Any:
        return self._conn

    async def action_quit_app(self) -> None:
        if self._conn:
            await self._conn.close()
        self.exit(1)

    async def on_unmount(self) -> None:
        if self._conn:
            try:
                await self._conn.close()
            except Exception:
                pass
