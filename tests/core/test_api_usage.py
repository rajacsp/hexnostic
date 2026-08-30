"""Tests for H.1–H.3: API usage tracking (table, LLM recording, embedding recording)."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.usage import (
    extract_usage,
    record_usage,
    record_llm_usage,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ---------------------------------------------------------------------------
# H.1  —  api_usage table + SQL functions
# ---------------------------------------------------------------------------


class TestApiUsageTable:
    """Verify the api_usage table and SQL functions."""

    async def test_record_api_usage_inserts(self, db_pool):
        """record_api_usage() inserts a row and returns the id."""
        row_id = await db_pool.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            "anthropic",            # provider
            "claude-opus-4-6",      # model
            "chat",                 # operation
            1000,                   # input_tokens
            500,                    # output_tokens
            200,                    # cache_read_tokens
            0,                      # cache_write_tokens
            0.025,                  # cost_usd
            "test-session",         # session_key
            "chat",                 # source
            "{}",                   # metadata
        )
        assert row_id is not None
        assert isinstance(row_id, int)

    async def test_total_tokens_computed(self, db_pool):
        """total_tokens column is auto-computed from the four token fields."""
        row_id = await db_pool.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7)",
            "openai", "gpt-4o", "chat", 100, 200, 50, 25,
        )
        row = await db_pool.fetchrow(
            "SELECT total_tokens FROM api_usage WHERE id = $1", row_id,
        )
        assert row["total_tokens"] == 100 + 200 + 50 + 25

    async def test_usage_summary(self, db_pool):
        """usage_summary() aggregates by provider/model/operation."""
        # Insert some data
        for _ in range(3):
            await db_pool.fetchval(
                "SELECT record_api_usage($1,$2,$3,$4,$5)",
                "anthropic", "claude-opus-4-6", "chat", 100, 50,
            )
        rows = await db_pool.fetch(
            "SELECT * FROM usage_summary('1 hour'::interval)",
        )
        assert len(rows) > 0
        anthro_rows = [r for r in rows if r["provider"] == "anthropic" and r["model"] == "claude-opus-4-6"]
        assert len(anthro_rows) > 0
        assert anthro_rows[0]["call_count"] >= 3
        assert anthro_rows[0]["total_input_tokens"] >= 300

    async def test_usage_daily(self, db_pool):
        """usage_daily() returns per-day breakdowns."""
        await db_pool.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7,$8)",
            "gemini", "gemini-2.5-flash", "chat", 500, 200, 0, 0, 0.001,
        )
        rows = await db_pool.fetch(
            "SELECT * FROM usage_daily('1 hour'::interval)",
        )
        assert len(rows) > 0

    async def test_usage_summary_source_filter(self, db_pool):
        """usage_summary() can filter by source."""
        await db_pool.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
            "openai", "gpt-4o", "chat", 100, 50, 0, 0, None, None, "heartbeat",
        )
        rows = await db_pool.fetch(
            "SELECT * FROM usage_summary('1 hour'::interval, 'heartbeat')",
        )
        hb_rows = [r for r in rows if r["provider"] == "openai"]
        assert len(hb_rows) > 0

    async def test_usage_cleanup(self, db_pool):
        """usage_cleanup() removes old entries."""
        # Insert with a forced old timestamp
        await db_pool.execute(
            """
            INSERT INTO api_usage (provider, model, operation, input_tokens, output_tokens, created_at)
            VALUES ('test-provider', 'test-model', 'chat', 10, 10, now() - '100 days'::interval)
            """,
        )
        count = await db_pool.fetchval("SELECT usage_cleanup('90 days'::interval)")
        assert count >= 1


# ---------------------------------------------------------------------------
# H.2  —  Usage extraction + cost estimation (Python)
# ---------------------------------------------------------------------------


class TestUsageExtraction:
    """Test extract_usage() for various provider response formats."""

    def test_anthropic_response(self):
        """Extract usage from an Anthropic Messages response."""
        raw = MagicMock()
        raw.usage = MagicMock()
        raw.usage.input_tokens = 1500
        raw.usage.output_tokens = 300
        raw.usage.cache_read_input_tokens = 200
        raw.usage.cache_creation_input_tokens = 100
        result = extract_usage("anthropic", raw)
        assert result["input_tokens"] == 1500
        assert result["output_tokens"] == 300
        assert result["cache_read_tokens"] == 200
        assert result["cache_write_tokens"] == 100

    def test_openai_response(self):
        """Extract usage from an OpenAI Chat Completions response."""
        raw = MagicMock()
        raw.usage = MagicMock()
        raw.usage.prompt_tokens = 800
        raw.usage.completion_tokens = 200
        raw.usage.prompt_tokens_details = MagicMock()
        raw.usage.prompt_tokens_details.cached_tokens = 100
        # Remove input_tokens to force OpenAI path
        del raw.usage.input_tokens
        result = extract_usage("openai", raw)
        assert result["input_tokens"] == 800
        assert result["output_tokens"] == 200
        assert result["cache_read_tokens"] == 100

    def test_gemini_response(self):
        """Extract usage from a Gemini response."""
        raw = MagicMock(spec=[])
        raw.usage_metadata = MagicMock()
        raw.usage_metadata.prompt_token_count = 600
        raw.usage_metadata.candidates_token_count = 150
        raw.usage_metadata.cached_content_token_count = 0
        result = extract_usage("gemini", raw)
        assert result["input_tokens"] == 600
        assert result["output_tokens"] == 150

    def test_none_response(self):
        """Returns zeros for None response (e.g. streaming without raw)."""
        result = extract_usage("any", None)
        assert result == {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        }

    def test_dict_response(self):
        """Extract usage from dict-style responses."""
        raw = {"usage": {"input_tokens": 400, "output_tokens": 100}}
        result = extract_usage("generic", raw)
        assert result["input_tokens"] == 400
        assert result["output_tokens"] == 100


class TestCostEstimation:
    """estimate_api_cost() (SQL, model_costs table) — the price list is data."""

    async def _cost(self, db_pool, model, inp, out, cache_read=0, cache_write=0):
        async with db_pool.acquire() as conn:
            value = await conn.fetchval(
                "SELECT estimate_api_cost($1, $2, $3, $4, $5)",
                model, inp, out, cache_read, cache_write,
            )
        return float(value) if value is not None else None

    async def test_claude_opus(self, db_pool):
        cost = await self._cost(db_pool, "claude-opus-4-6", 1_000_000, 100_000)
        # input: 1M * 15 / 1M = 15, output: 100K * 75 / 1M = 7.5
        assert cost is not None
        assert abs(cost - 22.5) < 0.01

    async def test_gpt4o(self, db_pool):
        cost = await self._cost(db_pool, "gpt-4o", 1_000_000, 100_000)
        # input: 1M * 2.5 / 1M = 2.5, output: 100K * 10 / 1M = 1.0
        assert cost is not None
        assert abs(cost - 3.5) < 0.01

    async def test_unknown_model(self, db_pool):
        """Unknown local models price NULL."""
        assert await self._cost(db_pool, "llama3.2:latest", 1000, 500) is None

    async def test_partial_match(self, db_pool):
        """Model ids with date suffixes match via longest prefix."""
        cost = await self._cost(db_pool, "claude-sonnet-4-5-20250929-v2", 1000, 500)
        assert cost is not None

    async def test_cache_tokens(self, db_pool):
        cost_no_cache = await self._cost(db_pool, "claude-opus-4-6", 1000, 500)
        cost_with_cache = await self._cost(
            db_pool, "claude-opus-4-6", 1000, 500, cache_read=500
        )
        assert cost_no_cache is not None
        assert cost_with_cache is not None
        assert cost_with_cache > cost_no_cache

    async def test_record_api_usage_self_costs(self, db_pool):
        """A NULL caller cost is filled from the price table at insert."""
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                row_id = await conn.fetchval(
                    "SELECT record_api_usage('anthropic', 'claude-opus-4-6', 'chat', 1000000, 100000)"
                )
                cost = await conn.fetchval(
                    "SELECT cost_usd FROM api_usage WHERE id = $1", row_id
                )
                assert abs(float(cost) - 22.5) < 0.01
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# H.2  —  Usage extraction + cost estimation (Python)
# ---------------------------------------------------------------------------


class TestUsageExtraction:
    """Test extract_usage() for various provider response formats."""

    def test_anthropic_response(self):
        """Extract usage from an Anthropic Messages response."""
        raw = MagicMock()
        raw.usage = MagicMock()
        raw.usage.input_tokens = 1500
        raw.usage.output_tokens = 300
        raw.usage.cache_read_input_tokens = 200
        raw.usage.cache_creation_input_tokens = 100
        result = extract_usage("anthropic", raw)
        assert result["input_tokens"] == 1500
        assert result["output_tokens"] == 300
        assert result["cache_read_tokens"] == 200
        assert result["cache_write_tokens"] == 100

    def test_openai_response(self):
        """Extract usage from an OpenAI Chat Completions response."""
        raw = MagicMock()
        raw.usage = MagicMock()
        raw.usage.prompt_tokens = 800
        raw.usage.completion_tokens = 200
        raw.usage.prompt_tokens_details = MagicMock()
        raw.usage.prompt_tokens_details.cached_tokens = 100
        # Remove input_tokens to force OpenAI path
        del raw.usage.input_tokens
        result = extract_usage("openai", raw)
        assert result["input_tokens"] == 800
        assert result["output_tokens"] == 200
        assert result["cache_read_tokens"] == 100

    def test_gemini_response(self):
        """Extract usage from a Gemini response."""
        raw = MagicMock(spec=[])
        raw.usage_metadata = MagicMock()
        raw.usage_metadata.prompt_token_count = 600
        raw.usage_metadata.candidates_token_count = 150
        raw.usage_metadata.cached_content_token_count = 0
        result = extract_usage("gemini", raw)
        assert result["input_tokens"] == 600
        assert result["output_tokens"] == 150

    def test_none_response(self):
        """Returns zeros for None response (e.g. streaming without raw)."""
        result = extract_usage("any", None)
        assert result == {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        }

    def test_dict_response(self):
        """Extract usage from dict-style responses."""
        raw = {"usage": {"input_tokens": 400, "output_tokens": 100}}
        result = extract_usage("generic", raw)
        assert result["input_tokens"] == 400
        assert result["output_tokens"] == 100


# ---------------------------------------------------------------------------
# H.2  —  record_usage() and record_llm_usage() (Python → DB)
# ---------------------------------------------------------------------------


class TestRecordUsage:
    """Test the Python recording functions write to DB."""

    async def test_record_usage_with_pool(self, db_pool):
        """record_usage() inserts into api_usage when pool is provided."""
        await record_usage(
            provider="test-provider",
            model="test-model",
            operation="chat",
            input_tokens=100,
            output_tokens=50,
            session_key="test-session-py",
            source="test",
            pool=db_pool,
        )
        row = await db_pool.fetchrow(
            "SELECT * FROM api_usage WHERE session_key = 'test-session-py' ORDER BY id DESC LIMIT 1",
        )
        assert row is not None
        assert row["provider"] == "test-provider"
        assert row["input_tokens"] == 100
        assert row["output_tokens"] == 50

    async def test_record_usage_auto_cost(self, db_pool):
        """record_usage() auto-estimates cost when not provided."""
        await record_usage(
            provider="anthropic",
            model="claude-opus-4-6",
            input_tokens=1000,
            output_tokens=500,
            session_key="test-auto-cost",
            pool=db_pool,
        )
        row = await db_pool.fetchrow(
            "SELECT cost_usd FROM api_usage WHERE session_key = 'test-auto-cost' ORDER BY id DESC LIMIT 1",
        )
        assert row is not None
        assert row["cost_usd"] is not None
        assert float(row["cost_usd"]) > 0

    async def test_record_usage_no_pool_no_error(self):
        """record_usage() silently does nothing when no pool is available."""
        # Should not raise even with no pool
        await record_usage(
            provider="test",
            model="test",
            pool=None,
        )

    async def test_record_llm_usage_anthropic(self, db_pool):
        """record_llm_usage() extracts from Anthropic response and records."""
        raw = MagicMock()
        raw.usage = MagicMock()
        raw.usage.input_tokens = 2000
        raw.usage.output_tokens = 400
        raw.usage.cache_read_input_tokens = 0
        raw.usage.cache_creation_input_tokens = 0

        await record_llm_usage(
            provider="anthropic",
            model="claude-opus-4-6",
            raw_response=raw,
            session_key="test-llm-anthropic",
            source="chat",
            pool=db_pool,
        )
        row = await db_pool.fetchrow(
            "SELECT * FROM api_usage WHERE session_key = 'test-llm-anthropic' ORDER BY id DESC LIMIT 1",
        )
        assert row is not None
        assert row["input_tokens"] == 2000
        assert row["output_tokens"] == 400
        assert row["provider"] == "anthropic"
