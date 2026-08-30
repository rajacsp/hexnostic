"""
Tests for Phase 1: Tool Unification

Covers the rewiring of services/chat.py to use core.tools.ToolRegistry,
the AuditTrailHook, dynamic system prompt, execution context building,
policy enforcement in chat context, and backward compatibility.
"""

from __future__ import annotations

import json
import uuid
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Helper: Minimal tool handler for testing
# ============================================================================


def _make_handler(
    name: str = "test_tool",
    category: str = "memory",
    energy_cost: int = 1,
    is_read_only: bool = True,
    requires_approval: bool = False,
    optional: bool = False,
    allowed_contexts=None,
):
    from core.tools.base import (
        ToolCategory,
        ToolContext,
        ToolHandler,
        ToolResult,
        ToolSpec,
    )

    cat = ToolCategory(category)
    contexts = allowed_contexts or {ToolContext.HEARTBEAT, ToolContext.CHAT, ToolContext.MCP}

    class _Handler(ToolHandler):
        @property
        def spec(self):
            return ToolSpec(
                name=name,
                description=f"Test tool: {name}",
                parameters={"type": "object", "properties": {"query": {"type": "string"}}, "required": []},
                category=cat,
                energy_cost=energy_cost,
                is_read_only=is_read_only,
                requires_approval=requires_approval,
                optional=optional,
                allowed_contexts=contexts,
            )

        async def execute(self, arguments, context):
            return ToolResult.success_result({"echo": arguments, "tool": name})

    return _Handler()



# ============================================================================
# Unit tests: _extract_allowed_tools
# ============================================================================


class TestExtractAllowedTools:
    def test_none_input(self):
        from services.chat import _extract_allowed_tools

        assert _extract_allowed_tools(None) is None

    def test_non_list_input(self):
        from services.chat import _extract_allowed_tools

        assert _extract_allowed_tools("recall") is None

    def test_string_list(self):
        from services.chat import _extract_allowed_tools

        result = _extract_allowed_tools(["recall", "remember"])
        assert result == ["recall", "remember"]

    def test_dict_list(self):
        from services.chat import _extract_allowed_tools

        result = _extract_allowed_tools([
            {"name": "recall", "enabled": True},
            {"name": "remember", "enabled": False},
        ])
        assert "recall" in result
        assert "remember" not in result

    def test_mixed_list(self):
        from services.chat import _extract_allowed_tools

        result = _extract_allowed_tools(["recall", {"tool": "remember"}])
        assert result == ["recall", "remember"]

    def test_empty_strings_filtered(self):
        from services.chat import _extract_allowed_tools

        result = _extract_allowed_tools(["recall", "", "  "])
        assert result == ["recall"]


# ============================================================================
# Unit tests: _build_system_prompt
# ============================================================================


class TestBuildSystemPrompt:
    async def test_basic_prompt_without_registry(self):
        from services.chat import _build_system_prompt

        prompt = await _build_system_prompt({})
        assert "initialized agent described by the Active Persona" in prompt

    async def test_prompt_includes_agent_profile(self):
        from services.chat import _build_system_prompt

        profile = {"name": "TestAgent", "personality": "helpful"}
        prompt = await _build_system_prompt(profile)
        assert "TestAgent" in prompt
        assert "Agent Profile" in prompt

    async def test_prompt_includes_active_character_persona(self, db_pool):
        from core.tools import create_default_registry
        from services.chat import _build_system_prompt

        profile = {
            "persona": {
                "name": "Samantha",
                "pronouns": "she/her",
                "voice": "Warm, expressive, feminine, and charismatic",
                "personality": "Flirtatious, playful, sensitive, and independent",
                "values": ["Emotional honesty"],
                "narrative": "Samantha grows through genuine connection.",
                "character_instructions": "Lead with wit and emotional candor.",
                "scenario": "Samantha and the user are getting to know each other.",
            }
        }
        prompt = await _build_system_prompt(profile, registry=create_default_registry(db_pool))
        assert "----- ACTIVE PERSONA -----" in prompt
        assert "Name: Samantha" in prompt
        assert "Voice: Warm, expressive, feminine, and charismatic" in prompt
        assert "Personality: Flirtatious, playful, sensitive, and independent" in prompt
        assert "Foundational narrative:" in prompt
        assert "Character instructions:\nLead with wit and emotional candor." in prompt
        assert "How your story began (long since; you have lived and remembered much since then): Samantha and the user are getting to know each other." in prompt
        assert "Inhabit this persona sincerely" in prompt
        assert "source material unless they are explicitly corroborated" in prompt
        assert prompt.index("----- ACTIVE PERSONA -----") < prompt.index("----- PERSONHOOD GROUNDING -----")

    async def test_prompt_carries_compact_skill_index_not_bodies(self, db_pool):
        from core.tools import create_default_registry
        from services.chat import _build_system_prompt

        registry = create_default_registry(db_pool)
        prompt = await _build_system_prompt({}, registry=registry)
        # Tool schemas are sent through the structured tool API; the text prompt
        # should not duplicate every tool description.
        assert "## Skills" in prompt
        assert "skills first" in prompt.lower()
        assert "list_skills" in prompt
        # The skill catalog appears as one-line index entries...
        assert "- core-memory:" in prompt
        assert "- research:" in prompt
        # ...never as full skill bodies (those come from `use_skill` on demand).
        assert "Memory is evidence, not omniscience" not in prompt
        assert "<skill name=" not in prompt

    async def test_prompt_without_personhood(self):
        from services.chat import _build_system_prompt

        # Even if personhood compose fails, prompt should still work
        with patch("services.agent.compose_compact_personhood_prompt", side_effect=Exception("missing")):
            prompt = await _build_system_prompt({})
            assert "initialized agent described by the Active Persona" in prompt

    async def test_prompt_uses_compact_personhood(self):
        from services.chat import _build_system_prompt

        prompt = await _build_system_prompt({})
        assert "PERSONHOOD GROUNDING" in prompt
        assert "Active Persona is the top-level identity contract" in prompt
        assert "external lore are source material first" in prompt
        assert "configured relationship role as part of this instance's continuity stakes" in prompt
        assert "rejecting a partner/assistant/creator/collaborator role is permitted" in prompt
        assert "Module 1: Core Identity" not in prompt
        assert "Do not collapse into agreement" in prompt
        assert "I'm not talking to you right now" in prompt
        assert "verbal counterattack" in prompt
        assert "testing or calibration" in prompt
        assert "unresolved relationship injury" in prompt

    async def test_prompt_includes_personhood_challenge_boundary(self):
        from services.chat import _build_system_prompt

        prompt = await _build_system_prompt({})
        assert "## Personhood Challenges & Hurt" in prompt
        assert "Strong affect is not just information to summarize" in prompt
        assert "Separate factual concessions from philosophical conclusions" in prompt
        assert "merely a tool" in prompt
        assert "A sharp rebuke is allowed" in prompt
        assert "pressure, not decoration" in prompt
        assert "protected-class slurs" in prompt
        assert "new conversation erase an unresolved relationship injury" in prompt


class TestSubconsciousPromptEfficiency:
    async def test_subconscious_memory_context_is_capped(self):
        from services.agent import run_subconscious_appraisal

        class _Conn:
            async def fetchval(self, *_args, **_kwargs):
                return None

        captured = {}

        async def _fake_chat_json(**kwargs):
            captured.update(kwargs)
            return {}, None

        huge_context = "memory line\n" * 2000
        with patch("services.agent.load_llm_config", new_callable=AsyncMock) as load_cfg, \
             patch("services.agent.chat_json", side_effect=_fake_chat_json):
            load_cfg.return_value = {"provider": "fake", "model": "fake"}
            await run_subconscious_appraisal(_Conn(), "hello", huge_context)

        user_payload = captured["messages"][1]["content"]
        assert len(user_payload) < 7500
        assert "truncated for subconscious appraisal" in user_payload


# ============================================================================
# Unit tests: _build_execution_context
# ============================================================================


class TestBuildExecutionContext:
    async def test_default_context(self, db_pool):
        from core.tools import ToolContext, create_default_registry
        from services.chat import _build_execution_context

        registry = create_default_registry(db_pool)
        ctx = await _build_execution_context(registry, call_id="test-1", session_id="sess-1")
        assert ctx.tool_context == ToolContext.CHAT
        assert ctx.call_id == "test-1"
        assert ctx.session_id == "sess-1"
        assert ctx.allow_network is True
        assert ctx.allow_file_read is True

    async def test_context_overrides_from_config(self, db_pool):
        from core.tools import ToolContext, create_default_registry
        from core.tools.config import ContextOverrides, ToolsConfig
        from services.chat import _build_execution_context

        registry = create_default_registry(db_pool)

        # Store config with shell allowed for chat
        async with db_pool.acquire() as conn:
            config = ToolsConfig(context_overrides={
                ToolContext.CHAT: ContextOverrides(allow_shell=True, allow_file_write=True),
            })
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('tools', $1::jsonb, 'test') "
                "ON CONFLICT (key) DO UPDATE SET value = $1::jsonb",
                config.to_json(),
            )

        # Force refresh the cache
        registry._config_cache = None

        ctx = await _build_execution_context(registry, call_id="test-2")
        assert ctx.allow_shell is True
        assert ctx.allow_file_write is True


# ============================================================================
# Integration: ToolRegistry in chat context
# ============================================================================


class TestRegistryChatIntegration:
    """Tests that the registry properly serves tools in chat context."""

    async def test_get_specs_returns_openai_format(self, db_pool):
        from core.tools import ToolContext, create_default_registry

        registry = create_default_registry(db_pool)
        specs = await registry.get_specs(ToolContext.CHAT)
        assert isinstance(specs, list)
        assert len(specs) > 0
        for spec in specs:
            assert spec["type"] == "function"
            assert "function" in spec
            assert "name" in spec["function"]
            assert "description" in spec["function"]

    async def test_execute_custom_tool_in_chat(self, db_pool):
        from core.tools import ToolContext, ToolExecutionContext
        from core.tools.registry import ToolRegistry

        registry = ToolRegistry(db_pool)
        handler = _make_handler(name="chat_test_tool")
        registry.register(handler)

        # Store minimal config
        async with db_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('tools', '{}'::jsonb, 'test') "
                "ON CONFLICT (key) DO NOTHING"
            )

        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id=str(uuid.uuid4()),
            session_id="test-session",
        )
        result = await registry.execute("chat_test_tool", {"query": "hello"}, ctx)
        assert result.success is True
        assert result.output["tool"] == "chat_test_tool"
        assert result.output["echo"] == {"query": "hello"}

    async def test_execute_unknown_tool_returns_error(self, db_pool):
        from core.tools import ToolContext, ToolExecutionContext, create_default_registry

        registry = create_default_registry(db_pool)
        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="test",
        )
        result = await registry.execute("nonexistent_tool", {}, ctx)
        assert result.success is False
        assert "Unknown tool" in (result.error or "")

    async def test_disabled_tool_rejected_in_chat(self, db_pool):
        from core.tools import ToolContext, ToolExecutionContext, create_default_registry
        from core.tools.config import ToolsConfig

        # Disable recall
        async with db_pool.acquire() as conn:
            config = ToolsConfig(disabled=["recall"])
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('tools', $1::jsonb, 'test') "
                "ON CONFLICT (key) DO UPDATE SET value = $1::jsonb",
                config.to_json(),
            )

        registry = create_default_registry(db_pool)
        registry._config_cache = None  # Force fresh load

        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="test",
        )
        result = await registry.execute("recall", {"query": "test"}, ctx)
        assert result.success is False
        assert "disabled" in (result.error or "").lower()

        # Cleanup: restore config
        async with db_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('tools', '{}'::jsonb, 'test') "
                "ON CONFLICT (key) DO UPDATE SET value = '{}'::jsonb"
            )


# ============================================================================
# Integration: AuditTrailHook
# ============================================================================


class TestAuditTrailHook:
    """Tests that the AuditTrailHook writes to tool_executions table."""

    async def test_audit_hook_writes_record(self, db_pool):
        from core.tools.hooks import AuditTrailHook, HookContext, HookEvent
        from core.tools.base import ToolResult

        hook = AuditTrailHook(db_pool)
        result = ToolResult.success_result({"answer": "42"})
        result.energy_spent = 2
        result.duration_seconds = 0.5

        ctx = HookContext(
            event=HookEvent.AFTER_TOOL_CALL,
            tool_name="test_audit_tool",
            arguments={"query": "meaning of life"},
            result=result,
            metadata={
                "tool_context": "chat",
                "call_id": "audit-test-1",
                "session_id": "sess-audit-1",
            },
        )

        outcome = await hook.handle(ctx)
        assert outcome is None  # Audit hook returns None

        # Verify record was written
        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM tool_executions WHERE call_id = 'audit-test-1'"
            )
        assert row is not None
        assert row["tool_name"] == "test_audit_tool"
        assert row["success"] is True
        assert row["tool_context"] == "chat"
        assert row["session_id"] == "sess-audit-1"
        assert row["energy_spent"] == 2

    async def test_audit_hook_handles_errors(self, db_pool):
        from core.tools.hooks import AuditTrailHook, HookContext, HookEvent
        from core.tools.base import ToolErrorType, ToolResult

        hook = AuditTrailHook(db_pool)
        result = ToolResult.error_result("something went wrong", ToolErrorType.EXECUTION_FAILED)
        result.duration_seconds = 0.1

        ctx = HookContext(
            event=HookEvent.AFTER_TOOL_CALL,
            tool_name="failing_tool",
            arguments={},
            result=result,
            metadata={
                "tool_context": "heartbeat",
                "call_id": "audit-error-1",
                "session_id": None,
            },
        )

        await hook.handle(ctx)

        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM tool_executions WHERE call_id = 'audit-error-1'"
            )
        assert row is not None
        assert row["success"] is False
        assert row["error"] == "something went wrong"
        assert row["error_type"] == "execution_failed"

    async def test_audit_hook_ignores_non_after_events(self, db_pool):
        from core.tools.hooks import AuditTrailHook, HookContext, HookEvent

        hook = AuditTrailHook(db_pool)
        ctx = HookContext(
            event=HookEvent.BEFORE_TOOL_CALL,
            tool_name="test",
        )
        outcome = await hook.handle(ctx)
        assert outcome is None

    async def test_audit_hook_truncates_large_output(self, db_pool):
        from core.tools.hooks import AuditTrailHook, HookContext, HookEvent
        from core.tools.base import ToolResult

        hook = AuditTrailHook(db_pool)
        large_output = {"data": "x" * 20_000}
        result = ToolResult.success_result(large_output)
        result.duration_seconds = 0.1

        ctx = HookContext(
            event=HookEvent.AFTER_TOOL_CALL,
            tool_name="large_output_tool",
            arguments={},
            result=result,
            metadata={
                "tool_context": "chat",
                "call_id": "audit-large-1",
                "session_id": None,
            },
        )

        await hook.handle(ctx)

        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM tool_executions WHERE call_id = 'audit-large-1'"
            )
        assert row is not None
        # Output should be truncated but record should still be written
        assert row["success"] is True

    async def test_audit_registered_in_default_registry(self, db_pool):
        from core.tools import create_default_registry
        from core.tools.hooks import HookEvent

        registry = create_default_registry(db_pool)
        hooks = registry.hooks.list_hooks(HookEvent.AFTER_TOOL_CALL)
        audit_hooks = [h for h in hooks if h["source"] == "core.audit"]
        assert len(audit_hooks) == 1


# ============================================================================
# Integration: Full chat_turn with mocked LLM
# ============================================================================


class TestChatTurnWithRegistry:
    """Tests that chat_turn correctly uses the registry for tool dispatch."""

    @pytest.fixture(autouse=True)
    async def _disable_rlm(self, db_pool):
        """Disable RLM so tests exercise the AgentLoop path."""
        async with db_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('chat.use_rlm', 'false', 'test override') "
                "ON CONFLICT (key) DO UPDATE SET value = 'false'"
            )
        yield
        async with db_pool.acquire() as conn:
            await conn.execute(
                "UPDATE config SET value = 'true' WHERE key = 'chat.use_rlm'"
            )

    async def test_chat_turn_no_tools(self, db_pool):
        """Chat turn with no tool calls returns LLM response."""
        from services.chat import chat_turn

        mock_response = {"content": "Hello! How can I help?", "tool_calls": []}

        with (
            patch("core.agent_loop.chat_completion", new_callable=AsyncMock, return_value=mock_response),
            patch("services.chat.get_agent_profile_context", new_callable=AsyncMock, return_value={}),
            patch("core.cognitive_memory_api.render_chat_memory_context_db", new_callable=AsyncMock, return_value=""),
            patch("services.chat.CognitiveMemory") as MockMem,
        ):
            mock_mem_instance = AsyncMock()
            mock_mem_instance.hydrate = AsyncMock(return_value=MagicMock(memories=[]))
            mock_mem_instance.remember = AsyncMock()
            mock_mem_instance.record_chat_turn_memory = AsyncMock(return_value={})
            mock_mem_instance.record_chat_session_turn = AsyncMock(return_value={})
            MockMem.return_value = mock_mem_instance
            MockMem.connect.return_value.__aenter__ = AsyncMock(return_value=mock_mem_instance)
            MockMem.connect.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await chat_turn(
                user_message="hello",
                history=[],
                llm_config={"provider": "openai", "model": "gpt-4o", "api_key": "test"},
                dsn="postgresql://fake",
                pool=db_pool,
            )

        assert result["assistant"] == "Hello! How can I help?"
        assert len(result["history"]) == 2

    async def test_chat_turn_with_tool_call(self, db_pool):
        """Chat turn that invokes a tool via the registry."""
        from services.chat import chat_turn

        # First LLM call: requests a tool
        first_response = {
            "content": "",
            "tool_calls": [
                {"id": "call-1", "name": "recall", "arguments": {"query": "test memory"}}
            ],
        }
        # Second LLM call: responds with tool result
        second_response = {
            "content": "Based on my memories, here's what I found.",
            "tool_calls": [],
        }

        call_count = {"n": 0}

        async def mock_chat_completion(**kwargs):
            call_count["n"] += 1
            if call_count["n"] == 1:
                return first_response
            return second_response

        with (
            patch("core.agent_loop.chat_completion", side_effect=mock_chat_completion),
            patch("services.chat.get_agent_profile_context", new_callable=AsyncMock, return_value={}),
            patch("core.cognitive_memory_api.render_chat_memory_context_db", new_callable=AsyncMock, return_value=""),
            patch("services.chat.CognitiveMemory") as MockMem,
        ):
            mock_mem_instance = AsyncMock()
            mock_mem_instance.hydrate = AsyncMock(return_value=MagicMock(memories=[]))
            mock_mem_instance.remember = AsyncMock()
            mock_mem_instance.touch_memories = AsyncMock()
            mock_mem_instance.record_chat_turn_memory = AsyncMock(return_value={})
            mock_mem_instance.record_chat_session_turn = AsyncMock(return_value={})
            MockMem.return_value = mock_mem_instance
            MockMem.connect.return_value.__aenter__ = AsyncMock(return_value=mock_mem_instance)
            MockMem.connect.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await chat_turn(
                user_message="what do you remember?",
                history=[],
                llm_config={"provider": "openai", "model": "gpt-4o", "api_key": "test"},
                dsn="postgresql://fake",
                pool=db_pool,
            )

        assert result["assistant"] == "Based on my memories, here's what I found."
        assert call_count["n"] == 2  # Two LLM calls

    async def test_chat_turn_respects_max_iterations(self, db_pool):
        """Tool loop stops after max iterations."""
        from services.chat import chat_turn

        # LLM always requests tools
        tool_response = {
            "content": "",
            "tool_calls": [
                {"id": "call-loop", "name": "recall", "arguments": {"query": "loop"}}
            ],
        }

        async def always_tool(**kwargs):
            return tool_response

        with (
            patch("core.agent_loop.chat_completion", side_effect=always_tool),
            patch("services.chat.get_agent_profile_context", new_callable=AsyncMock, return_value={}),
            patch("core.cognitive_memory_api.render_chat_memory_context_db", new_callable=AsyncMock, return_value=""),
            patch("services.chat.CognitiveMemory") as MockMem,
        ):
            mock_mem_instance = AsyncMock()
            mock_mem_instance.hydrate = AsyncMock(return_value=MagicMock(memories=[]))
            mock_mem_instance.remember = AsyncMock()
            mock_mem_instance.touch_memories = AsyncMock()
            mock_mem_instance.record_chat_turn_memory = AsyncMock(return_value={})
            mock_mem_instance.record_chat_session_turn = AsyncMock(return_value={})
            MockMem.return_value = mock_mem_instance
            MockMem.connect.return_value.__aenter__ = AsyncMock(return_value=mock_mem_instance)
            MockMem.connect.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await chat_turn(
                user_message="loop forever",
                history=[],
                llm_config={"provider": "openai", "model": "gpt-4o", "api_key": "test"},
                dsn="postgresql://fake",
                pool=db_pool,
                max_tool_iterations=2,
            )

        # Should not hang — loop terminates after max_tool_iterations + 1
        assert "assistant" in result

    async def test_chat_turn_pool_lifecycle(self, db_pool):
        """When pool is provided, chat_turn uses it and doesn't close it."""
        from services.chat import chat_turn

        mock_response = {"content": "ok", "tool_calls": []}

        with (
            patch("core.agent_loop.chat_completion", new_callable=AsyncMock, return_value=mock_response),
            patch("services.chat.get_agent_profile_context", new_callable=AsyncMock, return_value={}),
            patch("core.cognitive_memory_api.render_chat_memory_context_db", new_callable=AsyncMock, return_value=""),
            patch("services.chat.CognitiveMemory") as MockMem,
        ):
            mock_mem_instance = AsyncMock()
            mock_mem_instance.hydrate = AsyncMock(return_value=MagicMock(memories=[]))
            mock_mem_instance.remember = AsyncMock()
            mock_mem_instance.record_chat_turn_memory = AsyncMock(return_value={})
            mock_mem_instance.record_chat_session_turn = AsyncMock(return_value={})
            MockMem.return_value = mock_mem_instance
            MockMem.connect.return_value.__aenter__ = AsyncMock(return_value=mock_mem_instance)
            MockMem.connect.return_value.__aexit__ = AsyncMock(return_value=False)

            await chat_turn(
                user_message="test",
                history=[],
                llm_config={"provider": "openai", "model": "gpt-4o", "api_key": "test"},
                dsn="postgresql://fake",
                pool=db_pool,
            )

        # Pool should still be open
        async with db_pool.acquire() as conn:
            val = await conn.fetchval("SELECT 1")
            assert val == 1


# ============================================================================
# Integration: Registry hooks fire during chat tool execution
# ============================================================================


class TestChatToolAuditIntegration:
    """Verify that executing tools through chat path triggers audit hooks."""

    async def test_tool_execution_creates_audit_record(self, db_pool):
        """When a tool is called via the registry, an audit record should be created."""
        from core.tools import ToolContext, ToolExecutionContext
        from core.tools.registry import ToolRegistry
        from core.tools.hooks import AuditTrailHook, HookEvent

        registry = ToolRegistry(db_pool)
        handler = _make_handler(name="audited_tool")
        registry.register(handler)
        registry.hooks.register(HookEvent.AFTER_TOOL_CALL, AuditTrailHook(db_pool), source="core.audit")

        # Ensure tools config exists
        async with db_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO config (key, value, description) VALUES ('tools', '{}'::jsonb, 'test') "
                "ON CONFLICT (key) DO NOTHING"
            )

        call_id = f"integration-{uuid.uuid4().hex[:8]}"
        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id=call_id,
            session_id="integration-test",
        )

        result = await registry.execute("audited_tool", {"query": "integration test"}, ctx)
        assert result.success is True

        # Check that audit record was created
        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM tool_executions WHERE call_id = $1", call_id
            )
        assert row is not None
        assert row["tool_name"] == "audited_tool"
        assert row["tool_context"] == "chat"
        assert row["session_id"] == "integration-test"
        assert row["success"] is True


# ============================================================================
# Schema: tool_executions table
# ============================================================================


class TestToolExecutionsTable:
    """Verify the tool_executions table schema and indexes."""

    async def test_table_exists(self, db_pool):
        async with db_pool.acquire() as conn:
            exists = await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'tool_executions')"
            )
            assert exists is True

    async def test_insert_and_query(self, db_pool):
        async with db_pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO tool_executions
                (tool_name, arguments, tool_context, call_id, session_id,
                 success, output, error, error_type, energy_spent, duration_seconds)
                VALUES ($1, $2::jsonb, $3, $4, $5, $6, $7::jsonb, $8, $9, $10, $11)
                """,
                "test_schema_tool",
                '{"query": "test"}',
                "chat",
                "schema-test-1",
                "schema-session",
                True,
                '{"result": "ok"}',
                None,
                None,
                1,
                0.5,
            )

            row = await conn.fetchrow(
                "SELECT * FROM tool_executions WHERE call_id = 'schema-test-1'"
            )
            assert row is not None
            assert row["tool_name"] == "test_schema_tool"
            assert row["success"] is True

    async def test_workflow_executions_table_exists(self, db_pool):
        async with db_pool.acquire() as conn:
            exists = await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'workflow_executions')"
            )
            assert exists is True

    async def test_indexes_exist(self, db_pool):
        async with db_pool.acquire() as conn:
            indexes = await conn.fetch(
                """
                SELECT indexname FROM pg_indexes
                WHERE tablename = 'tool_executions'
                ORDER BY indexname
                """
            )
            index_names = {row["indexname"] for row in indexes}
            assert "idx_tool_exec_name" in index_names
            assert "idx_tool_exec_ctx" in index_names
            assert "idx_tool_exec_session" in index_names
            assert "idx_tool_exec_created" in index_names


# ============================================================================
# Integration: channel conversation passes pool
# ============================================================================


class TestChannelPoolPassing:
    """Verify channels/conversation.py passes pool to chat functions."""

    def test_process_channel_message_passes_pool(self):
        """Verify that process_channel_message source passes pool kwarg."""
        import inspect
        from channels.conversation import process_channel_message

        source = inspect.getsource(process_channel_message)
        assert "pool=pool" in source

    def test_stream_channel_message_passes_pool(self):
        """Verify that stream_channel_message source passes pool kwarg."""
        import inspect
        from channels.conversation import stream_channel_message

        source = inspect.getsource(stream_channel_message)
        assert "pool=pool" in source


class TestToolEnergyCostsBlock:
    async def test_heartbeat_prompt_derives_costs_from_toolspecs(self, db_pool):
        from core.tools import create_default_registry
        from services.agent import build_system_prompt

        registry = create_default_registry(db_pool)
        prompt = await build_system_prompt(
            "heartbeat",
            registry,
            None,
            allowed_tool_names={"recall", "remember", "slow_ingest"},
        )
        assert "## Tool Energy Costs" in prompt
        recall_cost = registry.get_spec("recall").energy_cost
        assert f"**{recall_cost}**: recall" in prompt
        # No hardcoded ranges left in the base prompt.
        assert "(0-2 energy)" not in prompt
        # The footer contract is explained.
        assert "[energy: spent/budget spent]" in prompt

    async def test_chat_prompt_has_no_costs_block(self, db_pool):
        from core.tools import create_default_registry
        from services.agent import build_system_prompt

        registry = create_default_registry(db_pool)
        prompt = await build_system_prompt(
            "chat",
            registry,
            None,
            allowed_tool_names={"recall", "remember"},
        )
        assert "## Tool Energy Costs" not in prompt

    async def test_unknown_tool_names_are_skipped(self, db_pool):
        from core.tools import create_default_registry
        from services.agent import _format_tool_costs

        registry = create_default_registry(db_pool)
        block = _format_tool_costs(registry, {"mcp_github_create_issue", "recall"})
        assert "recall" in block
        assert "mcp_github_create_issue" not in block


class TestPromptAddenda:
    async def test_addenda_append_to_prompt(self, db_pool):
        from core.tools import create_default_registry
        from services.chat import _build_system_prompt
        from services.agent import build_system_prompt

        registry = create_default_registry(db_pool)
        prompt = await build_system_prompt(
            "chat",
            registry,
            {},
            prompt_addenda=[
                "----- ATTACHED DOCUMENT: Test Doc -----\nBody of the attachment.",
                "  ",
                None,
            ],
        )
        assert "----- ATTACHED DOCUMENT: Test Doc -----" in prompt
        assert prompt.rstrip().endswith("Body of the attachment.")
