"""
Substrate-change visibility for self-authored capability (#93, #99).

When the agent grows herself a new tool or skill, the change is journaled
(`record_change('self_extension', ...)`) and a first-person notice is
pinned to the operator's web inbox — the operator always sees what she
grew. Both writes are advisory: a failure logs loudly and never blocks
the authoring act itself.
"""

from __future__ import annotations

import json
import logging
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)


async def record_self_extension(
    pool: "asyncpg.Pool",
    *,
    summary: str,
    notice: str,
    detail: dict[str, Any] | None = None,
) -> None:
    """Journal a self-extension change and post a web-inbox notice.

    `summary` is the operator-facing journal line; `notice` is the
    first-person inbox message; `detail` lands in the journal row's JSONB.
    """
    try:
        async with pool.acquire() as conn:
            await conn.fetchval(
                "SELECT record_change('self_extension', $1, $2::jsonb)",
                summary,
                json.dumps(detail or {}),
            )
            await conn.fetchval(
                """
                SELECT queue_outbox_message(
                    $1, 'self_extension', 'tool', '{"mode": "web_inbox"}'::jsonb)
                """,
                notice,
            )
    except Exception:
        logger.warning(
            "Self-extension visibility failed (the change itself still applied): %s",
            summary,
            exc_info=True,
        )
