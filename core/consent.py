"""Consent — DB-backed access layer.

The `consent_log` table plus `config('agent.consent_status')` are the **single source
of truth** for consent. They are written during `hexis init` (the `sign_consent` tool
-> `init_consent()` -> `record_consent_response()` SQL functions) and read via
`get_agent_consent_status()`; the heartbeat/worker/API and `hexis doctor`/`consents`
all consult the DB. This module is the thin async wrapper over those SQL functions.

(The former filesystem certificate store under ~/.hexis/consents/ was a redundant
parallel universe the runtime never read — it caused `hexis doctor` to contradict a
successful `init` — and has been removed in favor of this one DB source of truth.)
"""
from __future__ import annotations

import json
from typing import Any


async def get_consent_status(conn) -> str | None:
    """Latest consent decision for the active model ('consent'/'decline'/'abstain'),
    via `get_agent_consent_status()` (which falls back to config('agent.consent_status'))."""
    try:
        status = await conn.fetchval("SELECT get_agent_consent_status()")
    except Exception:
        return None
    return status if isinstance(status, str) else None


async def is_consent_granted(conn) -> bool:
    status = await get_consent_status(conn)
    return isinstance(status, str) and status.strip().lower() == "consent"


async def record_consent_response(conn, payload: dict[str, Any]) -> dict[str, Any]:
    """Record a consent decision in `consent_log` (and, when the payload asks, mirror
    it into the config keys) via the DB `record_consent_response()` function."""
    raw = await conn.fetchval("SELECT record_consent_response($1::jsonb)", json.dumps(payload))
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            raw = {}
    return raw if isinstance(raw, dict) else {}
