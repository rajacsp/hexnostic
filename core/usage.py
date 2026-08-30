"""API usage tracking.

Records every LLM and embedding API call to the ``api_usage`` table for
cost analysis and budgeting.  Modelled after OpenClaw's provider-usage
system but backed by Postgres.

Usage recording is **fire-and-forget** — errors are logged but never
propagated so that a tracking failure can't break a chat or heartbeat.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Usage extraction from raw provider responses
# ---------------------------------------------------------------------------


def extract_usage(provider: str, raw: Any) -> dict[str, int]:
    """Extract token counts from a provider's raw response object.

    Returns a dict with keys: input_tokens, output_tokens,
    cache_read_tokens, cache_write_tokens.
    """
    result = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
    }

    if raw is None:
        return result

    # Anthropic Messages API
    if hasattr(raw, "usage"):
        usage = raw.usage
        if hasattr(usage, "input_tokens"):
            result["input_tokens"] = getattr(usage, "input_tokens", 0) or 0
            result["output_tokens"] = getattr(usage, "output_tokens", 0) or 0
            result["cache_read_tokens"] = getattr(usage, "cache_read_input_tokens", 0) or 0
            result["cache_write_tokens"] = getattr(usage, "cache_creation_input_tokens", 0) or 0
            return result
        # OpenAI Chat Completions
        if hasattr(usage, "prompt_tokens"):
            result["input_tokens"] = getattr(usage, "prompt_tokens", 0) or 0
            result["output_tokens"] = getattr(usage, "completion_tokens", 0) or 0
            # OpenAI caching (prompt_tokens_details)
            details = getattr(usage, "prompt_tokens_details", None)
            if details:
                result["cache_read_tokens"] = getattr(details, "cached_tokens", 0) or 0
            return result

    # Gemini
    if hasattr(raw, "usage_metadata"):
        meta = raw.usage_metadata
        result["input_tokens"] = getattr(meta, "prompt_token_count", 0) or 0
        result["output_tokens"] = getattr(meta, "candidates_token_count", 0) or 0
        result["cache_read_tokens"] = getattr(meta, "cached_content_token_count", 0) or 0
        return result

    # Dict-style responses (some providers return dicts)
    if isinstance(raw, dict):
        usage = raw.get("usage", {})
        if isinstance(usage, dict):
            result["input_tokens"] = usage.get("input_tokens") or usage.get("prompt_tokens") or 0
            result["output_tokens"] = usage.get("output_tokens") or usage.get("completion_tokens") or 0
            result["cache_read_tokens"] = usage.get("cache_read_input_tokens") or usage.get("cached_tokens") or 0
            result["cache_write_tokens"] = usage.get("cache_creation_input_tokens") or 0
            return result

    return result


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

# Module-level pool reference — set by the application entrypoint.
_pool: asyncpg.Pool | None = None


def set_usage_pool(pool: asyncpg.Pool) -> None:
    """Set the DB pool used for usage recording.

    Called once at startup by the API server or worker.
    """
    global _pool
    _pool = pool


async def record_usage(
    *,
    provider: str,
    model: str,
    operation: str = "chat",
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
    cost_usd: float | None = None,
    session_key: str | None = None,
    source: str = "chat",
    metadata: dict[str, Any] | None = None,
    pool: asyncpg.Pool | None = None,
) -> None:
    """Fire-and-forget usage recording.

    Errors are logged but never raised.
    """
    p = pool or _pool
    if p is None:
        logger.debug("Usage pool not set — skipping recording")
        return

    # A NULL cost self-prices inside record_api_usage from the model_costs
    # table — the DB owns the price list.
    try:
        await p.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            provider,
            model,
            operation,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            cost_usd,
            session_key,
            source,
            json.dumps(metadata or {}),
        )
    except Exception:
        logger.debug("Failed to record API usage", exc_info=True)


async def record_llm_usage(
    *,
    provider: str,
    model: str,
    raw_response: Any,
    operation: str = "chat",
    session_key: str | None = None,
    source: str = "chat",
    pool: asyncpg.Pool | None = None,
) -> None:
    """Extract usage from a raw LLM response and record it."""
    usage = extract_usage(provider, raw_response)
    await record_usage(
        provider=provider,
        model=model,
        operation=operation,
        input_tokens=usage["input_tokens"],
        output_tokens=usage["output_tokens"],
        cache_read_tokens=usage["cache_read_tokens"],
        cache_write_tokens=usage["cache_write_tokens"],
        session_key=session_key,
        source=source,
        pool=pool,
    )
