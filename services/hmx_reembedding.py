"""Bounded maintenance step for accepted HMX memory embeddings."""

from __future__ import annotations

import json
from typing import Any


def _coerce_json(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


async def run_hmx_reembed_step(conn) -> dict[str, Any]:
    """Claim and embed one HMX batch, retaining actionable retry state on failure."""

    raw = await conn.fetchval("SELECT hmx_claim_reembed_batch()")
    items = _coerce_json(raw)
    if not isinstance(items, list) or not items:
        return {"skipped": True, "reason": "no_pending_hmx_embeddings"}

    memory_ids = [
        str(item["memory_id"])
        for item in items
        if isinstance(item, dict) and item.get("memory_id")
    ]
    if not memory_ids:
        return {"skipped": True, "reason": "empty_hmx_embedding_claim"}

    try:
        async with conn.transaction():
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT hmx_apply_reembed_batch($1::uuid[])", memory_ids
                )
            )
    except Exception as exc:
        failures = []
        for memory_id in memory_ids:
            failure = _coerce_json(
                await conn.fetchval(
                    "SELECT hmx_fail_reembed($1::uuid, $2::text)",
                    memory_id,
                    str(exc),
                )
            )
            failures.append(failure)
        return {
            "claimed": len(memory_ids),
            "embedded": 0,
            "failed": len(memory_ids),
            "error": str(exc),
            "failures": failures,
        }

    output = dict(result) if isinstance(result, dict) else {}
    output.update({"claimed": len(memory_ids), "failed": 0})
    return output
