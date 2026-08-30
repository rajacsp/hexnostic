"""Database contracts for free cross-session full-text history search."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


async def _raw_turn(
    conn, token: str, session_id, *, turn_at: datetime, status="active"
):
    result = _json(
        await conn.fetchval(
            """
            SELECT recmem_ingest_turn(
                $1::text, $2::text, $3::uuid, $4::text, $5::timestamptz
            )
            """,
            f"Discuss {token} in this conversation",
            f"Recorded {token} for later continuity",
            session_id,
            f"fts-test:{uuid4()}",
            turn_at,
        )
    )
    unit_id = UUID(str(result["unit_id"]))
    if status != "active":
        await conn.execute(
            "UPDATE subconscious_units SET status=$2 WHERE id=$1::uuid",
            unit_id,
            status,
        )
    return unit_id


async def _memory(conn, token: str, *, status="active", created_at=None):
    return await conn.fetchval(
        """
        INSERT INTO memories (type, content, embedding, status, created_at)
        VALUES (
            'semantic',
            $1,
            array_fill(0.0, ARRAY[embedding_dimension()])::vector,
            $2::memory_status,
            COALESCE($3::timestamptz, CURRENT_TIMESTAMP)
        )
        RETURNING id
        """,
        f"Consolidated knowledge about {token}",
        status,
        created_at,
    )


async def test_search_history_unifies_active_turns_and_memories_with_session_exclusion(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            token = f"crosssessionneedle{uuid4().hex}"
            prior_session = uuid4()
            current_session = uuid4()
            now = datetime.now(timezone.utc)
            prior_turn = await _raw_turn(
                conn, token, prior_session, turn_at=now - timedelta(days=2)
            )
            current_turn = await _raw_turn(
                conn, token, current_session, turn_at=now - timedelta(minutes=2)
            )
            redacted_turn = await _raw_turn(
                conn,
                token,
                uuid4(),
                turn_at=now - timedelta(days=1),
                status="redacted",
            )
            active_memory = await _memory(conn, token)
            invalid_memory = await _memory(conn, token, status="invalidated")
            await conn.execute(
                """
                INSERT INTO memory_source_units (memory_id, subconscious_unit_id)
                VALUES ($1::uuid, $2::uuid)
                """,
                active_memory,
                prior_turn,
            )

            all_rows = await conn.fetch(
                "SELECT * FROM search_cross_session_history($1, 20)", token
            )
            excluded_rows = await conn.fetch(
                """
                SELECT * FROM search_cross_session_history(
                    $1, 20, ARRAY['turn','memory']::text[], NULL, NULL, $2::uuid
                )
                """,
                token,
                current_session,
            )

            all_ids = {row["item_id"] for row in all_rows}
            excluded_ids = {row["item_id"] for row in excluded_rows}
            assert {prior_turn, current_turn, active_memory} <= all_ids
            assert redacted_turn not in all_ids
            assert invalid_memory not in all_ids
            assert current_turn not in excluded_ids
            assert {prior_turn, active_memory} <= excluded_ids
            memory_row = next(
                row for row in excluded_rows if row["item_id"] == active_memory
            )
            assert memory_row["source_kind"] == "memory"
            assert memory_row["session_id"] == prior_session
            assert memory_row["source_unit_ids"] == [prior_turn]
            assert all(row["rank"] > 0 for row in excluded_rows)
        finally:
            await transaction.rollback()


async def test_search_history_honors_source_and_time_filters_without_embeddings(
    db_pool,
):
    async with db_pool.acquire() as conn:
        transaction = conn.transaction()
        await transaction.start()
        try:
            token = f"lexicalcontinuity{uuid4().hex}"
            now = datetime.now(timezone.utc)
            old_turn = await _raw_turn(
                conn, token, uuid4(), turn_at=now - timedelta(days=30)
            )
            recent_turn = await _raw_turn(
                conn, token, uuid4(), turn_at=now - timedelta(hours=1)
            )
            memory_id = await _memory(conn, token)

            recent_turns = await conn.fetch(
                """
                SELECT * FROM search_cross_session_history(
                    $1, 20, ARRAY['turn']::text[], $2::timestamptz, NULL, NULL
                )
                """,
                token,
                now - timedelta(days=1),
            )
            memories = await conn.fetch(
                """
                SELECT * FROM search_cross_session_history(
                    $1, 20, ARRAY['memory']::text[], NULL, NULL, NULL
                )
                """,
                token,
            )

            assert [row["item_id"] for row in recent_turns] == [recent_turn]
            assert old_turn not in {row["item_id"] for row in recent_turns}
            assert [row["item_id"] for row in memories] == [memory_id]
            assert await conn.fetchval(
                "SELECT to_regclass('public.idx_subconscious_units_content_fts') IS NOT NULL"
            )
        finally:
            await transaction.rollback()
