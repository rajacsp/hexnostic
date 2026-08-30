"""Tests for Asana integration tools (E.4)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.asana.tools import (
    CreateAsanaTaskHandler,
    ListAsanaProjectsHandler,
    create_asana_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestCreateAsanaTaskSpec:
    def test_spec_name(self):
        assert CreateAsanaTaskHandler().spec.name == "asana_create_task"

    def test_spec_category(self):
        assert CreateAsanaTaskHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_not_read_only(self):
        assert CreateAsanaTaskHandler().spec.is_read_only is False

    def test_spec_requires_approval(self):
        assert CreateAsanaTaskHandler().spec.requires_approval is True

    def test_spec_required_params(self):
        assert "name" in CreateAsanaTaskHandler().spec.parameters["required"]


class TestListAsanaProjectsSpec:
    def test_spec_name(self):
        assert ListAsanaProjectsHandler().spec.name == "asana_list_projects"

    def test_spec_read_only(self):
        assert ListAsanaProjectsHandler().spec.is_read_only is True


class TestAsanaAuthFailure:
    @pytest.mark.asyncio
    async def test_create_no_key(self):
        handler = CreateAsanaTaskHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"name": "Test task"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_list_no_key(self):
        handler = ListAsanaProjectsHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestAsanaFactory:
    def test_factory_count(self):
        tools = create_asana_tools()
        assert len(tools) == 2

    def test_factory_names(self):
        names = {t.spec.name for t in create_asana_tools()}
        assert names == {"asana_create_task", "asana_list_projects"}
