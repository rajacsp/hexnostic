"""Source-chunk maintenance: deferred embedding of durable document chunks.

Chunks are written at ingest time with embedding_status='pending'; this step
(mirroring the RecMem embed queue) claims a batch and embeds in-DB via
get_embedding, so ingestion never blocks on the embedding sidecar and search
degrades to lexical until embeddings land.
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger("source_chunks")


def _coerce_json(val: Any) -> Any:
    if isinstance(val, str):
        try:
            return json.loads(val)
        except Exception:
            return val
    return val


async def run_source_chunk_embed_step(conn) -> dict[str, Any]:
    """Claim and embed one batch of pending source-document chunks."""
    batch_size = await conn.fetchval(
        "SELECT COALESCE(get_config_int('memory.source_chunk_embed_batch_size'), 32)"
    )
    raw = await conn.fetchval(
        "SELECT claim_source_chunks_unembedded_batch($1::int)", int(batch_size or 32)
    )
    items = _coerce_json(raw)
    if not isinstance(items, list) or not items:
        return {"skipped": True, "reason": "no_unembedded_chunks"}

    embedded = 0
    failed = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        chunk_id = item.get("chunk_id")
        content = item.get("content") or ""
        try:
            await conn.execute(
                """
                UPDATE source_document_chunks
                SET embedding = (get_embedding(ARRAY[$2::text]))[1],
                    embedded_at = CURRENT_TIMESTAMP,
                    embedding_status = 'embedded',
                    embedding_model = COALESCE(get_config_text('embedding.model_id'), embedding_model),
                    embedding_claimed_at = NULL,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = $1::uuid
                  AND embedding_status = 'in_progress'
                """,
                str(chunk_id),
                content,
            )
            embedded += 1
        except Exception as exc:
            failed += 1
            await conn.fetchval(
                "SELECT fail_source_chunk_embedding($1::uuid, $2::text)",
                str(chunk_id),
                str(exc),
            )

    return {"claimed": len(items), "embedded": embedded, "failed": failed}
