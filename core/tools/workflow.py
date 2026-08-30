"""
Hexis Tools System - Workflow Orchestration

Multi-step tool chaining with dependency resolution, error handling,
parallel execution of independent steps, and template substitution
from previous step outputs.
"""

from __future__ import annotations

import json
import logging
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, TYPE_CHECKING

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

if TYPE_CHECKING:
    from .registry import ToolRegistry

logger = logging.getLogger(__name__)

# Template pattern: {{step_name.output}} or {{step_name.output.key}}
_TEMPLATE_RE = re.compile(r"\{\{(\w+)\.output(?:\.(\w+))?\}\}")


@dataclass
class WorkflowStep:
    """A single step in a workflow plan."""

    name: str
    tool: str  # Tool name to execute
    arguments: dict[str, Any]
    depends_on: list[str] = field(default_factory=list)
    on_error: str = "stop"  # "stop", "skip", "retry"
    max_retries: int = 1


@dataclass
class WorkflowStepResult:
    """Result of executing a single workflow step."""

    name: str
    tool: str
    success: bool
    output: Any = None
    error: str | None = None
    duration_seconds: float = 0.0
    energy_spent: int = 0
    skipped: bool = False
    retries: int = 0


@dataclass
class WorkflowPlan:
    """A complete workflow plan."""

    name: str
    description: str
    steps: list[WorkflowStep]

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "steps": [
                {
                    "name": s.name,
                    "tool": s.tool,
                    "arguments": s.arguments,
                    "depends_on": s.depends_on,
                    "on_error": s.on_error,
                    "max_retries": s.max_retries,
                }
                for s in self.steps
            ],
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "WorkflowPlan":
        steps = [
            WorkflowStep(
                name=s["name"],
                tool=s["tool"],
                arguments=s.get("arguments", {}),
                depends_on=s.get("depends_on", []),
                on_error=s.get("on_error", "stop"),
                max_retries=s.get("max_retries", 1),
            )
            for s in data.get("steps", [])
        ]
        return cls(
            name=data["name"],
            description=data.get("description", ""),
            steps=steps,
        )


def _resolve_templates(
    arguments: dict[str, Any],
    step_outputs: dict[str, Any],
) -> dict[str, Any]:
    """
    Resolve {{step_name.output}} and {{step_name.output.key}} templates.

    Walks all string values in the arguments dict and replaces template
    references with actual outputs from completed steps.
    """

    def _resolve_value(val: Any) -> Any:
        if isinstance(val, str):
            # Check for full-value replacement (entire string is one template)
            full_match = _TEMPLATE_RE.fullmatch(val)
            if full_match:
                step_name, key = full_match.group(1), full_match.group(2)
                output = step_outputs.get(step_name)
                if key and isinstance(output, dict):
                    return output.get(key, val)
                return output if output is not None else val

            # Partial replacement (template embedded in larger string)
            def _replacer(m: re.Match) -> str:
                step_name, key = m.group(1), m.group(2)
                output = step_outputs.get(step_name)
                if key and isinstance(output, dict):
                    return str(output.get(key, m.group(0)))
                return str(output) if output is not None else m.group(0)

            return _TEMPLATE_RE.sub(_replacer, val)
        elif isinstance(val, dict):
            return {k: _resolve_value(v) for k, v in val.items()}
        elif isinstance(val, list):
            return [_resolve_value(item) for item in val]
        return val

    return _resolve_value(arguments)


def _topological_layers(steps: list[WorkflowStep]) -> list[list[WorkflowStep]]:
    """
    Sort steps into topological layers for dependency-ordered execution.

    Each layer contains steps whose dependencies are all in previous layers.
    Steps within the same layer can execute in parallel.

    Raises ValueError if the dependency graph has cycles or missing deps.
    """
    step_map = {s.name: s for s in steps}
    all_names = set(step_map.keys())

    # Validate dependencies
    for step in steps:
        for dep in step.depends_on:
            if dep not in all_names:
                raise ValueError(
                    f"Step '{step.name}' depends on unknown step '{dep}'"
                )

    remaining = set(all_names)
    satisfied = set()
    layers: list[list[WorkflowStep]] = []

    while remaining:
        # Find steps whose deps are all satisfied
        layer = [
            step_map[name]
            for name in remaining
            if all(dep in satisfied for dep in step_map[name].depends_on)
        ]

        if not layer:
            raise ValueError(
                f"Circular dependency detected among steps: {remaining}"
            )

        layers.append(layer)
        for step in layer:
            remaining.discard(step.name)
            satisfied.add(step.name)

    return layers


class WorkflowHandler(ToolHandler):
    """Execute multi-step workflow plans with dependency resolution."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="execute_workflow",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Execute a multi-step workflow: define steps with tool calls, "
                "dependencies between steps, and error handling. Steps run in "
                "dependency order; independent steps execute in parallel. "
                "Use {{step_name.output}} in arguments to reference previous outputs."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Workflow name for tracking",
                    },
                    "description": {
                        "type": "string",
                        "description": "Brief description of what the workflow does",
                    },
                    "steps": {
                        "type": "array",
                        "description": "Ordered list of workflow steps",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {
                                    "type": "string",
                                    "description": "Unique step name for dependency references",
                                },
                                "tool": {
                                    "type": "string",
                                    "description": "Tool name to execute",
                                },
                                "arguments": {
                                    "type": "object",
                                    "description": "Tool arguments (may include {{step.output}} templates)",
                                },
                                "depends_on": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": "Step names this step depends on",
                                },
                                "on_error": {
                                    "type": "string",
                                    "enum": ["stop", "skip", "retry"],
                                    "description": "Error handling: stop (abort workflow), skip (continue), retry (retry once)",
                                },
                            },
                            "required": ["name", "tool"],
                        },
                    },
                },
                "required": ["name", "steps"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,  # Base cost; actual = sum of step costs
            is_read_only=False,
            requires_approval=False,
            supports_parallel=False,
            allowed_contexts={ToolContext.CHAT, ToolContext.HEARTBEAT},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        registry: ToolRegistry | None = context.registry
        if not registry:
            return ToolResult.error_result(
                "Workflow execution requires a registry reference in context",
                ToolErrorType.MISSING_CONFIG,
            )

        # Parse plan
        try:
            plan = WorkflowPlan.from_dict(arguments)
        except (KeyError, TypeError) as e:
            return ToolResult.error_result(
                f"Invalid workflow plan: {e}",
                ToolErrorType.INVALID_PARAMS,
            )

        if not plan.steps:
            return ToolResult.error_result(
                "Workflow must have at least one step",
                ToolErrorType.INVALID_PARAMS,
            )

        # Validate step names are unique
        names = [s.name for s in plan.steps]
        if len(names) != len(set(names)):
            return ToolResult.error_result(
                "Workflow step names must be unique",
                ToolErrorType.INVALID_PARAMS,
            )

        # Build dependency layers in DB; Python fallback keeps mocked/non-DB
        # contexts compatible.
        try:
            layers = await self._build_layers(registry, plan)
        except ValueError as e:
            return ToolResult.error_result(str(e), ToolErrorType.INVALID_PARAMS)

        # Track workflow in DB
        workflow_id = await self._create_workflow_record(
            registry, plan, context.session_id
        )

        # Execute layers
        step_outputs: dict[str, Any] = {}
        step_results: list[WorkflowStepResult] = {}
        step_results = []
        total_energy = 0
        total_duration = 0.0
        aborted = False
        abort_reason = ""

        for layer in layers:
            if aborted:
                # Mark remaining steps as skipped
                for step in layer:
                    step_results.append(
                        WorkflowStepResult(
                            name=step.name,
                            tool=step.tool,
                            success=False,
                            error=f"Skipped due to abort: {abort_reason}",
                            skipped=True,
                        )
                    )
                continue

            # Execute steps in this layer
            layer_results = await self._execute_layer(
                layer, step_outputs, registry, context
            )

            for step, result in layer_results:
                step_results.append(result)
                total_energy += result.energy_spent
                total_duration += result.duration_seconds

                if result.success:
                    step_outputs[step.name] = result.output
                elif result.skipped:
                    step_outputs[step.name] = None
                else:
                    # Handle error based on on_error policy
                    if step.on_error == "stop":
                        aborted = True
                        abort_reason = f"Step '{step.name}' failed: {result.error}"
                    elif step.on_error == "skip":
                        step_outputs[step.name] = None
                    # "retry" already handled in _execute_layer

        # Determine overall status
        any_failed = any(
            not r.success and not r.skipped for r in step_results
        )
        status = "failed" if aborted or any_failed else "completed"

        # Update workflow record
        await self._update_workflow_record(
            registry, workflow_id, status, step_results, total_energy
        )

        # Build summary
        summary = {
            "workflow_id": str(workflow_id) if workflow_id else None,
            "name": plan.name,
            "status": status,
            "steps": [
                {
                    "name": r.name,
                    "tool": r.tool,
                    "success": r.success,
                    "skipped": r.skipped,
                    "output": r.output,
                    "error": r.error,
                    "duration_seconds": r.duration_seconds,
                    "energy_spent": r.energy_spent,
                    "retries": r.retries,
                }
                for r in step_results
            ],
            "total_energy_spent": total_energy,
            "total_duration_seconds": round(total_duration, 3),
        }

        if status == "completed":
            return ToolResult.success_result(
                summary,
                display_output=(
                    f"Workflow '{plan.name}' completed: "
                    f"{len(step_results)} steps, {total_energy} energy, "
                    f"{total_duration:.2f}s"
                ),
            )
        else:
            return ToolResult(
                success=False,
                output=summary,
                error=abort_reason or "One or more steps failed",
                display_output=(
                    f"Workflow '{plan.name}' {status}: {abort_reason}"
                ),
            )

    async def _execute_layer(
        self,
        layer: list[WorkflowStep],
        step_outputs: dict[str, Any],
        registry: "ToolRegistry",
        parent_context: ToolExecutionContext,
    ) -> list[tuple[WorkflowStep, WorkflowStepResult]]:
        """Execute all steps in a layer, parallelizing where possible."""
        import asyncio

        if len(layer) == 1:
            # Single step — run directly
            step = layer[0]
            result = await self._execute_step(
                step, step_outputs, registry, parent_context
            )
            return [(step, result)]

        # Multiple steps — run in parallel
        tasks = [
            self._execute_step(step, step_outputs, registry, parent_context)
            for step in layer
        ]
        results = await asyncio.gather(*tasks)
        return list(zip(layer, results))

    async def _build_layers(
        self,
        registry: "ToolRegistry",
        plan: WorkflowPlan,
    ) -> list[list[WorkflowStep]]:
        try:
            async with registry.pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT workflow_plan_layers($1::jsonb)",
                    json.dumps(plan.to_dict()),
                )
            payload = json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(payload, list):
                return [
                    [
                        WorkflowStep(
                            name=step["name"],
                            tool=step["tool"],
                            arguments=step.get("arguments", {}),
                            depends_on=step.get("depends_on", []),
                            on_error=step.get("on_error", "stop"),
                            max_retries=step.get("max_retries", 1),
                        )
                        for step in layer
                    ]
                    for layer in payload
                ]
        except Exception as exc:
            message = str(exc)
            if "Circular dependency" in message or "unknown step" in message or "unique" in message:
                raise ValueError(message) from exc
            logger.debug("DB workflow layer planning unavailable; falling back to Python", exc_info=True)
        return _topological_layers(plan.steps)

    async def _resolve_step_arguments(
        self,
        registry: "ToolRegistry",
        arguments: dict[str, Any],
        step_outputs: dict[str, Any],
    ) -> dict[str, Any]:
        try:
            async with registry.pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT resolve_workflow_templates($1::jsonb, $2::jsonb)",
                    json.dumps(arguments),
                    json.dumps(step_outputs),
                )
            payload = json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(payload, dict):
                return payload
        except Exception:
            logger.debug("DB workflow template resolution unavailable; falling back to Python", exc_info=True)
        return _resolve_templates(arguments, step_outputs)

    async def _execute_step(
        self,
        step: WorkflowStep,
        step_outputs: dict[str, Any],
        registry: "ToolRegistry",
        parent_context: ToolExecutionContext,
    ) -> WorkflowStepResult:
        """Execute a single workflow step with retry support."""
        resolved_args = await self._resolve_step_arguments(registry, step.arguments, step_outputs)
        retries = 0
        max_attempts = step.max_retries if step.on_error == "retry" else 1

        for attempt in range(max_attempts):
            start = time.time()
            step_context = ToolExecutionContext(
                tool_context=parent_context.tool_context,
                call_id=str(uuid.uuid4()),
                heartbeat_id=parent_context.heartbeat_id,
                session_id=parent_context.session_id,
                energy_available=parent_context.energy_available,
                workspace_path=parent_context.workspace_path,
                allow_network=parent_context.allow_network,
                allow_shell=parent_context.allow_shell,
                allow_file_write=parent_context.allow_file_write,
                allow_file_read=parent_context.allow_file_read,
                registry=registry,
            )

            result = await registry.execute(step.tool, resolved_args, step_context)
            duration = time.time() - start

            if result.success:
                return WorkflowStepResult(
                    name=step.name,
                    tool=step.tool,
                    success=True,
                    output=result.output,
                    duration_seconds=round(duration, 3),
                    energy_spent=result.energy_spent,
                    retries=attempt,
                )

            retries = attempt + 1
            if attempt < max_attempts - 1:
                logger.info(
                    f"Workflow step '{step.name}' failed (attempt {attempt + 1}), retrying..."
                )

        # All attempts exhausted
        return WorkflowStepResult(
            name=step.name,
            tool=step.tool,
            success=False,
            error=result.error,
            duration_seconds=round(duration, 3),
            energy_spent=result.energy_spent,
            retries=retries,
        )

    async def _create_workflow_record(
        self,
        registry: "ToolRegistry",
        plan: WorkflowPlan,
        session_id: str | None,
    ) -> uuid.UUID | None:
        """Insert workflow_executions row, return its ID."""
        try:
            async with registry.pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT create_workflow_execution($1::jsonb, $2::jsonb)",
                    json.dumps(plan.to_dict()),
                    json.dumps({"session_id": session_id}),
                )
                payload = json.loads(raw) if isinstance(raw, str) else raw
                if isinstance(payload, dict) and payload.get("workflow_id"):
                    return uuid.UUID(str(payload["workflow_id"]))
        except Exception:
            logger.debug("workflow_executions table not available, skipping tracking")
            return None

    async def _update_workflow_record(
        self,
        registry: "ToolRegistry",
        workflow_id: uuid.UUID | None,
        status: str,
        step_results: list[WorkflowStepResult],
        total_energy: int,
    ) -> None:
        """Update workflow_executions row with final status."""
        if not workflow_id:
            return
        try:
            results_json = json.dumps(
                [
                    {
                        "name": r.name,
                        "tool": r.tool,
                        "success": r.success,
                        "skipped": r.skipped,
                        "error": r.error,
                        "duration_seconds": r.duration_seconds,
                        "energy_spent": r.energy_spent,
                    }
                    for r in step_results
                ]
            )
            error_msg = None
            if status == "failed":
                failed = [r for r in step_results if not r.success and not r.skipped]
                if failed:
                    error_msg = f"Step '{failed[0].name}' failed: {failed[0].error}"

            async with registry.pool.acquire() as conn:
                await conn.execute(
                    """
                    UPDATE workflow_executions
                    SET status = $1,
                        step_results = $2::jsonb,
                        total_energy_spent = $3,
                        error = $4,
                        completed_at = CURRENT_TIMESTAMP
                    WHERE id = $5
                    """,
                    status,
                    results_json,
                    total_energy,
                    error_msg,
                    workflow_id,
                )
        except Exception:
            logger.debug("Failed to update workflow record", exc_info=True)


def create_workflow_tools() -> list[ToolHandler]:
    """Create workflow orchestration tool handlers."""
    return [WorkflowHandler()]
