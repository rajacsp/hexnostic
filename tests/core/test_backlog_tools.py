"""
Tests for core/tools/backlog.py — ManageBacklogHandler.

Covers: spec, validation, CRUD actions, episodic memory creation on user
changes, checkpoint management, and DB integration.
"""

from __future__ import annotations

import json
import uuid
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest

from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolResult,
)
from core.tools.backlog import ManageBacklogHandler, create_backlog_tools

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Helpers
# ============================================================================


def _make_exec_context(
    *,
    pool=None,
    registry=None,
    tool_context: ToolContext = ToolContext.HEARTBEAT,
) -> ToolExecutionContext:
    reg = registry or MagicMock()
    if pool:
        reg.pool = pool
    ctx = ToolExecutionContext(
        tool_context=tool_context,
        call_id=str(uuid.uuid4()),
    )
    ctx.registry = reg
    return ctx


# ============================================================================
# Unit: spec
# ============================================================================


class TestBacklogSpec:
    def test_spec_name(self):
        handler = ManageBacklogHandler()
        assert handler.spec.name == "manage_backlog"

    def test_spec_category(self):
        handler = ManageBacklogHandler()
        assert handler.spec.category == ToolCategory.MEMORY

    def test_spec_allowed_contexts(self):
        handler = ManageBacklogHandler()
        assert ToolContext.HEARTBEAT in handler.spec.allowed_contexts
        assert ToolContext.CHAT in handler.spec.allowed_contexts
        assert ToolContext.MCP in handler.spec.allowed_contexts

    def test_spec_energy_cost(self):
        handler = ManageBacklogHandler()
        assert handler.spec.energy_cost == 1

    def test_create_backlog_tools_returns_list(self):
        tools = create_backlog_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], ManageBacklogHandler)


# ============================================================================
# Unit: validation
# ============================================================================


class TestBacklogValidation:
    async def test_invalid_action_rejected(self):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=MagicMock()))
        result = await handler.execute({"action": "invalid_action"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_missing_action_rejected(self):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=MagicMock()))
        result = await handler.execute({}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_create_requires_title(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "create"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_create_blank_title_rejected(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "create", "title": "   "}, ctx)
        assert not result.success

    async def test_update_requires_item_id(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "update", "title": "new"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_update_requires_fields(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "update", "item_id": "abc"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_delete_requires_item_id(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "delete"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_get_requires_item_id(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "get"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_set_status_requires_item_id(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute({"action": "set_status", "status": "done"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_set_status_requires_valid_status(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute(
            {"action": "set_status", "item_id": "abc", "status": "mega"},
            ctx,
        )
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_set_checkpoint_requires_item_id(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute(
            {"action": "set_checkpoint", "checkpoint": {}}, ctx
        )
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_set_checkpoint_requires_data(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(registry=MagicMock(pool=db_pool))
        result = await handler.execute(
            {"action": "set_checkpoint", "item_id": "abc"}, ctx
        )
        assert not result.success
        assert result.error_type == ToolErrorType.INVALID_PARAMS

    async def test_no_pool_returns_error(self):
        handler = ManageBacklogHandler()
        registry = MagicMock()
        registry.pool = None
        ctx = _make_exec_context(registry=registry)
        result = await handler.execute({"action": "list"}, ctx)
        assert not result.success
        assert result.error_type == ToolErrorType.MISSING_CONFIG


# ============================================================================
# Integration: CRUD
# ============================================================================


class TestBacklogIntegration:
    async def test_create_item(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        result = await handler.execute(
            {
                "action": "create",
                "title": "Test backlog item",
                "description": "Integration test",
                "priority": "high",
                "owner": "agent",
            },
            ctx,
        )
        assert result.success
        assert result.output["title"] == "Test backlog item"
        assert result.output["priority"] == "high"
        assert result.output["created_by"] == "agent"  # heartbeat context

        # Cleanup
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", result.output["item_id"])

    async def test_create_from_chat_sets_user_created_by(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(
            pool=db_pool,
            registry=MagicMock(pool=db_pool),
            tool_context=ToolContext.CHAT,
        )

        result = await handler.execute(
            {"action": "create", "title": "User task"},
            ctx,
        )
        assert result.success
        assert result.output["created_by"] == "user"

        # Check episodic memory was created
        async with db_pool.acquire() as conn:
            mem_count = await conn.fetchval(
                """
                SELECT COUNT(*) FROM memories
                WHERE type = 'episodic'
                AND metadata->>'source' = 'user_backlog_change'
                AND metadata->>'backlog_item_id' = $1
                """,
                result.output["item_id"],
            )
            assert mem_count >= 1

            # Cleanup
            await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", result.output["item_id"])
            await conn.execute(
                "DELETE FROM memories WHERE metadata->>'backlog_item_id' = $1",
                result.output["item_id"],
            )

    async def test_list_items(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        # Create two items
        r1 = await handler.execute({"action": "create", "title": "List A"}, ctx)
        r2 = await handler.execute({"action": "create", "title": "List B"}, ctx)
        assert r1.success and r2.success

        try:
            result = await handler.execute({"action": "list"}, ctx)
            assert result.success
            titles = [i["title"] for i in result.output["items"]]
            assert "List A" in titles
            assert "List B" in titles
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", r1.output["item_id"])
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", r2.output["item_id"])

    async def test_list_with_filters(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        r1 = await handler.execute(
            {"action": "create", "title": "Urgent task", "priority": "urgent"}, ctx
        )
        r2 = await handler.execute(
            {"action": "create", "title": "Low task", "priority": "low"}, ctx
        )

        try:
            result = await handler.execute(
                {"action": "list", "priority_filter": "urgent"}, ctx
            )
            assert result.success
            titles = [i["title"] for i in result.output["items"]]
            assert "Urgent task" in titles
            assert "Low task" not in titles
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", r1.output["item_id"])
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", r2.output["item_id"])

    async def test_get_item(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        created = await handler.execute(
            {"action": "create", "title": "Get me", "description": "Detailed"}, ctx
        )
        assert created.success

        try:
            result = await handler.execute(
                {"action": "get", "item_id": created.output["item_id"]}, ctx
            )
            assert result.success
            assert result.output["title"] == "Get me"
            assert result.output["description"] == "Detailed"
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", created.output["item_id"])

    async def test_update_item(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        created = await handler.execute(
            {"action": "create", "title": "Update me"}, ctx
        )
        assert created.success

        try:
            result = await handler.execute(
                {
                    "action": "update",
                    "item_id": created.output["item_id"],
                    "title": "Updated title",
                    "priority": "urgent",
                },
                ctx,
            )
            assert result.success
            assert result.output["title"] == "Updated title"
            assert result.output["priority"] == "urgent"
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", created.output["item_id"])

    async def test_set_status(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        created = await handler.execute(
            {"action": "create", "title": "Status me"}, ctx
        )
        assert created.success

        try:
            result = await handler.execute(
                {
                    "action": "set_status",
                    "item_id": created.output["item_id"],
                    "status": "done",
                },
                ctx,
            )
            assert result.success
            assert result.output["new_status"] == "done"
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", created.output["item_id"])

    async def test_set_checkpoint(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        created = await handler.execute(
            {"action": "create", "title": "Checkpoint me"}, ctx
        )
        assert created.success

        try:
            checkpoint = {"step": "step 3", "progress": "almost done", "next_action": "verify"}
            result = await handler.execute(
                {
                    "action": "set_checkpoint",
                    "item_id": created.output["item_id"],
                    "checkpoint": checkpoint,
                },
                ctx,
            )
            assert result.success
            assert result.output["checkpoint_saved"] is True

            # Verify checkpoint was stored
            get_result = await handler.execute(
                {"action": "get", "item_id": created.output["item_id"]}, ctx
            )
            assert get_result.success
            assert get_result.output["checkpoint"]["step"] == "step 3"
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", created.output["item_id"])

    async def test_delete_item(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        created = await handler.execute(
            {"action": "create", "title": "Delete me"}, ctx
        )
        assert created.success

        result = await handler.execute(
            {"action": "delete", "item_id": created.output["item_id"]}, ctx
        )
        assert result.success
        assert result.output["deleted"] is True

        # Verify it's gone
        get_result = await handler.execute(
            {"action": "get", "item_id": created.output["item_id"]}, ctx
        )
        assert not get_result.success

    async def test_delete_from_chat_creates_memory(self, db_pool):
        handler = ManageBacklogHandler()

        # Create in heartbeat context
        hb_ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))
        created = await handler.execute(
            {"action": "create", "title": "User deletes this"}, hb_ctx
        )
        assert created.success
        item_id = created.output["item_id"]

        # Delete in chat context
        chat_ctx = _make_exec_context(
            pool=db_pool,
            registry=MagicMock(pool=db_pool),
            tool_context=ToolContext.CHAT,
        )
        result = await handler.execute(
            {"action": "delete", "item_id": item_id}, chat_ctx
        )
        assert result.success

        # Check memory was created
        async with db_pool.acquire() as conn:
            mem_count = await conn.fetchval(
                """
                SELECT COUNT(*) FROM memories
                WHERE type = 'episodic'
                AND metadata->>'source' = 'user_backlog_change'
                AND metadata->>'backlog_item_id' = $1
                """,
                item_id,
            )
            assert mem_count >= 1

            # Cleanup
            await conn.execute(
                "DELETE FROM memories WHERE metadata->>'backlog_item_id' = $1",
                item_id,
            )

    async def test_create_subtask(self, db_pool):
        handler = ManageBacklogHandler()
        ctx = _make_exec_context(pool=db_pool, registry=MagicMock(pool=db_pool))

        parent = await handler.execute(
            {"action": "create", "title": "Parent task"}, ctx
        )
        assert parent.success

        child = await handler.execute(
            {
                "action": "create",
                "title": "Child task",
                "parent_id": parent.output["item_id"],
            },
            ctx,
        )
        assert child.success

        try:
            get_child = await handler.execute(
                {"action": "get", "item_id": child.output["item_id"]}, ctx
            )
            assert get_child.success
            assert get_child.output["parent_id"] == parent.output["item_id"]
        finally:
            async with db_pool.acquire() as conn:
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", child.output["item_id"])
                await conn.execute("DELETE FROM backlog WHERE id = $1::uuid", parent.output["item_id"])
