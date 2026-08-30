"""
Hexis Tools - Humanizer / Output Quality (L.1-L.2)

Tool handler for detecting and removing AI writing patterns from text.
Combines rule-based pattern detection with optional LLM rewriting.
"""

from __future__ import annotations

import logging
from typing import Any

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Detection is DB-owned: ai_writing_patterns + humanize_detect() (db/70).
# ---------------------------------------------------------------------------


async def humanize_detect_db(pool: Any, text: str) -> dict[str, Any]:
    """Run pattern detection + scoring via humanize_detect() in the DB."""
    import json

    async with pool.acquire() as conn:
        raw = await conn.fetchval("SELECT humanize_detect($1)", text)
    return json.loads(raw) if isinstance(raw, str) else (raw or {})


class HumanizeTextHandler(ToolHandler):
    """Detect and optionally rewrite AI writing patterns in text."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="humanize_text",
            description=(
                "Analyze text for AI writing patterns (em dashes, formulaic transitions, "
                "'delve', etc.) and optionally rewrite to sound more natural. "
                "Returns pattern detections, AI-ness score, and rewritten text if requested."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "The text to analyze and optionally humanize.",
                    },
                    "rewrite": {
                        "type": "boolean",
                        "description": "If true, produce a rewritten version with AI patterns removed. Uses an LLM pass.",
                    },
                },
                "required": ["text"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        text = arguments.get("text", "")
        do_rewrite = arguments.get("rewrite", False)

        if not text.strip():
            return ToolResult.error_result("No text provided")
        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Pattern detection requires a database-backed registry (humanize_detect)",
                ToolErrorType.MISSING_CONFIG,
            )

        doc = await humanize_detect_db(pool, text)
        detections = doc.get("detections") or []

        result: dict[str, Any] = {
            "ai_score": doc.get("ai_score", 0.0),
            "pattern_count": doc.get("pattern_count", len(detections)),
            "total_hits": doc.get("total_hits", 0),
            "detections": detections,
        }

        # Optional LLM rewrite
        if do_rewrite and detections:
            try:
                rewritten = await self._rewrite_text(text, detections, pool)
                if rewritten:
                    result["rewritten"] = rewritten
                    # Re-score the rewritten version
                    result["rewritten_ai_score"] = (
                        await humanize_detect_db(pool, rewritten)
                    ).get("ai_score", 0.0)
            except Exception as e:
                result["rewrite_error"] = str(e)

        return ToolResult.success_result(result)

    async def _rewrite_text(
        self, text: str, detections: list[dict[str, Any]], pool: Any
    ) -> str | None:
        """Use an LLM to rewrite text removing detected AI patterns."""
        from core.llm import chat_completion
        from core.llm_config import load_llm_config

        pattern_list = "\n".join(
            f"- {d['pattern']}: {d['suggestion']}" for d in detections[:10]
        )

        prompt = (
            "Rewrite the following text to sound more natural and human. "
            "Remove the detected AI writing patterns listed below. "
            "Preserve the original meaning and tone. Do NOT add new content. "
            "Return ONLY the rewritten text, nothing else.\n\n"
            f"Detected AI patterns to fix:\n{pattern_list}\n\n"
            f"Original text:\n{text}"
        )

        try:
            llm_config = await load_llm_config(pool, preference="cheap")
        except Exception:
            llm_config = await load_llm_config(pool)

        response = await chat_completion(
            messages=[{"role": "user", "content": prompt}],
            **llm_config,
        )

        if response and response.get("content"):
            content = response["content"]
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        return block["text"]
            elif isinstance(content, str):
                return content

        return None


# ---------------------------------------------------------------------------
# L.1: Output Post-Processor Hook
# ---------------------------------------------------------------------------


class PostProcessOutputHandler(ToolHandler):
    """Apply output post-processing pipeline to text before delivery."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="post_process_output",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Apply configured output post-processing transformations to text. "
                "Runs the humanizer and any other configured processors. "
                "Use this before delivering important content to channels."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "Text to post-process.",
                    },
                    "processors": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Processors to apply. Options: 'humanizer'. Defaults to all enabled processors.",
                    },
                },
                "required": ["text"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=True,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        text = arguments.get("text", "")
        processors = arguments.get("processors", ["humanizer"])

        if not text.strip():
            return ToolResult.error_result("No text provided")

        result_text = text
        applied = []

        pool = context.registry.pool if context.registry else None
        if pool is None:
            return ToolResult.error_result(
                "Post-processing requires a database-backed registry (humanize_detect)",
                ToolErrorType.MISSING_CONFIG,
            )

        for proc in processors:
            if proc == "humanizer":
                doc = await humanize_detect_db(pool, result_text)
                detections = doc.get("detections") or []
                score = doc.get("ai_score", 0.0)

                if detections and score > 0.3:
                    # Only rewrite if score is meaningfully high
                    if pool:
                        try:
                            handler = HumanizeTextHandler()
                            rewritten = await handler._rewrite_text(result_text, detections, pool)
                            if rewritten:
                                result_text = rewritten
                                applied.append({
                                    "processor": "humanizer",
                                    "original_score": score,
                                    "patterns_found": len(detections),
                                })
                        except Exception as e:
                            applied.append({
                                "processor": "humanizer",
                                "error": str(e),
                            })
                else:
                    applied.append({
                        "processor": "humanizer",
                        "skipped": True,
                        "reason": "score too low" if not detections else "no patterns found",
                        "score": score,
                    })

        return ToolResult.success_result({
            "text": result_text,
            "processors_applied": applied,
        })


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def create_humanizer_tools() -> list[ToolHandler]:
    """Create humanizer and output post-processing tool handlers."""
    return [
        HumanizeTextHandler(),
        PostProcessOutputHandler(),
    ]
