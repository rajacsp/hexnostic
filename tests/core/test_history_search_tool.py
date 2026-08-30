"""Typed API and agent-tool contracts for cross-session lexical search."""

from __future__ import annotations

from uuid import uuid4

import pytest

from core.tools import ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.memory import SearchHistoryHandler

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _context(registry, session_id=None):
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="history-search-test",
        session_id=str(session_id) if session_id else None,
        registry=registry,
    )


async def _seed_turn(conn, *, content, session_id, turn_at):
    return await conn.fetchval(
        """
        INSERT INTO subconscious_units (
            content, user_text, assistant_text, embedding, embedding_status,
            route_status, session_id, turn_at, idempotency_key
        )
        VALUES (
            $1, 'user half', 'assistant half',
            array_fill(0.1, ARRAY[embedding_dimension()])::vector, 'embedded',
            'raw_only', $2, ($3::text)::timestamptz, gen_random_uuid()::text
        )
        RETURNING id
        """,
        content,
        session_id,
        turn_at,
    )


async def test_search_history_dispatch_result_shape(db_pool):
    session_a, session_b = uuid4(), uuid4()
    import json

    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            await _seed_turn(
                conn,
                content="History dispatch parity: kept turn",
                session_id=session_b,
                turn_at="2026-07-10T12:00:00Z",
            )
            await _seed_turn(
                conn,
                content="History dispatch parity: excluded turn",
                session_id=session_a,
                turn_at="2026-07-10T13:00:00Z",
            )
            raw = await conn.fetchval(
                "SELECT execute_memory_tool('search_history', $1::jsonb)",
                json.dumps(
                    {
                        "query": '"History dispatch parity"',
                        "sources": ["turn"],
                        "created_after": "2026-07-09T00:00:00Z",
                        "exclude_session_id": str(session_a),
                    }
                ),
            )
        finally:
            await transaction.rollback()

    payload = json.loads(raw)
    assert payload["success"] is True
    output = payload["output"]
    assert output["count"] == 1
    assert output["excluded_session_id"] == str(session_a)
    row = output["results"][0]
    assert row["source_kind"] == "turn"
    assert row["session_id"] == str(session_b)
    assert row["content"] == "History dispatch parity: kept turn"
    assert row["user_text"] == "user half"
    assert "2026-07-10T12:00:00" in row["occurred_at"]
    assert row["rank"] > 0


async def test_search_history_handler_injects_current_session(db_pool):
    """The handler's only Python-side contribution: the current UUID session
    rides into the dispatch as exclude_session_id."""
    from core.tools import create_default_registry

    session_id = uuid4()
    registry = create_default_registry(db_pool)
    response = await SearchHistoryHandler().execute(
        {"query": "", "created_after": "2026-07-01T00:00:00Z", "limit": 5},
        _context(registry, session_id),
    )

    assert response.success is True
    assert response.output["excluded_session_id"] == str(session_id)
    assert response.output["limit"] == 5


@pytest.mark.parametrize(
    ("arguments", "message"),
    [
        ({"query": ""}, "query keywords, or a created_after"),
        (
            {
                "query": "detail",
                "created_after": "2026-08-01T00:00:00Z",
                "created_before": "2026-07-01T00:00:00Z",
            },
            "must be earlier",
        ),
        ({"query": "detail", "created_after": "not-a-date"}, "must be ISO-8601"),
        ({"query": "detail", "sources": ["bogus"]}, "invalid: bogus"),
    ],
)
async def test_search_history_tool_rejects_invalid_requests(db_pool, arguments, message):
    from core.tools import create_default_registry

    registry = create_default_registry(db_pool)
    response = await SearchHistoryHandler().execute(arguments, _context(registry))

    assert response.success is False
    assert response.error_type is ToolErrorType.INVALID_PARAMS
    assert message in (response.error or "")


async def test_core_memory_skill_exposes_history_search(db_pool):
    from core.tools import create_default_registry
    from services.skill_runtime import select_skills

    registry = create_default_registry(db_pool)
    selection = await select_skills(
        registry,
        ToolContext.CHAT,
        query="What did we decide in an earlier conversation?",
    )

    assert "search_history" in registry.list_names()
    assert "search_history" in selection.allowed_tool_names
    core_memory = next(
        skill for skill in selection.skills if skill.name == "core-memory"
    )
    assert "search_history" in core_memory.bound_tools
