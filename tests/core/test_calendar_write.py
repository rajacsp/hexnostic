"""Tests for calendar write tools (E.2): update and delete event handlers."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.calendar import (
    CreateCalendarEventHandler,
    UpdateCalendarEventHandler,
    DeleteCalendarEventHandler,
    create_calendar_tools,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


# ---------------------------------------------------------------------------
# UpdateCalendarEventHandler spec tests
# ---------------------------------------------------------------------------

class TestUpdateCalendarEventSpec:
    def test_spec_name(self):
        spec = UpdateCalendarEventHandler().spec
        assert spec.name == "calendar_update"

    def test_spec_category(self):
        spec = UpdateCalendarEventHandler().spec
        assert spec.category == ToolCategory.CALENDAR

    def test_spec_not_read_only(self):
        spec = UpdateCalendarEventHandler().spec
        assert spec.is_read_only is False

    def test_spec_requires_approval(self):
        spec = UpdateCalendarEventHandler().spec
        assert spec.requires_approval is True

    def test_spec_required_params(self):
        spec = UpdateCalendarEventHandler().spec
        assert "event_id" in spec.parameters["required"]

    def test_spec_optional_params(self):
        spec = UpdateCalendarEventHandler().spec
        props = spec.parameters["properties"]
        assert "title" in props
        assert "start" in props
        assert "end" in props
        assert "description" in props
        assert "location" in props


# ---------------------------------------------------------------------------
# DeleteCalendarEventHandler spec tests
# ---------------------------------------------------------------------------

class TestDeleteCalendarEventSpec:
    def test_spec_name(self):
        spec = DeleteCalendarEventHandler().spec
        assert spec.name == "calendar_delete"

    def test_spec_category(self):
        spec = DeleteCalendarEventHandler().spec
        assert spec.category == ToolCategory.CALENDAR

    def test_spec_not_read_only(self):
        spec = DeleteCalendarEventHandler().spec
        assert spec.is_read_only is False

    def test_spec_requires_approval(self):
        spec = DeleteCalendarEventHandler().spec
        assert spec.requires_approval is True

    def test_spec_required_params(self):
        spec = DeleteCalendarEventHandler().spec
        assert "event_id" in spec.parameters["required"]


# ---------------------------------------------------------------------------
# Auth failure tests
# ---------------------------------------------------------------------------

class TestCalendarWriteAuthFailure:
    @pytest.mark.asyncio
    async def test_update_no_credentials(self):
        handler = UpdateCalendarEventHandler(credentials_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"event_id": "abc123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_update_resolver_returns_none(self):
        handler = UpdateCalendarEventHandler(credentials_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"event_id": "abc123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_delete_no_credentials(self):
        handler = DeleteCalendarEventHandler(credentials_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"event_id": "abc123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_delete_resolver_returns_none(self):
        handler = DeleteCalendarEventHandler(credentials_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({"event_id": "abc123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


# ---------------------------------------------------------------------------
# Factory tests
# ---------------------------------------------------------------------------

class TestCalendarFactory:
    def test_factory_includes_all_handlers(self):
        tools = create_calendar_tools()
        names = {t.spec.name for t in tools}
        assert "calendar_events" in names
        assert "calendar_create" in names
        assert "calendar_update" in names
        assert "calendar_delete" in names

    def test_factory_count(self):
        tools = create_calendar_tools()
        assert len(tools) == 5

    def test_factory_passes_resolver(self):
        resolver = lambda: {"test": True}
        tools = create_calendar_tools(credentials_resolver=resolver)
        # All should have the resolver set
        for tool in tools:
            assert tool._credentials_resolver is resolver
