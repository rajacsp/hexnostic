"""
Tests for Phase 4: Workflow Orchestration

Covers WorkflowHandler: linear workflows, DAG with parallel steps,
error handling (stop/skip/retry), template substitution, energy
accounting, dependency validation, and DB tracking.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from core.tools.workflow import (
    WorkflowHandler,
    WorkflowPlan,
    WorkflowStep,
    WorkflowStepResult,
    _resolve_templates,
    _topological_layers,
    create_workflow_tools,
)
from core.tools.registry import ToolRegistry, ToolRegistryBuilder

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Test tools: simple handlers for workflow testing
# ============================================================================


class EchoHandler(ToolHandler):
    """Returns its arguments as output."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="echo",
            description="Returns arguments as output",
            parameters={"type": "object", "properties": {
                "message": {"type": "string"},
            }},
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return ToolResult.success_result(arguments)


class UpperHandler(ToolHandler):
    """Uppercases input text."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="upper",
            description="Uppercases input text",
            parameters={"type": "object", "properties": {
                "text": {"type": "string"},
            }, "required": ["text"]},
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        text = arguments.get("text", "")
        return ToolResult.success_result({"result": text.upper()})


class FailHandler(ToolHandler):
    """Always fails."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="fail",
            description="Always fails",
            parameters={"type": "object", "properties": {}},
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        return ToolResult.error_result("Intentional failure")


class CounterHandler(ToolHandler):
    """Increments a shared counter. Useful for testing parallel execution."""

    call_count: int = 0

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="counter",
            description="Increments counter",
            parameters={"type": "object", "properties": {}},
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        CounterHandler.call_count += 1
        return ToolResult.success_result({"count": CounterHandler.call_count})


def _make_registry(pool) -> ToolRegistry:
    """Build a test registry with echo, upper, fail, counter tools."""
    builder = ToolRegistryBuilder(pool)
    builder.add(EchoHandler())
    builder.add(UpperHandler())
    builder.add(FailHandler())
    builder.add(CounterHandler())
    return builder.build()


def _make_context(registry: ToolRegistry, session_id: str | None = None) -> ToolExecutionContext:
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id=str(uuid.uuid4()),
        session_id=session_id or f"test-wf-{uuid.uuid4().hex[:8]}",
        registry=registry,
    )


# ============================================================================
# Unit tests: template resolution
# ============================================================================


class TestTemplateResolution:
    def test_simple_output_reference(self):
        result = _resolve_templates(
            {"text": "{{step1.output}}"},
            {"step1": "hello"},
        )
        assert result["text"] == "hello"

    def test_nested_key_reference(self):
        result = _resolve_templates(
            {"text": "{{step1.output.name}}"},
            {"step1": {"name": "Alice", "age": 30}},
        )
        assert result["text"] == "Alice"

    def test_embedded_template(self):
        result = _resolve_templates(
            {"text": "Hello {{step1.output.name}}, welcome!"},
            {"step1": {"name": "Bob"}},
        )
        assert result["text"] == "Hello Bob, welcome!"

    def test_missing_step_unchanged(self):
        result = _resolve_templates(
            {"text": "{{unknown.output}}"},
            {},
        )
        assert result["text"] == "{{unknown.output}}"

    def test_non_string_passthrough(self):
        result = _resolve_templates(
            {"count": 5, "flag": True},
            {},
        )
        assert result == {"count": 5, "flag": True}

    def test_full_value_replacement_preserves_type(self):
        result = _resolve_templates(
            {"data": "{{step1.output}}"},
            {"step1": {"key": "value", "num": 42}},
        )
        # Full match should preserve dict type, not stringify
        assert result["data"] == {"key": "value", "num": 42}

    def test_nested_dict_resolution(self):
        result = _resolve_templates(
            {"outer": {"inner": "{{s1.output}}"}},
            {"s1": "resolved"},
        )
        assert result["outer"]["inner"] == "resolved"

    def test_list_resolution(self):
        result = _resolve_templates(
            {"items": ["{{s1.output}}", "static", "{{s2.output}}"]},
            {"s1": "first", "s2": "third"},
        )
        assert result["items"] == ["first", "static", "third"]


# ============================================================================
# Unit tests: topological sort
# ============================================================================


class TestTopologicalSort:
    def test_linear_chain(self):
        steps = [
            WorkflowStep(name="a", tool="echo", arguments={}),
            WorkflowStep(name="b", tool="echo", arguments={}, depends_on=["a"]),
            WorkflowStep(name="c", tool="echo", arguments={}, depends_on=["b"]),
        ]
        layers = _topological_layers(steps)
        assert len(layers) == 3
        assert [s.name for s in layers[0]] == ["a"]
        assert [s.name for s in layers[1]] == ["b"]
        assert [s.name for s in layers[2]] == ["c"]

    def test_parallel_independent_steps(self):
        steps = [
            WorkflowStep(name="a", tool="echo", arguments={}),
            WorkflowStep(name="b", tool="echo", arguments={}),
            WorkflowStep(name="c", tool="echo", arguments={}),
        ]
        layers = _topological_layers(steps)
        # All in one layer since no dependencies
        assert len(layers) == 1
        names = {s.name for s in layers[0]}
        assert names == {"a", "b", "c"}

    def test_diamond_dag(self):
        steps = [
            WorkflowStep(name="start", tool="echo", arguments={}),
            WorkflowStep(name="left", tool="echo", arguments={}, depends_on=["start"]),
            WorkflowStep(name="right", tool="echo", arguments={}, depends_on=["start"]),
            WorkflowStep(name="end", tool="echo", arguments={}, depends_on=["left", "right"]),
        ]
        layers = _topological_layers(steps)
        assert len(layers) == 3
        assert {s.name for s in layers[0]} == {"start"}
        assert {s.name for s in layers[1]} == {"left", "right"}
        assert {s.name for s in layers[2]} == {"end"}

    def test_circular_dependency_raises(self):
        steps = [
            WorkflowStep(name="a", tool="echo", arguments={}, depends_on=["b"]),
            WorkflowStep(name="b", tool="echo", arguments={}, depends_on=["a"]),
        ]
        with pytest.raises(ValueError, match="Circular dependency"):
            _topological_layers(steps)

    def test_missing_dependency_raises(self):
        steps = [
            WorkflowStep(name="a", tool="echo", arguments={}, depends_on=["nonexistent"]),
        ]
        with pytest.raises(ValueError, match="unknown step"):
            _topological_layers(steps)


# ============================================================================
# Integration tests: workflow execution
# ============================================================================


class TestLinearWorkflow:
    async def test_three_step_linear(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "test-linear",
                "description": "A simple 3-step workflow",
                "steps": [
                    {"name": "greet", "tool": "echo", "arguments": {"message": "hello"}},
                    {"name": "transform", "tool": "upper", "arguments": {"text": "{{greet.output.message}}"}, "depends_on": ["greet"]},
                    {"name": "final", "tool": "echo", "arguments": {"result": "{{transform.output.result}}"}, "depends_on": ["transform"]},
                ],
            },
            ctx,
        )

        assert result.success is True
        assert result.output["status"] == "completed"
        assert len(result.output["steps"]) == 3

        # Step 1: echo returns {"message": "hello"}
        assert result.output["steps"][0]["success"] is True
        assert result.output["steps"][0]["output"]["message"] == "hello"

        # Step 2: upper returns {"result": "HELLO"}
        assert result.output["steps"][1]["success"] is True
        assert result.output["steps"][1]["output"]["result"] == "HELLO"

        # Step 3: echo with resolved template
        assert result.output["steps"][2]["success"] is True
        assert result.output["steps"][2]["output"]["result"] == "HELLO"


class TestParallelWorkflow:
    async def test_independent_steps_all_execute(self, db_pool):
        CounterHandler.call_count = 0
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "test-parallel",
                "steps": [
                    {"name": "a", "tool": "counter", "arguments": {}},
                    {"name": "b", "tool": "counter", "arguments": {}},
                    {"name": "c", "tool": "counter", "arguments": {}},
                ],
            },
            ctx,
        )

        assert result.success is True
        assert len(result.output["steps"]) == 3
        assert all(s["success"] for s in result.output["steps"])
        # All three should have executed
        assert CounterHandler.call_count == 3


class TestDAGWorkflow:
    async def test_diamond_dag(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "diamond",
                "steps": [
                    {"name": "start", "tool": "echo", "arguments": {"val": "root"}},
                    {"name": "left", "tool": "upper", "arguments": {"text": "{{start.output.val}}"}, "depends_on": ["start"]},
                    {"name": "right", "tool": "echo", "arguments": {"text": "{{start.output.val}}"}, "depends_on": ["start"]},
                    {"name": "merge", "tool": "echo", "arguments": {"left": "{{left.output.result}}", "right": "{{right.output.text}}"}, "depends_on": ["left", "right"]},
                ],
            },
            ctx,
        )

        assert result.success is True
        merge_output = result.output["steps"][3]["output"]
        assert merge_output["left"] == "ROOT"
        assert merge_output["right"] == "root"


# ============================================================================
# Error handling
# ============================================================================


class TestErrorHandling:
    async def test_stop_on_error(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "stop-test",
                "steps": [
                    {"name": "ok", "tool": "echo", "arguments": {"msg": "fine"}},
                    {"name": "boom", "tool": "fail", "arguments": {}, "depends_on": ["ok"], "on_error": "stop"},
                    {"name": "after", "tool": "echo", "arguments": {}, "depends_on": ["boom"]},
                ],
            },
            ctx,
        )

        assert result.success is False
        assert result.output["status"] == "failed"
        steps = result.output["steps"]
        assert steps[0]["success"] is True
        assert steps[1]["success"] is False
        assert steps[2]["skipped"] is True

    async def test_skip_on_error(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "skip-test",
                "steps": [
                    {"name": "boom", "tool": "fail", "arguments": {}, "on_error": "skip"},
                    {"name": "after", "tool": "echo", "arguments": {"msg": "ok"}, "depends_on": ["boom"]},
                ],
            },
            ctx,
        )

        # Workflow continues past the failed step
        steps = result.output["steps"]
        assert steps[0]["success"] is False
        assert steps[1]["success"] is True

    async def test_retry_on_error(self, db_pool):
        """Retry still fails (FailHandler always fails), but retries field is set."""
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "retry-test",
                "steps": [
                    {"name": "flaky", "tool": "fail", "arguments": {}, "on_error": "retry"},
                ],
            },
            ctx,
        )

        # Default max_retries=1 so only 1 attempt
        assert result.output["steps"][0]["retries"] == 1


# ============================================================================
# Validation
# ============================================================================


class TestValidation:
    async def test_empty_steps_rejected(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {"name": "empty", "steps": []},
            ctx,
        )
        assert result.success is False
        assert "at least one step" in result.error

    async def test_duplicate_step_names_rejected(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "dupes",
                "steps": [
                    {"name": "a", "tool": "echo", "arguments": {}},
                    {"name": "a", "tool": "echo", "arguments": {}},
                ],
            },
            ctx,
        )
        assert result.success is False
        assert "unique" in result.error

    async def test_circular_dependency_rejected(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "circular",
                "steps": [
                    {"name": "a", "tool": "echo", "arguments": {}, "depends_on": ["b"]},
                    {"name": "b", "tool": "echo", "arguments": {}, "depends_on": ["a"]},
                ],
            },
            ctx,
        )
        assert result.success is False
        assert "Circular" in result.error

    async def test_no_registry_in_context(self, db_pool):
        handler = WorkflowHandler()
        ctx = ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="test",
            registry=None,
        )

        result = await handler.execute(
            {"name": "no-reg", "steps": [{"name": "a", "tool": "echo"}]},
            ctx,
        )
        assert result.success is False
        assert "registry" in result.error.lower()


# ============================================================================
# Energy accounting
# ============================================================================


class TestEnergyAccounting:
    async def test_total_energy_summed(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "energy-test",
                "steps": [
                    {"name": "a", "tool": "echo", "arguments": {}},
                    {"name": "b", "tool": "counter", "arguments": {}, "depends_on": ["a"]},
                ],
            },
            ctx,
        )

        assert result.success is True
        # echo costs 1, counter costs 2 = 3 total
        assert result.output["total_energy_spent"] >= 2  # At least both tools ran


# ============================================================================
# DB tracking
# ============================================================================


class TestDBTracking:
    async def test_workflow_recorded_in_db(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry, session_id="db-track-test")

        result = await handler.execute(
            {
                "name": "tracked-workflow",
                "steps": [
                    {"name": "step1", "tool": "echo", "arguments": {"msg": "hi"}},
                ],
            },
            ctx,
        )

        assert result.success is True
        workflow_id = result.output["workflow_id"]
        assert workflow_id is not None

        # Verify DB record
        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM workflow_executions WHERE id = $1",
                uuid.UUID(workflow_id),
            )
            assert row is not None
            assert row["name"] == "tracked-workflow"
            assert row["status"] == "completed"
            assert row["session_id"] == "db-track-test"
            assert row["completed_at"] is not None

    async def test_failed_workflow_recorded(self, db_pool):
        registry = _make_registry(db_pool)
        handler = WorkflowHandler()
        ctx = _make_context(registry)

        result = await handler.execute(
            {
                "name": "failed-workflow",
                "steps": [
                    {"name": "boom", "tool": "fail", "arguments": {}, "on_error": "stop"},
                ],
            },
            ctx,
        )

        assert result.success is False
        workflow_id = result.output["workflow_id"]

        async with db_pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM workflow_executions WHERE id = $1",
                uuid.UUID(workflow_id),
            )
            assert row["status"] == "failed"
            assert row["error"] is not None


# ============================================================================
# Spec and factory
# ============================================================================


class TestSpecAndFactory:
    def test_spec_basics(self):
        handler = WorkflowHandler()
        spec = handler.spec
        assert spec.name == "execute_workflow"
        assert spec.category == ToolCategory.EXTERNAL
        assert spec.is_read_only is False
        assert ToolContext.CHAT in spec.allowed_contexts

    def test_factory(self):
        tools = create_workflow_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], WorkflowHandler)

    async def test_registered_in_default_registry(self, db_pool):
        from core.tools.registry import create_default_registry

        registry = create_default_registry(db_pool)
        specs = await registry.get_specs(ToolContext.CHAT)
        names = [s["function"]["name"] for s in specs]
        assert "execute_workflow" in names


# ============================================================================
# WorkflowPlan serialization
# ============================================================================


class TestPlanSerialization:
    def test_round_trip(self):
        plan = WorkflowPlan(
            name="test",
            description="A test plan",
            steps=[
                WorkflowStep(name="s1", tool="echo", arguments={"x": 1}),
                WorkflowStep(name="s2", tool="upper", arguments={"text": "hi"}, depends_on=["s1"]),
            ],
        )
        d = plan.to_dict()
        restored = WorkflowPlan.from_dict(d)
        assert restored.name == plan.name
        assert restored.description == plan.description
        assert len(restored.steps) == 2
        assert restored.steps[1].depends_on == ["s1"]
