"""Tests for Todoist integration tools (E.3)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from plugins.installed.todoist.tools import (
    CreateTodoistTaskHandler,
    ListTodoistTasksHandler,
    CompleteTodoistTaskHandler,
    create_todoist_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestCreateTodoistTaskSpec:
    def test_spec_name(self):
        assert CreateTodoistTaskHandler().spec.name == "todoist_create_task"

    def test_spec_category(self):
        assert CreateTodoistTaskHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_not_read_only(self):
        assert CreateTodoistTaskHandler().spec.is_read_only is False

    def test_spec_requires_approval(self):
        assert CreateTodoistTaskHandler().spec.requires_approval is True

    def test_spec_required_params(self):
        assert "content" in CreateTodoistTaskHandler().spec.parameters["required"]


class TestListTodoistTasksSpec:
    def test_spec_name(self):
        assert ListTodoistTasksHandler().spec.name == "todoist_list_tasks"

    def test_spec_read_only(self):
        assert ListTodoistTasksHandler().spec.is_read_only is True


class TestCompleteTodoistTaskSpec:
    def test_spec_name(self):
        assert CompleteTodoistTaskHandler().spec.name == "todoist_complete_task"

    def test_spec_required_params(self):
        assert "task_id" in CompleteTodoistTaskHandler().spec.parameters["required"]


class TestTodoistAuthFailure:
    @pytest.mark.asyncio
    async def test_create_no_key(self):
        handler = CreateTodoistTaskHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"content": "Test"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_list_no_key(self):
        handler = ListTodoistTasksHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED

    @pytest.mark.asyncio
    async def test_complete_no_key(self):
        handler = CompleteTodoistTaskHandler(api_key_resolver=None)
        ctx = _make_context()
        result = await handler.execute({"task_id": "123"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.AUTH_FAILED


class TestTodoistFactory:
    def test_factory_count(self):
        tools = create_todoist_tools()
        assert len(tools) == 3

    def test_factory_names(self):
        names = {t.spec.name for t in create_todoist_tools()}
        assert names == {"todoist_create_task", "todoist_list_tasks", "todoist_complete_task"}
