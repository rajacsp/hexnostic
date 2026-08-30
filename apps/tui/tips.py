"""Ambient feature-discovery tips shown at chat startup.

Mirrors hermes-agent's tips corpus / openclaw's "what now" hints: a rotating
one-liner surfaces a feature the user might not have discovered, without a
blocking tutorial.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

# Show-once flags persisted locally (survive DB resets; no round-trip).
_SEEN_PATH = Path.home() / ".hexis" / "onboarding_seen.json"


def seen(flag: str) -> bool:
    try:
        return bool(json.loads(_SEEN_PATH.read_text()).get(flag))
    except Exception:
        return False


def mark_seen(flag: str) -> None:
    try:
        _SEEN_PATH.parent.mkdir(parents=True, exist_ok=True)
        data = json.loads(_SEEN_PATH.read_text()) if _SEEN_PATH.exists() else {}
        data[flag] = True
        _SEEN_PATH.write_text(json.dumps(data))
    except Exception:
        pass

# Kept surface-agnostic: every tip is true in both the line-based CLI and the
# (legacy) Textual TUI. Don't add TUI-only keybindings (Ctrl+T, PageUp) here —
# the CLI REPL surfaces these too and must not advertise controls it lacks.
TIPS: list[str] = [
    "Type /help to see commands — try /recall <topic> to search memories.",
    "Ctrl+C interrupts a running reply; press it again (or /quit) to exit.",
    "/status shows energy, mood, and consent at a glance.",
    "/tools lists everything the agent can do right now.",
    "The agent remembers across sessions; it forms memories after each turn.",
    "`hexis up` starts the heartbeat and memory maintenance workers.",
    "Run `hexis doctor --llm` to verify your model connection.",
    "Re-run `hexis init` any time to reconfigure — it won't wipe anything unasked.",
]


def random_tip() -> str:
    return "Tip: " + random.choice(TIPS)
