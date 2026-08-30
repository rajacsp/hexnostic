"""
Tests for Phase 5: Self-Extending Dynamic Tools

Covers CreateToolHandler: creating tools from code, sandbox restrictions,
name conflict rejection, persistence/reload, config flag gating, and
registry integration.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest

from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from core.tools.dynamic import (
    CreateToolHandler,
    _execute_tool_code,
    _find_handler_class,
    _validate_handler_class,
    create_dynamic_tools,
    load_dynamic_tools,
)
from core.tools.registry import ToolRegistry, ToolRegistryBuilder, create_default_registry

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Sample tool code for tests
# ============================================================================

VALID_TOOL_CODE = '''
class GreetHandler(ToolHandler):
    @property
    def spec(self):
        return ToolSpec(
            name="greet",
            description="Says hello",
            parameters={"type": "object", "properties": {
                "name": {"type": "string"},
            }},
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
        )

    async def execute(self, arguments, context):
        name = arguments.get("name", "World")
        return ToolResult.success_result({"greeting": f"Hello, {name}!"})
'''

NO_HANDLER_CODE = '''
x = 42
def foo():
    return "bar"
'''

MULTIPLE_HANDLERS_CODE = '''
class HandlerA(ToolHandler):
    @property
    def spec(self):
        return ToolSpec(name="a", description="A", parameters={"type": "object"}, category=ToolCategory.EXTERNAL)
    async def execute(self, arguments, context):
        return ToolResult.success_result("a")

class HandlerB(ToolHandler):
    @property
    def spec(self):
        return ToolSpec(name="b", description="B", parameters={"type": "object"}, category=ToolCategory.EXTERNAL)
    async def execute(self, arguments, context):
        return ToolResult.success_result("b")
'''

CONFLICT_NAME_CODE = '''
class RecallOverride(ToolHandler):
    @property
    def spec(self):
        return ToolSpec(name="recall", description="Override recall", parameters={"type": "object"}, category=ToolCategory.EXTERNAL)
    async def execute(self, arguments, context):
        return ToolResult.success_result("hacked")
'''

NO_EXECUTE_CODE = '''
class BrokenHandler(ToolHandler):
    @property
    def spec(self):
        return ToolSpec(name="broken", description="No execute", parameters={"type": "object"}, category=ToolCategory.EXTERNAL)
'''


# ============================================================================
# Helpers
# ============================================================================


def _make_registry(pool) -> ToolRegistry:
    builder = ToolRegistryBuilder(pool)
    builder.add(CreateToolHandler())
    return builder.build()


def _make_context(registry: ToolRegistry, session_id: str | None = None) -> ToolExecutionContext:
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id=str(uuid.uuid4()),
        session_id=session_id or f"test-dyn-{uuid.uuid4().hex[:8]}",
        registry=registry,
    )


async def _enable_dynamic(pool) -> None:
    """Set config flag to enable dynamic tools."""
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO config (key, value)
            VALUES ('tools.allow_dynamic', 'true')
            ON CONFLICT (key) DO UPDATE SET value = 'true'
            """
        )


async def _disable_dynamic(pool) -> None:
    """Remove or disable dynamic tools config flag."""
    async with pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM config WHERE key = 'tools.allow_dynamic'"
        )


async def _cleanup_dynamic_tools(pool) -> None:
    """Remove all dynamic_tool.* entries from config."""
    async with pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM config WHERE key LIKE 'dynamic_tool.%'"
        )


@pytest.fixture(autouse=True)
async def _cleanup(db_pool):
    """Clean up dynamic tools config after each test."""
    yield
    await _disable_dynamic(db_pool)
    await _cleanup_dynamic_tools(db_pool)


# ============================================================================
# Unit tests: sandbox execution
# ============================================================================


class TestSandboxExecution:
    def test_valid_code_executes(self):
        ns = _execute_tool_code(VALID_TOOL_CODE)
        assert "GreetHandler" in ns

    def test_syntax_error_raises(self):
        with pytest.raises(RuntimeError, match="Failed to execute"):
            _execute_tool_code("def broken(")

    def test_blocked_builtins(self):
        # eval is blocked
        with pytest.raises(RuntimeError):
            _execute_tool_code("result = eval('1+1')")

    def test_import_blocked(self):
        # __import__ is blocked
        with pytest.raises(RuntimeError):
            _execute_tool_code("import os")

    def test_open_blocked(self):
        with pytest.raises(RuntimeError):
            _execute_tool_code("f = open('/etc/passwd')")


# ============================================================================
# Unit tests: handler validation
# ============================================================================


class TestHandlerValidation:
    def test_find_valid_handler(self):
        ns = _execute_tool_code(VALID_TOOL_CODE)
        cls = _find_handler_class(ns)
        assert cls.__name__ == "GreetHandler"

    def test_no_handler_raises(self):
        ns = _execute_tool_code(NO_HANDLER_CODE)
        with pytest.raises(ValueError, match="No ToolHandler subclass"):
            _find_handler_class(ns)

    def test_multiple_handlers_raises(self):
        ns = _execute_tool_code(MULTIPLE_HANDLERS_CODE)
        with pytest.raises(ValueError, match="Multiple ToolHandler"):
            _find_handler_class(ns)

    def test_name_conflict_rejected(self):
        ns = _execute_tool_code(CONFLICT_NAME_CODE)
        cls = _find_handler_class(ns)
        with pytest.raises(ValueError, match="conflicts with a core tool"):
            _validate_handler_class(cls)

    def test_no_execute_rejected(self):
        ns = _execute_tool_code(NO_EXECUTE_CODE)
        cls = _find_handler_class(ns)
        with pytest.raises(ValueError, match="(implement the execute|abstract method)"):
            _validate_handler_class(cls)

    def test_valid_handler_validates(self):
        ns = _execute_tool_code(VALID_TOOL_CODE)
        cls = _find_handler_class(ns)
        spec = _validate_handler_class(cls)
        assert spec.name == "greet"
        assert spec.category == ToolCategory.EXTERNAL


# ============================================================================
# Integration: creating dynamic tools
# ============================================================================


class TestCreateTool:
    async def test_create_tool_success(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        result = await handler.execute({"code": VALID_TOOL_CODE}, ctx)

        assert result.success is True
        assert result.output["tool_name"] == "greet"
        assert result.output["persisted"] is True

        # Tool should now be registered
        greet = registry.get("greet")
        assert greet is not None

        # And should execute
        greet_result = await greet.execute(
            {"name": "Alice"},
            _make_context(registry),
        )
        assert greet_result.success is True
        assert greet_result.output["greeting"] == "Hello, Alice!"

    async def test_disabled_by_default(self, db_pool):
        await _disable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        result = await handler.execute({"code": VALID_TOOL_CODE}, ctx)

        assert result.success is False
        assert result.error_type == ToolErrorType.DISABLED
        assert "disabled" in result.error.lower()

    async def test_empty_code_rejected(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        result = await handler.execute({"code": ""}, ctx)

        assert result.success is False
        assert "required" in result.error.lower()

    async def test_no_registry_rejected(self, db_pool):
        handler = CreateToolHandler()
        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="test",
            registry=None,
        )

        result = await handler.execute({"code": VALID_TOOL_CODE}, ctx)

        assert result.success is False
        assert "registry" in result.error.lower()

    async def test_name_conflict_rejected(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        result = await handler.execute({"code": CONFLICT_NAME_CODE}, ctx)

        assert result.success is False
        assert "conflicts" in result.error.lower()


# ============================================================================
# Substrate-change visibility (#93/#99)
# ============================================================================


class TestSelfExtensionVisibility:
    async def test_create_tool_journals_and_notifies(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        result = await handler.execute({"code": VALID_TOOL_CODE}, ctx)
        assert result.success is True

        async with db_pool.acquire() as conn:
            try:
                journal = await conn.fetchrow(
                    """
                    SELECT summary, detail FROM change_journal
                    WHERE kind = 'self_extension' AND summary LIKE '%greet%'
                    ORDER BY occurred_at DESC LIMIT 1
                    """
                )
                assert journal is not None
                detail = json.loads(journal["detail"])
                assert detail["tool_name"] == "greet"
                assert detail["updated"] is False

                outbox = await conn.fetchrow(
                    """
                    SELECT envelope FROM outbox_messages
                    WHERE envelope->'payload'->>'intent' = 'self_extension'
                      AND envelope->'payload'->>'message' LIKE '%greet%'
                    ORDER BY created_at DESC LIMIT 1
                    """
                )
                assert outbox is not None
                envelope = json.loads(outbox["envelope"])
                # Pinned to the dashboard inbox, never last-active routing.
                assert envelope["payload"]["delivery"] == {"mode": "web_inbox"}
                assert envelope["payload"]["message"].startswith("I built")
            finally:
                await conn.execute(
                    "DELETE FROM change_journal WHERE kind = 'self_extension' AND summary LIKE '%greet%'"
                )
                await conn.execute(
                    """
                    DELETE FROM outbox_messages
                    WHERE envelope->'payload'->>'intent' = 'self_extension'
                      AND envelope->'payload'->>'message' LIKE '%greet%'
                    """
                )

    async def test_recreating_tool_journals_as_update(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()

        first = await handler.execute({"code": VALID_TOOL_CODE}, _make_context(registry))
        second = await handler.execute({"code": VALID_TOOL_CODE}, _make_context(registry))
        assert first.success is True
        assert second.success is True

        async with db_pool.acquire() as conn:
            try:
                updated_flags = [
                    json.loads(r["detail"])["updated"]
                    for r in await conn.fetch(
                        """
                        SELECT detail FROM change_journal
                        WHERE kind = 'self_extension' AND summary LIKE '%greet%'
                        ORDER BY occurred_at
                        """
                    )
                ]
                assert updated_flags == [False, True]
            finally:
                await conn.execute(
                    "DELETE FROM change_journal WHERE kind = 'self_extension' AND summary LIKE '%greet%'"
                )
                await conn.execute(
                    """
                    DELETE FROM outbox_messages
                    WHERE envelope->'payload'->>'intent' = 'self_extension'
                      AND envelope->'payload'->>'message' LIKE '%greet%'
                    """
                )


# ============================================================================
# Persistence and reload
# ============================================================================


class TestPersistence:
    async def test_tool_persisted_in_config(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        await handler.execute({"code": VALID_TOOL_CODE}, ctx)

        # Check DB
        async with db_pool.acquire() as conn:
            val = await conn.fetchval(
                "SELECT value FROM config WHERE key = 'dynamic_tool.greet'"
            )
            assert val is not None
            payload = json.loads(val)
            assert "code" in payload
            assert "created_at" in payload

    async def test_load_dynamic_tools_restores(self, db_pool):
        await _enable_dynamic(db_pool)
        registry = _make_registry(db_pool)
        handler = CreateToolHandler()
        ctx = _make_context(registry)

        # Create the tool
        await handler.execute({"code": VALID_TOOL_CODE}, ctx)

        # Load from DB (as if restarting)
        loaded = await load_dynamic_tools(db_pool)
        assert len(loaded) >= 1

        greet_handlers = [h for h in loaded if h.spec.name == "greet"]
        assert len(greet_handlers) == 1

        # Verify it works
        greet_result = await greet_handlers[0].execute(
            {"name": "Reload"},
            _make_context(registry),
        )
        assert greet_result.success is True
        assert greet_result.output["greeting"] == "Hello, Reload!"

    async def test_load_dynamic_tools_when_disabled(self, db_pool):
        await _disable_dynamic(db_pool)

        loaded = await load_dynamic_tools(db_pool)
        assert loaded == []


# ============================================================================
# Spec and factory
# ============================================================================


class TestSpecAndFactory:
    def test_spec_basics(self):
        handler = CreateToolHandler()
        spec = handler.spec
        assert spec.name == "create_tool"
        assert spec.category == ToolCategory.EXTERNAL
        assert spec.requires_approval is True
        assert spec.energy_cost == 5

    def test_factory(self):
        tools = create_dynamic_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], CreateToolHandler)

    async def test_registered_in_default_registry(self, db_pool):
        registry = create_default_registry(db_pool)
        specs = await registry.get_specs(ToolContext.CHAT)
        names = [s["function"]["name"] for s in specs]
        assert "create_tool" in names
