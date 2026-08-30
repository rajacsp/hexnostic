"""Tests for Fathom meeting transcript integration tools (E.7)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.fathom.tools import (
    FetchFathomTranscriptsHandler,
    IngestFathomTranscriptHandler,
    create_fathom_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestFetchFathomTranscriptsSpec:
    def test_spec_name(self):
        assert FetchFathomTranscriptsHandler().spec.name == "fathom_transcripts"

    def test_spec_category(self):
        assert FetchFathomTranscriptsHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert FetchFathomTranscriptsHandler().spec.is_read_only is True

    def test_spec_energy_cost(self):
        assert FetchFathomTranscriptsHandler().spec.energy_cost == 2

    def test_spec_optional(self):
        assert FetchFathomTranscriptsHandler().spec.optional is True

    def test_spec_has_limit_param(self):
        props = FetchFathomTranscriptsHandler().spec.parameters["properties"]
        assert "limit" in props
        assert props["limit"]["type"] == "integer"

    def test_spec_has_since_days_param(self):
        props = FetchFathomTranscriptsHandler().spec.parameters["properties"]
        assert "since_days" in props
        assert props["since_days"]["type"] == "integer"


class TestIngestFathomTranscriptSpec:
    def test_spec_name(self):
        assert IngestFathomTranscriptHandler().spec.name == "fathom_ingest"

    def test_spec_category(self):
        assert IngestFathomTranscriptHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_not_read_only(self):
        assert IngestFathomTranscriptHandler().spec.is_read_only is False

    def test_spec_energy_cost(self):
        assert IngestFathomTranscriptHandler().spec.energy_cost == 4

    def test_spec_optional(self):
        assert IngestFathomTranscriptHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "recording_id" in IngestFathomTranscriptHandler().spec.parameters["required"]


class TestFathomAuthFailure:
    @pytest.mark.asyncio
    async def test_fetch_no_key(self):
        handler = FetchFathomTranscriptsHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_fetch_resolver_returns_none(self):
        handler = FetchFathomTranscriptsHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_ingest_no_key(self):
        handler = IngestFathomTranscriptHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"recording_id": "rec_123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_ingest_resolver_returns_none(self):
        handler = IngestFathomTranscriptHandler(api_key_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"recording_id": "rec_123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestFathomFactory:
    def test_factory_count(self):
        tools = create_fathom_tools()
        assert len(tools) == 2

    def test_factory_names(self):
        names = {t.spec.name for t in create_fathom_tools()}
        assert names == {"fathom_transcripts", "fathom_ingest"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_fathom_tools(api_key_resolver=resolver)
        for tool in tools:
            assert tool._api_key_resolver is resolver
