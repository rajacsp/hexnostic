"""Tests for email ingestion tool (B.2)."""

from __future__ import annotations

import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.email import IngestEmailsHandler, create_email_tools


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


class TestIngestEmailsSpec:
    def test_spec_name(self):
        assert IngestEmailsHandler().spec.name == "ingest_emails"

    def test_spec_category(self):
        assert IngestEmailsHandler().spec.category == ToolCategory.EMAIL

    def test_spec_not_read_only(self):
        assert IngestEmailsHandler().spec.is_read_only is False

    def test_spec_optional(self):
        assert IngestEmailsHandler().spec.optional is True

    def test_spec_allowed_contexts(self):
        assert ToolContext.HEARTBEAT in IngestEmailsHandler().spec.allowed_contexts
        assert ToolContext.CHAT in IngestEmailsHandler().spec.allowed_contexts

    def test_spec_has_max_results_param(self):
        props = IngestEmailsHandler().spec.parameters["properties"]
        assert "max_results" in props

    def test_spec_has_label_param(self):
        props = IngestEmailsHandler().spec.parameters["properties"]
        assert "label" in props

    def test_spec_has_unread_only_param(self):
        props = IngestEmailsHandler().spec.parameters["properties"]
        assert "unread_only" in props

    def test_spec_energy_cost(self):
        assert IngestEmailsHandler().spec.energy_cost == 5


class TestIngestEmailsAuth:
    @pytest.mark.asyncio
    async def test_no_credentials_returns_auth_failed(self):
        handler = IngestEmailsHandler()
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_credentials_resolver_returns_none(self):
        handler = IngestEmailsHandler(credentials_resolver=lambda: None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestIngestEmailsExecution:
    @pytest.mark.asyncio
    async def test_no_messages_returns_zero(self):
        handler = IngestEmailsHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.users.return_value.messages.return_value.list.return_value.execute.return_value = {
            "messages": []
        }

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert result.output["emails_ingested"] == 0

    @pytest.mark.asyncio
    async def test_ingests_email_and_creates_contact(self):
        handler = IngestEmailsHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.users.return_value.messages.return_value.list.return_value.execute.return_value = {
            "messages": [{"id": "msg-1"}]
        }
        mock_service.users.return_value.messages.return_value.get.return_value.execute.return_value = {
            "id": "msg-1",
            "snippet": "Hello there",
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    {"name": "From", "value": "Alice Smith <alice@example.com>"},
                    {"name": "Subject", "value": "Test email"},
                    {"name": "Date", "value": "2026-02-13"},
                    {"name": "To", "value": "me@example.com"},
                ],
                "body": {"data": ""},
            },
        }

        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(side_effect=[
            None,       # content_hash check — not a duplicate
            "mem-uuid", # create_episodic_memory
            '{"id": 7, "created": true}',  # upsert_contact (db/65)
        ])
        mock_conn.execute = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({"unread_only": False}, ctx)

        assert result.success
        assert result.output["emails_ingested"] == 1
        assert result.output["contacts_created"] == 1
        assert result.output["contacts_updated"] == 0

    @pytest.mark.asyncio
    async def test_skips_duplicate_emails(self):
        handler = IngestEmailsHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.users.return_value.messages.return_value.list.return_value.execute.return_value = {
            "messages": [{"id": "msg-1"}]
        }
        mock_service.users.return_value.messages.return_value.get.return_value.execute.return_value = {
            "id": "msg-1",
            "snippet": "Hello",
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    {"name": "From", "value": "bob@example.com"},
                    {"name": "Subject", "value": "Dup"},
                    {"name": "Date", "value": "2026-02-13"},
                    {"name": "To", "value": "me@example.com"},
                ],
                "body": {"data": ""},
            },
        }

        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(return_value="existing-mem-id")
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert result.output["emails_ingested"] == 0
        assert result.output["emails_skipped"] == 1

    @pytest.mark.asyncio
    async def test_updates_existing_contact(self):
        handler = IngestEmailsHandler(credentials_resolver=lambda: {"token": "fake"})
        ctx = _make_context()

        mock_service = MagicMock()
        mock_service.users.return_value.messages.return_value.list.return_value.execute.return_value = {
            "messages": [{"id": "msg-2"}]
        }
        mock_service.users.return_value.messages.return_value.get.return_value.execute.return_value = {
            "id": "msg-2",
            "snippet": "Hi",
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    {"name": "From", "value": "Bob <bob@example.com>"},
                    {"name": "Subject", "value": "Follow up"},
                    {"name": "Date", "value": "2026-02-13"},
                    {"name": "To", "value": "me@example.com"},
                ],
                "body": {"data": ""},
            },
        }

        import uuid
        existing_contact_id = uuid.uuid4()

        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(side_effect=[
            None,                # content_hash check — not duplicate
            "mem-uuid",          # create_episodic_memory
            '{"id": 7, "created": false}',  # upsert_contact touches existing (db/65)
        ])
        mock_conn.execute = AsyncMock()
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        modules, mock_creds_class, mock_build = _mock_google_modules()
        mock_build.return_value = mock_service

        with patch.dict(sys.modules, modules):
            result = await handler.execute({}, ctx)

        assert result.success
        assert result.output["contacts_updated"] == 1
        assert result.output["contacts_created"] == 0


class TestIngestEmailsFactory:
    def test_factory_includes_ingest_handler(self):
        tools = create_email_tools()
        names = [t.spec.name for t in tools]
        assert "ingest_emails" in names

    def test_factory_total_count(self):
        tools = create_email_tools()
        # email_send, email_list, email_read, email_search, ingest_emails
        assert len(tools) == 5
