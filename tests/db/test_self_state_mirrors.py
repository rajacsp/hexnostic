"""Self-state mirrors (#43/#44/#45/#46): the agent can read its own
belief-revision history, configuration (allowlisted + redacted), and verbatim
action log; budgeted turns surface energy on every tool result.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _coerce_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def _seed_belief(conn, content: str, confidence: float = 0.5) -> str:
    return str(
        await conn.fetchval(
            """
            INSERT INTO memories (type, content, embedding, importance, trust_level, status, metadata)
            VALUES ('semantic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                    0.8, 0.3, 'active', $2::jsonb)
            RETURNING id
            """,
            content,
            json.dumps({"confidence": confidence}),
        )
    )


async def _stub_get_embedding(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                ARRAY[1.0::float] ||
                array_fill(0.0::float, ARRAY[embedding_dimension() - 1])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """
    )


# ---------------------------------------------------------------------------
# belief_history (#43)
# ---------------------------------------------------------------------------


async def test_belief_history_tells_the_whole_story(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mid = await _seed_belief(conn, "belief: full story", confidence=0.5)
            await conn.fetchval(
                "SELECT add_memory_evidence($1::uuid, 'supports', $2::jsonb, $3::text)",
                mid,
                json.dumps({"kind": "origin_document", "ref": "docs/a.md", "trust": 0.9}),
                "Document A states this.",
            )
            await conn.fetchval(
                "SELECT revise_memory_confidence($1::uuid, $2::jsonb, 'contradicts', 'test')",
                mid,
                json.dumps({"kind": "web_page", "ref": "https://b.example", "trust": 0.6}),
            )
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT execute_memory_tool('belief_history', $1::jsonb)",
                    json.dumps({"memory_id": mid}),
                )
            )
            assert result["success"] is True
            out = result["output"]
            # Current state + profile
            assert out["memory"]["protected"] is False
            assert out["memory"]["confidence"] is not None
            assert out["profile"]["source_count"] >= 1
            # Revisions newest-first: contradiction after support
            revisions = out["revisions"]
            assert len(revisions) == 2
            assert revisions[0]["stance"] == "contradicts"
            assert revisions[1]["stance"] == "supports"
            assert revisions[1]["prior"] == 0.5
            assert revisions[0]["prior"] == revisions[1]["posterior"]
            # Evidence edge with excerpt (from the note-created evidence memory)
            assert len(out["evidence"]) == 1
            assert out["evidence"][0]["relation"] == "SUPPORTS"
            assert "Document A" in out["evidence"][0]["excerpt"]
            assert len(out["contradicting_sources"]) == 1
            assert "revision" in result["display_output"]
        finally:
            await tr.rollback()


async def test_belief_history_validation_and_non_semantic(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            bad = _coerce_json(
                await conn.fetchval(
                    "SELECT execute_memory_tool('belief_history', '{\"memory_id\": \"nope\"}'::jsonb)"
                )
            )
            assert bad["success"] is False
            assert bad["error_type"] == "invalid_params"

            missing = _coerce_json(
                await conn.fetchval(
                    "SELECT execute_memory_tool('belief_history', $1::jsonb)",
                    json.dumps({"memory_id": "00000000-0000-0000-0000-000000000000"}),
                )
            )
            assert missing["success"] is False

            eid = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', 'an event', array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.5, 0.9, 'active')
                RETURNING id
                """
            )
            episodic = _coerce_json(
                await conn.fetchval(
                    "SELECT execute_memory_tool('belief_history', $1::jsonb)",
                    json.dumps({"memory_id": str(eid)}),
                )
            )
            # Non-semantic memories explain themselves rather than erroring.
            assert episodic["success"] is True
            assert "Not a semantic belief" in episodic["output"]["note"]
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# inspect_agent_config (#45)
# ---------------------------------------------------------------------------


async def test_inspect_config_allowlist_and_hard_exclusions(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            visible = _coerce_json(
                await conn.fetchval("SELECT inspect_agent_config('extraction.')")
            )
            assert visible["extraction.enabled"] is True

            # Secrets never surface, even if their prefixes reach the allowlist.
            await conn.execute(
                """
                UPDATE config SET value = value || '["oauth.", "token.", "tools"]'::jsonb
                WHERE key = 'inspection.config_prefixes'
                """
            )
            await conn.execute(
                """
                INSERT INTO config (key, value, description)
                VALUES ('oauth.test_provider', '{"access": "SECRET"}'::jsonb, 'test'),
                       ('token.test', '{"token": "SECRET"}'::jsonb, 'test')
                ON CONFLICT (key) DO NOTHING
                """
            )
            everything = _coerce_json(await conn.fetchval("SELECT inspect_agent_config(NULL)"))
            assert not any(k.startswith("oauth.") for k in everything)
            assert not any(k.startswith("token.") for k in everything)
            assert "tools" not in everything
            assert "SECRET" not in json.dumps(everything)
        finally:
            await tr.rollback()


async def test_inspect_config_redacts_secret_named_keys(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO config (key, value, description)
                VALUES ('inspection.test_api_key', '"sk-live-secret"'::jsonb, 'test')
                ON CONFLICT (key) DO NOTHING
                """
            )
            result = _coerce_json(
                await conn.fetchval("SELECT inspect_agent_config('inspection.test')")
            )
            assert result["inspection.test_api_key"] == "[redacted]"

            # Non-allowlisted prefixes yield nothing.
            outside = _coerce_json(
                await conn.fetchval("SELECT inspect_agent_config('channel.')")
            )
            assert outside == {}
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# get_recent_actions (#46)
# ---------------------------------------------------------------------------


async def test_recent_actions_window_failures_and_no_blobs(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO tool_executions
                    (tool_name, arguments, tool_context, call_id, success, error,
                     error_type, energy_spent, duration_seconds, output, created_at)
                VALUES
                    ('recall', '{}'::jsonb, 'chat', 'a', true, NULL, NULL, 1, 0.2,
                     '{"big": "blob"}'::jsonb, now()),
                    ('shell', '{}'::jsonb, 'heartbeat', 'b', false, 'boom', 'execution_failed',
                     2, 1.5, NULL, now()),
                    ('recall', '{}'::jsonb, 'chat', 'c', true, NULL, NULL, 1, 0.1,
                     NULL, now() - interval '3 days')
                """
            )
            report = _coerce_json(await conn.fetchval("SELECT get_recent_actions(24, 10)"))
            summary = report["summary"]
            assert summary["total"] == 2  # the 3-day-old row is outside the window
            assert summary["failures"] == 1
            assert summary["energy_total"] == 3
            tools = [a["tool"] for a in report["actions"]]
            assert set(tools) == {"recall", "shell"}
            assert all("output" not in a for a in report["actions"])

            # Context filter
            hb_only = _coerce_json(
                await conn.fetchval("SELECT get_recent_actions(24, 10, 'heartbeat')")
            )
            assert hb_only["summary"]["total"] == 1
            assert hb_only["actions"][0]["success"] is False

            # Clamps: absurd asks bounded
            clamped = _coerce_json(
                await conn.fetchval("SELECT get_recent_actions(99999, 99999)")
            )
            assert clamped["summary"]["window_hours"] == 168
            assert clamped["summary"]["truncated_to"] == 100
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Energy footer (#44) — negative case (positive lives in test_agent_runtime)
# ---------------------------------------------------------------------------


async def test_no_energy_footer_without_budget(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            started = _coerce_json(
                await conn.fetchval("SELECT start_agent_turn('chat', 'hi')")
            )
            await conn.fetchval(
                "SELECT apply_agent_tool_result($1::uuid, 'c1', $2::jsonb)",
                started["turn_id"],
                json.dumps({"tool_name": "recall", "success": True,
                            "energy_spent": 1, "model_output": "plain"}),
            )
            content = await conn.fetchval(
                "SELECT messages->-1->>'content' FROM agent_turns WHERE id = $1::uuid",
                started["turn_id"],
            )
            assert content == "plain"
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Recency in recall (#47)
# ---------------------------------------------------------------------------


async def test_fast_recall_prefers_newer_on_similarity_ties(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            old_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level,
                                      status, created_at)
                VALUES ('semantic', 'recency tie test fact',
                        (get_embedding(ARRAY['recency tie test fact']))[1],
                        0.5, 0.8, 'active', now() - interval '60 days')
                RETURNING id
                """
            )
            new_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level,
                                      status, created_at)
                VALUES ('semantic', 'recency tie test fact',
                        (get_embedding(ARRAY['recency tie test fact']))[1],
                        0.5, 0.8, 'active', now())
                RETURNING id
                """
            )
            rows = await conn.fetch(
                "SELECT memory_id, score FROM fast_recall('recency tie test fact', 10)"
            )
            ranked = [str(r["memory_id"]) for r in rows]
            weighted = {str(r["memory_id"]): r["score"] for r in rows}
            assert str(new_id) in ranked and str(old_id) in ranked
            assert ranked.index(str(new_id)) < ranked.index(str(old_id))

            # Weight 0 removes the recency term; the remaining age effect is
            # the (small) pre-existing strength decay, so the new/old score gap
            # must shrink.
            await conn.execute(
                "UPDATE config SET value = '0'::jsonb WHERE key = 'memory.recency_weight'"
            )
            rows = await conn.fetch(
                "SELECT memory_id, score FROM fast_recall('recency tie test fact', 10)"
            )
            unweighted = {str(r["memory_id"]): r["score"] for r in rows}
            gap_weighted = weighted[str(new_id)] - weighted[str(old_id)]
            gap_unweighted = unweighted[str(new_id)] - unweighted[str(old_id)]
            assert gap_unweighted < gap_weighted
        finally:
            await tr.rollback()


# ---------------------------------------------------------------------------
# Temporal grounding (#55) and speaker naming (#56)
# ---------------------------------------------------------------------------


async def test_temporal_context_reports_now_and_age(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level,
                                      status, metadata, created_at)
                VALUES ('episodic', 'I came online today.',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.9, 0.95, 'active', '{"type": "initialization"}'::jsonb,
                        now() - interval '5 days')
                """
            )
            ctx = _coerce_json(await conn.fetchval("SELECT get_temporal_context()"))
            assert ctx["now"]
            assert ctx["timezone"]
            assert ctx["age_days"] == 5
            assert ctx["born_on"]
        finally:
            await tr.rollback()


async def test_recmem_turns_use_configured_names(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO config (key, value, description)
                VALUES ('agent.user_name', '"Eric"'::jsonb, 'test')
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
                """
            )
            formatted = await conn.fetchval(
                "SELECT format_recmem_turn('hello', 'hi there')"
            )
            assert formatted.startswith("Eric: hello")
        finally:
            await tr.rollback()


async def test_promises_clear_the_importance_floor(db_pool):
    async with db_pool.acquire() as conn:
        importance = await conn.fetchval(
            "SELECT estimate_conversation_importance('do you promise?', 'I promise I will tell you mine too.')"
        )
        assert importance >= 0.8
