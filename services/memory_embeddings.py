"""Durable-memory embedding maintenance.

Memory rows are written with embedding_status='pending' and embedded by the
maintenance worker. This keeps durable memory creation ACID-local and lets
recall degrade until vectors arrive instead of failing the write path.
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger("memory_embeddings")


def _coerce_json(val: Any) -> Any:
    if isinstance(val, str):
        try:
            return json.loads(val)
        except Exception:
            return val
    return val


async def run_memory_embed_step(conn) -> dict[str, Any]:
    """Claim and embed one batch of pending durable memories."""
    batch_size = await conn.fetchval(
        "SELECT COALESCE(get_config_int('memory.memory_embed_batch_size'), 32)"
    )
    raw = await conn.fetchval(
        "SELECT claim_memories_unembedded_batch($1::int)", int(batch_size or 32)
    )
    items = _coerce_json(raw)
    if not isinstance(items, list) or not items:
        return {"skipped": True, "reason": "no_unembedded_memories"}

    embedded = 0
    failed = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        memory_id = item.get("memory_id")
        content = item.get("content") or ""
        try:
            await conn.execute(
                """
                UPDATE memories
                SET embedding = (get_embedding(ARRAY[$2::text]))[1],
                    embedded_at = CURRENT_TIMESTAMP,
                    embedding_status = 'embedded',
                    embedding_model = COALESCE(get_config_text('embedding.model_id'), embedding_model),
                    embedding_claimed_at = NULL,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = $1::uuid
                  AND embedding_status = 'in_progress'
                """,
                str(memory_id),
                content,
            )
            embedded += 1
        except Exception as exc:
            failed += 1
            logger.debug("memory embedding failed for %s", memory_id, exc_info=True)
            await conn.fetchval(
                "SELECT fail_memory_embedding($1::uuid, $2::text)",
                str(memory_id),
                str(exc),
            )

    return {"claimed": len(items), "embedded": embedded, "failed": failed}
