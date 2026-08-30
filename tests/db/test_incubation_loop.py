"""The incubation loop (#98 Batch 2a): resolutions boost found memories over
the spontaneous floor, tell the user via an explicitly-routed web-inbox
message (capped, fire-once, sensitivity-honoring), and surface as
spontaneous recall in the unified ranker and the heartbeat context.
"""
from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _stub(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                array_fill(0.01::float, ARRAY[2 + abs(hashtext(t)) % (embedding_dimension() - 2)]) ||
                ARRAY[1.0::float] ||
                array_fill(0.01::float, ARRAY[embedding_dimension() - 3 - abs(hashtext(t)) % (embedding_dimension() - 2)])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents) t
        $$ LANGUAGE sql;
        """
    )


async def test_resolution_boosts_tells_and_surfaces(db_pool):
    m = get_test_identifier("incub")
    q = f"the forgotten fact {m}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub(conn)
            target = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('semantic', $1,
                        (get_embedding(ARRAY[ensure_embedding_prefix($2, 'search_query')]))[1],
                        0.5, 0.8, 'active')
                RETURNING id
                """,
                f"the answer to the forgotten fact {m}", q,
            )
            await conn.fetchval("SELECT request_background_search($1)", q)
            processed = await conn.fetchval(
                "SELECT process_background_searches(10, INTERVAL '0 seconds')"
            )
            assert processed == 1

            boost = await conn.fetchval(
                "SELECT (metadata->>'activation_boost')::float FROM memories WHERE id = $1",
                target,
            )
            assert boost is not None and boost >= 0.45  # clears the 0.3 floor

            note = await conn.fetchrow(
                "SELECT envelope#>>'{payload,message}' AS msg, "
                "envelope#>'{payload,delivery}' AS delivery FROM outbox_messages "
                "WHERE envelope#>>'{payload,intent}' = 'incubation' "
                "ORDER BY created_at DESC LIMIT 1"
            )
            assert note is not None
            assert q in note["msg"] and "came back to me" in note["msg"]
            assert json.loads(note["delivery"])["mode"] == "web_inbox"

            spont = await conn.fetch("SELECT id FROM get_spontaneous_memories(3)")
            assert target in [r["id"] for r in spont]

            # Crowd the semantic tier with on-axis distractors so the target
            # cannot surface there — spontaneous is for what recall would NOT
            # have found, which the dedupe enforces.
            unrelated = f"a wholly unrelated question {m}"
            for i in range(4):
                await conn.execute(
                    """
                    INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                    VALUES ('semantic', $1,
                            (get_embedding(ARRAY[ensure_embedding_prefix($2, 'search_query')]))[1],
                            0.5, 0.8, 'active')
                    """,
                    f"unrelated distractor {i} {m}", unrelated,
                )
            rows = await conn.fetch(
                "SELECT item_id FROM recmem_recall_context($1, 2, 2, 2, NULL, FALSE, 2) "
                "WHERE tier = 'spontaneous'", unrelated,
            )
            assert target in [r["item_id"] for r in rows]

            env = json.loads(await conn.fetchval("SELECT get_environment_snapshot()"))
            assert any(m in s for s in env["on_my_mind"])
        finally:
            await tr.rollback()


async def test_private_resolutions_stay_quiet_and_cap_holds(db_pool):
    m = get_test_identifier("incub")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub(conn)
            # Private memory resolving: no user note carries its content.
            q1 = f"private forgotten thing {m}"
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution)
                VALUES ('semantic', $1,
                        (get_embedding(ARRAY[ensure_embedding_prefix($2, 'search_query')]))[1],
                        0.5, 0.8, 'active', '{"sensitivity": "private"}'::jsonb)
                """,
                f"the private answer {m}", q1,
            )
            await conn.fetchval("SELECT request_background_search($1)", q1)
            await conn.fetchval("SELECT process_background_searches(10, INTERVAL '0 seconds')")
            leaked = await conn.fetchval(
                "SELECT COUNT(*) FROM outbox_messages "
                "WHERE envelope#>>'{payload,intent}' = 'incubation' "
                "AND envelope#>>'{payload,message}' LIKE '%' || $1 || '%'",
                f"the private answer {m}",
            )
            assert leaked == 0

            # Cap: with the per-day counter saturated, resolutions stay silent.
            await conn.execute(
                "SELECT set_config('incubation.tell_user_max_per_day', '0'::jsonb)"
            )
            q2 = f"capped forgotten thing {m}"
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('semantic', $1,
                        (get_embedding(ARRAY[ensure_embedding_prefix($2, 'search_query')]))[1],
                        0.5, 0.8, 'active')
                """,
                f"the capped answer {m}", q2,
            )
            await conn.fetchval("SELECT request_background_search($1)", q2)
            await conn.fetchval("SELECT process_background_searches(10, INTERVAL '0 seconds')")
            capped = await conn.fetchval(
                "SELECT COUNT(*) FROM outbox_messages "
                "WHERE envelope#>>'{payload,message}' LIKE '%' || $1 || '%'",
                f"the capped answer {m}",
            )
            assert capped == 0
        finally:
            await tr.rollback()
