"""Heartbeat decision prompt — rendered by the database.

The prompt is assembled entirely in the DB by render_heartbeat_decision_prompt
(db/39_functions_prompt_render.sql) from the DB-produced heartbeat context
(gather_turn_context). The former Python byte-parity fork of the renderer was
deleted; the golden fixtures in tests/fixtures/prompt_render/ pin the rendered
output (tests/db/test_prompt_render.py).
"""

from __future__ import annotations

import json
from typing import Any


async def render_heartbeat_decision_prompt_db(conn: Any, context: dict[str, Any]) -> str:
    """Render the heartbeat decision prompt in the DB."""
    return await conn.fetchval(
        "SELECT render_heartbeat_decision_prompt($1::jsonb)", json.dumps(context)
    )
