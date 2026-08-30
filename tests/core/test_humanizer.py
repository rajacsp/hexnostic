"""Humanizer / output-quality tools (L.1-L.2).

Detection and scoring are DB-owned (ai_writing_patterns + humanize_detect,
db/70); the vectors here were byte-parity-verified against the deleted
Python implementation when the port shipped (0065).
"""

import json
from unittest.mock import MagicMock, patch

import pytest

from core.tools.humanizer import (
    HumanizeTextHandler,
    PostProcessOutputHandler,
    create_humanizer_tools,
)
from core.tools.base import ToolContext, ToolErrorType, ToolExecutionContext

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _make_context(pool=None):
    registry = MagicMock()
    registry.pool = pool
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


async def _detect(db_pool, text):
    async with db_pool.acquire() as conn:
        raw = await conn.fetchval("SELECT humanize_detect($1)", text)
    return json.loads(raw) if isinstance(raw, str) else raw


def _counts(doc):
    return {d["pattern"]: d["count"] for d in doc["detections"]}


# ============================================================================
# Factory
# ============================================================================


class TestHumanizerFactory:
    def test_factory_returns_all_handlers(self):
        tools = create_humanizer_tools()
        names = {t.spec.name for t in tools}
        assert names == {"humanize_text", "post_process_output"}

    def test_all_have_specs(self):
        for tool in create_humanizer_tools():
            assert tool.spec.name
            assert tool.spec.description


# ============================================================================
# Pattern table + detection (SQL)
# ============================================================================


class TestPatternDetection:
    async def test_pattern_table_seeded(self, db_pool):
        async with db_pool.acquire() as conn:
            count = await conn.fetchval("SELECT COUNT(*) FROM ai_writing_patterns WHERE enabled")
            rows = await conn.fetch(
                "SELECT name, pattern, flags, threshold, suggestion FROM ai_writing_patterns"
            )
        assert count == 24
        for row in rows:
            assert row["pattern"]
            assert "n" in row["flags"]
            assert row["threshold"] >= 1
            assert row["suggestion"]

    async def test_detects_em_dashes(self, db_pool):
        doc = await _detect(db_pool, "One — two — three — dashes here.")
        assert _counts(doc)["em_dash_overuse"] == 3

    async def test_detects_delve(self, db_pool):
        doc = await _detect(db_pool, "We delve into details. Delve deeper.")
        assert _counts(doc)["delve"] == 2

    async def test_delve_word_boundary(self, db_pool):
        """\\y parity: 'delvers'/'delved' carry no bare 'delve'."""
        doc = await _detect(db_pool, "The delvers delved.")
        assert "delve" not in _counts(doc)

    async def test_detects_formulaic_opener(self, db_pool):
        doc = await _detect(db_pool, "In today's world we write.")
        assert _counts(doc)["formulaic_opener"] == 1

    async def test_detects_transition_crutch_line_starts(self, db_pool):
        """^ under the n flag matches line starts (re.MULTILINE parity)."""
        doc = await _detect(db_pool, "Moreover, it rains.\nFurthermore: it pours.")
        assert _counts(doc)["transition_crutch"] == 2
        clean = await _detect(db_pool, "The moreover argument fails.")
        assert "transition_crutch" not in _counts(clean)

    async def test_detects_list_intro(self, db_pool):
        doc = await _detect(db_pool, "Here are 3 things. Let's dive into it.")
        assert _counts(doc)["list_intro"] == 2

    async def test_detects_grandiose_framing(self, db_pool):
        doc = await _detect(db_pool, "A revolutionary, cutting-edge idea.")
        assert _counts(doc)["grandiose_framing"] == 2

    async def test_detects_empathy_opener(self, db_pool):
        doc = await _detect(db_pool, "Great question! I understand that you care.")
        assert _counts(doc)["empathy_opener"] == 2

    async def test_detects_filler_phrases(self, db_pool):
        doc = await _detect(
            db_pool, "It goes without saying that needless to say, this is important."
        )
        assert _counts(doc)["filler_phrases"] == 2

    async def test_detects_navigate_complexity(self, db_pool):
        doc = await _detect(db_pool, "We navigate the complexities.")
        assert _counts(doc)["navigate_complexity"] == 1
        clean = await _detect(db_pool, "I navigate home.")
        assert "navigate_complexity" not in _counts(clean)

    async def test_detects_leverage_utilize(self, db_pool):
        doc = await _detect(db_pool, "We leverage synergy and utilize tools.")
        assert _counts(doc)["leverage_utilize"] == 2

    async def test_detects_landscape_tapestry(self, db_pool):
        doc = await _detect(db_pool, "The landscape of AI shifts.")
        assert _counts(doc)["landscape_tapestry"] == 1

    async def test_conclusion_signal(self, db_pool):
        doc = await _detect(db_pool, "In conclusion, the key takeaway is clear.")
        assert _counts(doc)["conclusion_signal"] == 2

    async def test_rhetorical_question_needs_question_mark(self, db_pool):
        doc = await _detect(db_pool, "But what does it mean?")
        assert _counts(doc)["rhetorical_question"] == 1
        clean = await _detect(db_pool, "But what\nno question mark here.")
        assert "rhetorical_question" not in _counts(clean)

    async def test_clean_text_no_detections(self, db_pool):
        doc = await _detect(db_pool, "The cat sat on the mat.")
        assert doc["detections"] == []
        assert doc["total_hits"] == 0

    async def test_detection_includes_examples(self, db_pool):
        doc = await _detect(db_pool, "We delve into the archive today, friends.")
        delve = next(d for d in doc["detections"] if d["pattern"] == "delve")
        assert delve["examples"]
        assert "delve" in delve["examples"][0]

    async def test_thresholds_gate_detections(self, db_pool):
        """One hedge is below hedge_stacking's threshold of 2."""
        doc = await _detect(db_pool, "Perhaps we agree.")
        assert "hedge_stacking" not in _counts(doc)
        doc = await _detect(db_pool, "It seems that perhaps we agree.")
        assert _counts(doc)["hedge_stacking"] == 2


# ============================================================================
# Scoring (SQL)
# ============================================================================


class TestAIScore:
    async def test_clean_text_low_score(self, db_pool):
        doc = await _detect(
            db_pool,
            "I walked to the store this morning and bought some bread. "
            "The baker remembered my name, which was a nice surprise for a Tuesday.",
        )
        assert doc["ai_score"] < 0.2

    async def test_ai_heavy_text_high_score(self, db_pool):
        doc = await _detect(
            db_pool,
            "In today's world, let's delve into this revolutionary approach. "
            "Moreover, it's incredibly important. Furthermore, we should leverage "
            "this groundbreaking technology. In conclusion, the key takeaway is clear. "
            "Additionally, the landscape of innovation is fundamentally transforming.",
        )
        assert doc["ai_score"] > 0.4

    async def test_empty_text_zero_score(self, db_pool):
        doc = await _detect(db_pool, "   \n\t  ")
        assert doc["ai_score"] == 0.0
        assert doc["word_count"] == 0

    async def test_short_text_zero_score(self, db_pool):
        """Under 20 words scores 0 regardless of hits."""
        doc = await _detect(db_pool, "delve delve delve")
        assert doc["ai_score"] == 0.0
        assert _counts(doc)["delve"] == 3

    async def test_score_range(self, db_pool):
        doc = await _detect(db_pool, "delve " * 200)
        assert 0.0 <= doc["ai_score"] <= 1.0


# ============================================================================
# L.2: Humanize Text Handler
# ============================================================================


class TestHumanizeTextHandler:
    def test_spec(self):
        h = HumanizeTextHandler()
        assert h.spec.name == "humanize_text"
        assert h.spec.energy_cost == 1
        assert "text" in h.spec.parameters["required"]

    async def test_empty_text(self):
        ctx = _make_context()
        result = await HumanizeTextHandler().execute({"text": ""}, ctx)
        assert not result.success
        assert "no text" in result.error.lower()

    async def test_requires_pool(self):
        ctx = _make_context(pool=None)
        result = await HumanizeTextHandler().execute({"text": "Some text."}, ctx)
        assert not result.success
        assert result.error_type is ToolErrorType.MISSING_CONFIG

    async def test_analyzes_clean_text(self, db_pool):
        ctx = _make_context(pool=db_pool)
        result = await HumanizeTextHandler().execute(
            {"text": "The weather is nice today. I went for a walk."}, ctx
        )
        assert result.success
        assert result.output["ai_score"] == 0.0
        assert result.output["pattern_count"] == 0

    async def test_analyzes_ai_text(self, db_pool):
        ctx = _make_context(pool=db_pool)
        text = (
            "In today's world, let's delve into this revolutionary approach. "
            "Moreover, it's incredibly important. Furthermore, we should leverage this. "
            "Additionally, the landscape of innovation is fundamentally changing."
        )
        result = await HumanizeTextHandler().execute({"text": text}, ctx)
        assert result.success
        assert result.output["pattern_count"] > 0
        assert len(result.output["detections"]) > 0

    @patch("core.llm.chat_completion")
    @patch("core.llm_config.load_llm_config")
    async def test_rewrite_with_llm(self, mock_config, mock_chat, db_pool):
        mock_config.return_value = {"provider": "test", "model": "test"}
        mock_chat.return_value = {
            "content": "Exploring this topic reveals something important."
        }

        ctx = _make_context(pool=db_pool)
        text = (
            "Let's delve into this topic. Moreover, it's incredibly important. "
            "Furthermore, we should leverage this revolutionary approach."
        )
        result = await HumanizeTextHandler().execute(
            {"text": text, "rewrite": True}, ctx
        )
        assert result.success
        assert "rewritten" in result.output
        assert "rewritten_ai_score" in result.output

    async def test_no_rewrite_on_clean_text(self, db_pool):
        ctx = _make_context(pool=db_pool)
        result = await HumanizeTextHandler().execute(
            {"text": "The cat sat on the mat.", "rewrite": True}, ctx
        )
        assert result.success
        assert "rewritten" not in result.output


# ============================================================================
# L.1: Post-Process Output Handler
# ============================================================================


class TestPostProcessOutput:
    def test_spec(self):
        h = PostProcessOutputHandler()
        assert h.spec.name == "post_process_output"
        assert h.spec.energy_cost == 2

    async def test_empty_text(self):
        ctx = _make_context()
        result = await PostProcessOutputHandler().execute({"text": ""}, ctx)
        assert not result.success
        assert "no text" in result.error.lower()

    async def test_clean_text_passes_through(self, db_pool):
        ctx = _make_context(pool=db_pool)
        result = await PostProcessOutputHandler().execute(
            {"text": "Simple clean text."}, ctx
        )
        assert result.success
        assert result.output["text"] == "Simple clean text."
        assert len(result.output["processors_applied"]) > 0

    async def test_skips_low_score_text(self, db_pool):
        ctx = _make_context(pool=db_pool)
        result = await PostProcessOutputHandler().execute(
            {"text": "The weather is nice today."}, ctx
        )
        assert result.success
        proc = result.output["processors_applied"][0]
        assert proc.get("skipped") is True

    @patch("core.llm.chat_completion")
    @patch("core.llm_config.load_llm_config")
    async def test_rewrites_high_score_text(self, mock_config, mock_chat, db_pool):
        mock_config.return_value = {"provider": "test", "model": "test"}
        mock_chat.return_value = {
            "content": "This approach uses technology effectively."
        }

        ctx = _make_context(pool=db_pool)
        text = (
            "In today's world, let's delve into this revolutionary approach. "
            "Moreover, it's incredibly important. Furthermore, we should leverage "
            "this groundbreaking technology. In conclusion, the key takeaway is clear. "
            "Additionally, the landscape of innovation is fundamentally transforming."
        )
        result = await PostProcessOutputHandler().execute({"text": text}, ctx)
        assert result.success
        applied = result.output["processors_applied"]
        assert len(applied) > 0

    async def test_custom_processors(self, db_pool):
        ctx = _make_context(pool=db_pool)
        result = await PostProcessOutputHandler().execute(
            {"text": "Hello world.", "processors": ["humanizer"]}, ctx
        )
        assert result.success
