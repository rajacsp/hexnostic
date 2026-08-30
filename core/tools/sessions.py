"""
Hexis Tools System - Sub-Agent Session Management

Allows the agent to spawn background sub-agent sessions that run their own
AgentLoop with an isolated energy budget. Results are stored in the database
and optionally recorded as episodic memories.
"""

from __future__ import annotations

import asyncio
import json
import logging
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
    import asyncpg

logger = logging.getLogger(__name__)

_VALID_ACTIONS = {"spawn", "list", "get", "cancel"}

# Track running sub-agent tasks so they can be cancelled
_running_tasks: dict[str, asyncio.Task] = {}
_tasks_lock = asyncio.Lock()


async def _run_sub_agent(
    pool: "asyncpg.Pool",
    session_id: str,
    task: str,
    energy_budget: int,
) -> None:
    """Execute a sub-agent session in the background.

    This runs an AgentLoop with the given task and energy budget, then
    stores the results back to the sub_agent_sessions table and optionally
    creates an episodic memory.
    """
    from core.agent_loop import AgentLoop, AgentLoopConfig
    from core.llm_config import load_llm_config
    from core.tools.registry import create_default_registry
    from services.prompt_resources import compose_compact_personhood_prompt

    try:
        # Mark as running
        async with pool.acquire() as conn:
            await conn.fetchval(
                "SELECT update_sub_agent_session($1, 'running')",
                session_id,
            )

        # Load LLM config (use heartbeat model for sub-agents)
        async with pool.acquire() as conn:
            llm_config = await load_llm_config(conn, "llm.heartbeat")

        # Build a simple system prompt
        personhood = ""
        try:
            personhood = compose_compact_personhood_prompt("heartbeat")
        except Exception:
            pass

        system_prompt = (
            "You are a sub-agent running a focused background task. "
            "Complete the assigned task efficiently within your energy budget. "
            "Use your tools to gather information, store results, and accomplish the goal. "
            "When done, provide a clear summary of what you found or accomplished."
        )
        if personhood:
            system_prompt += (
                "\n\n----- PERSONHOOD GROUNDING -----\n\n"
                + personhood
            )

        # Create a tool registry for this sub-agent
        registry = create_default_registry(pool)

        loop_config = AgentLoopConfig(
            tool_context=ToolContext.HEARTBEAT,
            system_prompt=system_prompt,
            llm_config=llm_config,
            registry=registry,
            pool=pool,
            energy_budget=energy_budget,
            max_iterations=None,
            timeout_seconds=180.0,
            temperature=0.7,
            max_tokens=2048,
            session_id=f"sub_agent:{session_id}",
            enable_planning=False,
            continuation_prompt=(
                "Review your work — is there anything else to do "
                "before finishing this task?"
            ),
            max_continuations=1,
        )

        agent = AgentLoop(loop_config)
        result = await agent.run(task)

        # Store results
        transcript = json.dumps(result.messages[-10:]) if result.messages else "[]"
        summary = result.text or f"Task completed: {len(result.tool_calls_made)} tool calls."
        tool_names = [tc.get("name", "?") for tc in result.tool_calls_made]
        if tool_names:
            summary += f" Tools used: {', '.join(tool_names)}."

        async with pool.acquire() as conn:
            # Record as episodic memory
            memory_id = None
            try:
                memory_id = await conn.fetchval(
                    """
                    SELECT create_episodic_memory(
                        p_content := $1,
                        p_action := 'sub_agent_session',
                        p_context := $2::jsonb,
                        p_result := 'completed',
                        p_importance := 0.6,
                        p_trust_level := 1.0
                    )
                    """,
                    summary[:2000],
                    json.dumps({
                        "session_id": session_id,
                        "task": task[:500],
                        "energy_spent": result.energy_spent,
                        "tool_calls": len(result.tool_calls_made),
                        "stopped_reason": result.stopped_reason,
                        "source": "sub_agent",
                    }),
                )
            except Exception:
                logger.debug("Failed to create sub-agent episodic memory", exc_info=True)

            await conn.fetchval(
                """
                SELECT update_sub_agent_session(
                    $1, 'completed', $2, NULL,
                    $3, $4::jsonb, $5
                )
                """,
                session_id,
                summary[:4000],
                result.energy_spent,
                transcript,
                memory_id,
            )

        logger.info(
            "Sub-agent session %s completed: %d energy, %d tool calls",
            session_id, result.energy_spent, len(result.tool_calls_made),
        )

    except asyncio.CancelledError:
        async with pool.acquire() as conn:
            await conn.fetchval(
                "SELECT update_sub_agent_session($1, 'cancelled')",
                session_id,
            )
        logger.info("Sub-agent session %s cancelled", session_id)

    except Exception as exc:
        logger.error("Sub-agent session %s failed: %s", session_id, exc, exc_info=True)
        try:
            async with pool.acquire() as conn:
                await conn.fetchval(
                    "SELECT update_sub_agent_session($1, 'failed', NULL, $2)",
                    session_id,
                    str(exc)[:2000],
                )
        except Exception:
            logger.debug("Failed to update sub-agent session on error", exc_info=True)

    finally:
        async with _tasks_lock:
            _running_tasks.pop(session_id, None)


class ManageSessionsHandler(ToolHandler):
    """Manage background sub-agent sessions.

    Actions:
      spawn  - Start a new background task
      list   - List recent sessions
      get    - Get full details of a session
      cancel - Cancel a pending or running session
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="manage_sessions",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Spawn, list, inspect, or cancel background sub-agent sessions. "
                "Sub-agents run autonomously with their own energy budget to handle "
                "research, analysis, or other tasks in parallel."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": list(_VALID_ACTIONS),
                        "description": "The action to perform.",
                    },
                    "task": {
                        "type": "string",
                        "description": "(spawn) What the sub-agent should do.",
                    },
                    "energy_budget": {
                        "type": "integer",
                        "description": "(spawn) Energy budget for the sub-agent. Default 5.",
                    },
                    "session_id": {
                        "type": "string",
                        "description": "(get, cancel) UUID of the session.",
                    },
                    "status_filter": {
                        "type": "string",
                        "enum": ["pending", "running", "completed", "failed", "cancelled"],
                        "description": "(list) Filter by status.",
                    },
                },
                "required": ["action"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=False,
            requires_approval=False,
            allowed_contexts={ToolContext.HEARTBEAT, ToolContext.CHAT, ToolContext.MCP},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        action = arguments.get("action", "")
        if action not in _VALID_ACTIONS:
            return ToolResult.error_result(
                f"Invalid action '{action}'. Must be one of: {', '.join(sorted(_VALID_ACTIONS))}",
                ToolErrorType.INVALID_PARAMS,
            )

        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result(
                "Database pool not available",
                ToolErrorType.MISSING_CONFIG,
            )

        if action == "spawn":
            return await self._spawn(pool, arguments, context)
        if action == "list":
            return await self._list(pool, arguments)
        if action == "get":
            return await self._get(pool, arguments)
        if action == "cancel":
            return await self._cancel(pool, arguments)

        return ToolResult.error_result(f"Unhandled action: {action}")

    async def _spawn(
        self,
        pool: "asyncpg.Pool",
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        task_desc = arguments.get("task", "").strip()
        if not task_desc:
            return ToolResult.error_result(
                "Parameter 'task' is required for spawn.",
                ToolErrorType.INVALID_PARAMS,
            )

        energy_budget = arguments.get("energy_budget", 5)
        if energy_budget < 1:
            energy_budget = 1
        if energy_budget > 20:
            energy_budget = 20

        # Create DB record
        async with pool.acquire() as conn:
            session_id = await conn.fetchval(
                """
                SELECT create_sub_agent_session(
                    $1, $2, $3, $4, $5, true
                )
                """,
                task_desc,
                energy_budget,
                context.heartbeat_id,
                context.session_id,
                "heartbeat" if context.tool_context == ToolContext.HEARTBEAT else "chat",
            )

        session_id_str = str(session_id)

        # Spawn background task
        bg_task = asyncio.create_task(
            _run_sub_agent(pool, session_id_str, task_desc, energy_budget),
            name=f"sub_agent:{session_id_str[:8]}",
        )
        async with _tasks_lock:
            _running_tasks[session_id_str] = bg_task

        return ToolResult(
            output=json.dumps({
                "session_id": session_id_str,
                "task": task_desc,
                "energy_budget": energy_budget,
                "status": "pending",
                "message": "Sub-agent session spawned. It will run in the background.",
            }),
            energy_cost=1,
        )

    async def _list(
        self,
        pool: "asyncpg.Pool",
        arguments: dict[str, Any],
    ) -> ToolResult:
        status_filter = arguments.get("status_filter")

        async with pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT list_sub_agent_sessions($1, 20)",
                status_filter,
            )

        sessions = json.loads(result) if result else []
        return ToolResult(
            output=json.dumps({
                "count": len(sessions),
                "sessions": sessions,
            }),
            energy_cost=0,
        )

    async def _get(
        self,
        pool: "asyncpg.Pool",
        arguments: dict[str, Any],
    ) -> ToolResult:
        session_id = arguments.get("session_id", "").strip()
        if not session_id:
            return ToolResult.error_result(
                "Parameter 'session_id' is required for get.",
                ToolErrorType.INVALID_PARAMS,
            )

        async with pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT get_sub_agent_session($1::uuid)",
                session_id,
            )

        session = json.loads(result) if result else {}
        if not session:
            return ToolResult.error_result(
                f"Session {session_id} not found.",
                ToolErrorType.NOT_FOUND,
            )

        return ToolResult(
            output=json.dumps(session),
            energy_cost=0,
        )

    async def _cancel(
        self,
        pool: "asyncpg.Pool",
        arguments: dict[str, Any],
    ) -> ToolResult:
        session_id = arguments.get("session_id", "").strip()
        if not session_id:
            return ToolResult.error_result(
                "Parameter 'session_id' is required for cancel.",
                ToolErrorType.INVALID_PARAMS,
            )

        # Cancel the asyncio task if still running
        async with _tasks_lock:
            bg_task = _running_tasks.get(session_id)
            if bg_task and not bg_task.done():
                bg_task.cancel()

        async with pool.acquire() as conn:
            cancelled = await conn.fetchval(
                "SELECT cancel_sub_agent_session($1::uuid)",
                session_id,
            )

        if cancelled:
            return ToolResult(
                output=json.dumps({
                    "session_id": session_id,
                    "status": "cancelled",
                    "message": "Session cancelled.",
                }),
                energy_cost=0,
            )

        return ToolResult.error_result(
            f"Session {session_id} not found or already completed.",
            ToolErrorType.NOT_FOUND,
        )


def create_session_tools() -> list[ToolHandler]:
    """Create the sub-agent session management tools."""
    return [ManageSessionsHandler()]
