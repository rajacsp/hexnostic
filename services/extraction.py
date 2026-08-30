"""Conscious-episode memory formation (#37): the subconscious observer.

Sweeps unprocessed conscious episodes (conversation turns + heartbeat episodes
in ``subconscious_units``) and selectively encodes durable memories: claim a
batch → one ``chat_json`` extraction pass → ``apply_conscious_extraction``
(routes facts through the ingest dedup/corroborate policy) or
``fail_conscious_extraction``. Mirrors ``services/summarization.py``
(claim → chat_json → apply/fail). Gated by config ``extraction.enabled``.
"""
from __future__ import annotations

import json
import logging
from typing import Any

from core.llm_config import load_llm_config
from core.llm_json import chat_json

logger = logging.getLogger("extraction")

_UNIT_TEXT_BUDGET = 3000


def _format_unit(row: Any) -> str:
    metadata = row["metadata"]
    if isinstance(metadata, str):
        try:
            metadata = json.loads(metadata)
        except (TypeError, ValueError):
            metadata = {}
    kind = (metadata or {}).get("kind", "conversation_turn")
    return (
        f"episode id: {row['id']}\n"
        f"kind: {kind}\n"
        f"speaker/source: {row['source_identity'] or 'user'}\n"
        f"at: {row['turn_at']}\n"
        f"content:\n{(row['content'] or '')[:_UNIT_TEXT_BUDGET]}"
    )


async def run_conscious_extraction_step(conn) -> dict[str, Any]:
    """Claim and extract one batch of conscious episodes."""
    enabled = await conn.fetchval(
        "SELECT COALESCE(get_config_bool('extraction.enabled'), false)"
    )
    if not enabled:
        return {"skipped": True, "reason": "disabled"}

    rows = await conn.fetch("SELECT * FROM claim_conscious_extraction_batch()")
    if not rows:
        return {"skipped": True, "reason": "no_pending_units"}
    unit_ids = [str(row["id"]) for row in rows]

    try:
        llm_config = await load_llm_config(conn, "llm.extraction", fallback_key="llm.subconscious")
        system = await conn.fetchval(
            "SELECT content FROM prompt_modules WHERE key = 'conscious_extraction'"
        )
        # The extractor knows who "I" is and who the user is (#56/#82) — the
        # DB's label resolution, so facts carry real names and a first-person
        # self.
        labels_raw = await conn.fetchval("SELECT get_turn_labels()")
        labels = json.loads(labels_raw) if isinstance(labels_raw, str) else (labels_raw or {})
        naming = (
            f"You are {labels.get('agent_label', 'Assistant')}. "
            f"The user in these conversations is {labels.get('user_label', 'User')}."
        )
        user_payload = naming + "\n\n---\n\n" + "\n\n---\n\n".join(_format_unit(row) for row in rows)
        doc, _raw = await chat_json(
            llm_config=llm_config,
            messages=[
                {"role": "system", "content": (system or "").strip()},
                {"role": "user", "content": user_payload},
            ],
            max_tokens=1500,
            temperature=0.2,
            response_format={"type": "json_object"},
            fallback={"facts": []},
        )
        facts = doc.get("facts") if isinstance(doc, dict) else []
        if not isinstance(facts, list):
            facts = []
        raw_result = await conn.fetchval(
            "SELECT apply_conscious_extraction($1::uuid[], $2::jsonb)",
            unit_ids,
            json.dumps(facts),
        )
        result = json.loads(raw_result) if isinstance(raw_result, str) else (raw_result or {})
        return {"skipped": False, **result}
    except Exception as exc:
        logger.error("conscious extraction failed for %d units: %s", len(unit_ids), exc)
        try:
            await conn.fetchval(
                "SELECT fail_conscious_extraction($1::uuid[], $2::text)",
                unit_ids,
                str(exc),
            )
        except Exception:
            logger.exception("could not record extraction failure")
        return {"skipped": False, "failed_units": len(unit_ids), "error": str(exc)}
