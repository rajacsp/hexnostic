"""Tests for meeting prep tool (B.3)."""

from __future__ import annotations

import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.calendar import MeetingPrepHandler, create_calendar_tools


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.HEARTBEAT,
        call_id="test-call",
        registry=registry,
    )


def _mock_google_modules():
    """Set up mock google modules for lazy imports."""
    mock_creds_class = MagicMock()
    mock_build = MagicMock()

    mock_google = MagicMock()
    mock_google.oauth2.credentials.Credentials = mock_creds_class

    modules = {
        "google": mock_google,
        "google.oauth2": mock_google.oauth2,
        "google.oauth2.credentials": mock_google.oauth2.credentials,
        "googleapiclient": MagicMock(),
        "googleapiclient.discovery": MagicMock(build=mock_build),
    }
    return modules, mock_creds_class, mock_build


class TestMeetingPrepSpec:
    def test_spec_name(self):
        assert MeetingPrepHandler().spec.name == "meeting_prep"

    def test_spec_category(self):
        assert MeetingPrepHandler().spec.category == ToolCategory.CALENDAR

    def test_spec_read_only(self):
        assert MeetingPrepHandler().spec.is_read_only is True

    def test_spec_optional(self):
        assert MeetingPrepHandler().spec.optional is True

    def test_spec_allowed_contexts(self):
        assert ToolContext.HEARTBEAT in MeetingPrepHandler().spec.allowed_contexts
        assert ToolContext.CHAT in MeetingPrepHandler().spec.allowed_contexts

    def test_spec_has_days_ahead_param(self):
        props = MeetingPrepHandler().spec.parameters["properties"]
        assert "days_ahead" in props

    def test_spec_has_calendar_id_param(self):
        props = MeetingPrepHandler().spec.parameters["properties"]
        assert "calendar_id" in props

    def test_spec_energy_cost(self):
        assert MeetingPrepHandler().spec.energy_cost == 4


class TestMeetingPrepAuth:
    @pytest.mark.asyncio
    async def test_no_credentials_returns_auth_failed(self):
        handler = MeetingPrepHandler()
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_credentials_resolver_returns_none(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestMeetingPrepExecution:
    @pytest.mark.asyncio
    async def test_no_events_returns_empty(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.events.return_value.list.return_value.execute.return_value = {"items": []}

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        mock_conn = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert result.output["count"] == 0

    @pytest.mark.asyncio
    async def test_event_with_attendees_cross_references_crm(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.events.return_value.list.return_value.execute.return_value = {
            "items": [
                {
                    "id": "evt-1",
                    "summary": "Sync with Alice",
                    "start": {"dateTime": "2026-02-13T10:00:00Z"},
                    "end": {"dateTime": "2026-02-13T11:00:00Z"},
                    "attendees": [
                        {"email": "me@example.com", "self": True},
                        {
                            "email": "alice@corp.com",
                            "displayName": "Alice Smith",
                            "responseStatus": "accepted",
                        },
                    ],
                }
            ]
        }

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value={
            "name": "Alice Smith",
            "company": "Corp Inc",
            "role": "VP Engineering",
            "notes": "Met at conference",
            "tags": ["engineering", "partner"],
            "last_touch": None,
        })
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({"days_ahead": 1}, ctx)

        assert result.success
        assert result.output["count"] == 1
        meeting = result.output["meetings"][0]
        assert meeting["summary"] == "Sync with Alice"
        assert len(meeting["attendees"]) == 1  # self filtered out
        att = meeting["attendees"][0]
        assert att["email"] == "alice@corp.com"
        assert att["crm"] is not None
        assert att["crm"]["company"] == "Corp Inc"

    @pytest.mark.asyncio
    async def test_event_with_unknown_attendee(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.events.return_value.list.return_value.execute.return_value = {
            "items": [
                {
                    "id": "evt-2",
                    "summary": "Meeting",
                    "start": {"dateTime": "2026-02-13T14:00:00Z"},
                    "end": {"dateTime": "2026-02-13T15:00:00Z"},
                    "attendees": [
                        {"email": "unknown@example.com", "responseStatus": "needsAction"},
                    ],
                }
            ]
        }

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value=None)
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        att = result.output["meetings"][0]["attendees"][0]
        assert att["crm"] is None
        assert att["name"] == "unknown"  # derived from email

    @pytest.mark.asyncio
    async def test_event_without_attendees(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.events.return_value.list.return_value.execute.return_value = {
            "items": [
                {
                    "id": "evt-3",
                    "summary": "Focus time",
                    "start": {"dateTime": "2026-02-13T09:00:00Z"},
                    "end": {"dateTime": "2026-02-13T10:00:00Z"},
                }
            ]
        }

        mock_conn = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert result.output["count"] == 1
        assert len(result.output["meetings"][0]["attendees"]) == 0

    @pytest.mark.asyncio
    async def test_display_output_includes_crm_info(self):
        handler = MeetingPrepHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.events.return_value.list.return_value.execute.return_value = {
            "items": [
                {
                    "id": "evt-4",
                    "summary": "Review",
                    "start": {"dateTime": "2026-02-13T16:00:00Z"},
                    "end": {"dateTime": "2026-02-13T17:00:00Z"},
                    "location": "Room 42",
                    "attendees": [
                        {"email": "bob@corp.com", "displayName": "Bob", "responseStatus": "accepted"},
                    ],
                }
            ]
        }

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value={
            "name": "Bob Builder",
            "company": "Corp Inc",
            "role": "CTO",
            "notes": None,
            "tags": [],
            "last_touch": None,
        })
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert "Room 42" in result.display_output
        assert "Corp Inc" in result.display_output
        assert "CTO" in result.display_output


class TestMeetingPrepFactory:
    def test_factory_includes_meeting_prep(self):
        tools = create_calendar_tools()
        names = [t.spec.name for t in tools]
        assert "meeting_prep" in names

    def test_factory_total_count(self):
        tools = create_calendar_tools()
        # calendar_events, calendar_create, calendar_update, calendar_delete, meeting_prep
        assert len(tools) == 5
