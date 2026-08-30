"""Conscious-episode memory formation (#37): units claim selectively (floor-
gated), heartbeat turns join the substrate, extracted facts carry testimony
provenance with capped confidence, duplicates corroborate instead of
re-storing, and failures retry then park.
"""
from __future__ import annotations

import json
import uuid

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _coerce_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def _stub_get_embedding(conn):
    """Text-hash-bucketed unit vectors: identical text embeds identically,
    different text is (almost surely) orthogonal — so the ingest router sees
    duplicates only for genuine repeats."""
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                array_fill(0.0::float, ARRAY[(abs(hashtext(t)) % 256)]) ||
                ARRAY[1.0::float] ||
                array_fill(0.0::float, ARRAY[embedding_dimension() - 1 - (abs(hashtext(t)) % 256)])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents) t
        $$ LANGUAGE sql;
        """
    )


async def _enable(conn):
    await conn.execute(
        "UPDATE config SET value = 'true'::jsonb WHERE key = 'extraction.enabled'"
    )


_TURN_SEQ = iter(range(1, 10_000))


async def _seed_turn(conn, user_text: str, importance: float) -> str:
    # Mimic services/chat.py: source_identity is unique per turn (it doubles
    # as the recmem idempotency key).
    identity = f"chat:test-session:{next(_TURN_SEQ)}"
    result = _coerce_json(
        await conn.fetchval(
            "SELECT record_chat_turn_memory($1, $2, NULL, $3, $4::jsonb)",
            user_text,
            "Understood.",
            identity,
            json.dumps({"importance": importance}),
        )
    )
    return result["raw_unit_id"]


async def test_new_units_are_pending_and_claim_gates_on_importance(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            high = await _seed_turn(conn, "I am the inventor of Hexis.", 0.85)
            low = await _seed_turn(conn, "thanks, looks good", 0.3)
            statuses = {
                str(r["id"]): r["extraction_status"]
                for r in await conn.fetch(
                    "SELECT id, extraction_status FROM subconscious_units WHERE id = ANY($1::uuid[])",
                    [high, low],
                )
            }
            assert statuses[high] == "pending"
            assert statuses[low] == "pending"

            claimed = await conn.fetch("SELECT * FROM claim_conscious_extraction_batch()")
            claimed_ids = {str(r["id"]) for r in claimed}
            assert high in claimed_ids
            assert low not in claimed_ids
            low_status = await conn.fetchval(
                "SELECT extraction_status FROM subconscious_units WHERE id = $1::uuid", low
            )
            assert low_status == "skipped"
        finally:
            await tr.rollback()


async def test_heartbeat_turn_mirrors_into_substrate_when_enabled(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)

            async def _finish_heartbeat() -> None:
                started = _coerce_json(
                    await conn.fetchval("SELECT start_agent_turn('heartbeat', 'hb')")
                )
                for i in range(3):
                    await conn.fetchval(
                        "SELECT apply_agent_tool_result($1::uuid, $2, $3::jsonb)",
                        started["turn_id"],
                        f"c{i}",
                        json.dumps({"tool_name": "manage_backlog", "arguments": {},
                                    "success": True, "energy_spent": 1}),
                    )
                await conn.fetchval(
                    "SELECT finish_agent_turn($1::uuid, $2::jsonb)",
                    started["turn_id"],
                    json.dumps({"status": "completed",
                                "text": f"Completed backlog work, round {i}."}),
                )

            # Kill switch off: no mirroring.
            await conn.execute(
                "UPDATE config SET value = 'false'::jsonb WHERE key = 'extraction.enabled'"
            )
            i = 0
            await _finish_heartbeat()
            count = await conn.fetchval(
                "SELECT count(*) FROM subconscious_units WHERE metadata->>'kind' = 'heartbeat_episode'"
            )
            assert count == 0

            # Enabled (the default): the episode lands with action-derived importance.
            await _enable(conn)
            i = 1
            await _finish_heartbeat()
            row = await conn.fetchrow(
                "SELECT importance, source_identity, extraction_status FROM subconscious_units "
                "WHERE metadata->>'kind' = 'heartbeat_episode'"
            )
            assert row is not None
            assert row["source_identity"].startswith("heartbeat:")
            assert row["importance"] == pytest.approx(0.6)  # 0.3 + 3 * 0.1
            assert row["extraction_status"] == "pending"
        finally:
            await tr.rollback()


async def test_apply_creates_testimony_memory_with_capped_confidence(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _enable(conn)
            unit_id = await _seed_turn(conn, "I am the inventor of Hexis.", 0.85)
            await conn.fetch("SELECT * FROM claim_conscious_extraction_batch()")
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT apply_conscious_extraction($1::uuid[], $2::jsonb)",
                    [unit_id],
                    json.dumps([{
                        "unit_id": unit_id,
                        "content": "Eric is the inventor of Hexis.",
                        "kind": "user_testimony",
                        "category": "identity",
                        "confidence": 0.95,
                    }]),
                )
            )
            assert result["created"] == 1
            row = await conn.fetchrow(
                "SELECT metadata, source_attribution FROM memories "
                "WHERE type = 'semantic' AND content = 'Eric is the inventor of Hexis.'"
            )
            meta = _coerce_json(row["metadata"])
            attribution = _coerce_json(row["source_attribution"])
            assert float(meta["confidence"]) == 0.75  # testimony cap
            assert attribution["kind"] == "user_testimony"
            assert attribution["author"].startswith("chat:test-session:")
            assert attribution["ref"] == f"subconscious_unit:{unit_id}"
            linked = await conn.fetchval(
                "SELECT count(*) FROM memory_source_units WHERE subconscious_unit_id = $1::uuid "
                "AND role = 'extraction'",
                unit_id,
            )
            assert linked == 1
            unit_status = await conn.fetchval(
                "SELECT extraction_status FROM subconscious_units WHERE id = $1::uuid", unit_id
            )
            assert unit_status == "extracted"
        finally:
            await tr.rollback()


async def test_apply_corroborates_duplicates_instead_of_restoring(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _enable(conn)
            claim = "Eric is the inventor of Hexis."
            mid = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, metadata)
                VALUES ('semantic', $1, (get_embedding(ARRAY[$1]))[1], 0.8, 0.3, 'active',
                        '{"confidence": 0.5}'::jsonb)
                RETURNING id
                """,
                claim,
            )
            unit_id = await _seed_turn(conn, "I am the inventor of Hexis.", 0.85)
            await conn.fetch("SELECT * FROM claim_conscious_extraction_batch()")
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT apply_conscious_extraction($1::uuid[], $2::jsonb)",
                    [unit_id],
                    json.dumps([{
                        "unit_id": unit_id,
                        "content": claim,
                        "kind": "user_testimony",
                        "category": "identity",
                        "confidence": 0.7,
                    }]),
                )
            )
            assert result["corroborated"] == 1
            assert result["created"] == 0
            conf = await conn.fetchval(
                "SELECT (metadata->>'confidence')::float FROM memories WHERE id = $1::uuid", mid
            )
            # 0.5 + 0.5 * 0.35 * 0.75 (source trust) = 0.63125
            assert conf == pytest.approx(0.63125)
            audit = await conn.fetchval(
                "SELECT count(*) FROM belief_revision_audit WHERE memory_id = $1::uuid "
                "AND policy_context = 'conscious_extraction'",
                mid,
            )
            assert audit == 1
        finally:
            await tr.rollback()


async def test_empty_extraction_is_success_and_failures_retry_then_park(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _enable(conn)
            unit_id = await _seed_turn(conn, "Please remember I said something important.", 0.85)
            await conn.fetch("SELECT * FROM claim_conscious_extraction_batch()")
            result = _coerce_json(
                await conn.fetchval(
                    "SELECT apply_conscious_extraction($1::uuid[], '[]'::jsonb)",
                    [unit_id],
                )
            )
            assert result["created"] == 0
            status = await conn.fetchval(
                "SELECT extraction_status FROM subconscious_units WHERE id = $1::uuid", unit_id
            )
            assert status == "extracted"

            other = await _seed_turn(conn, "Another important identity statement here.", 0.85)
            for attempt in range(1, 4):
                await conn.fetchval(
                    "SELECT fail_conscious_extraction($1::uuid[], 'llm timeout')", [other]
                )
                status = await conn.fetchval(
                    "SELECT extraction_status FROM subconscious_units WHERE id = $1::uuid", other
                )
                assert status == ("failed" if attempt >= 3 else "pending")
            attempts = await conn.fetchval(
                "SELECT extraction_attempts FROM subconscious_units WHERE id = $1::uuid", other
            )
            assert attempts == 3
        finally:
            await tr.rollback()


async def test_get_turn_labels_resolves_configured_names(db_pool):
    """#56/#82: one label authority for turn rendering, extraction context,
    and source labels — config first, init-profile fallback, generic last."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT set_config('agent.name', '\"Nova\"'::jsonb)")
            await conn.execute("SELECT set_config('agent.user_name', '\"Ada\"'::jsonb)")
            labels = json.loads(await conn.fetchval("SELECT get_turn_labels()"))
            rendered = await conn.fetchval(
                "SELECT format_recmem_turn('hi there', 'hello', NULL)"
            )
        finally:
            await tr.rollback()

    assert labels == {"user_label": "Ada", "agent_label": "Nova"}
    assert rendered.startswith("Ada: hi there")
    assert "Nova: hello" in rendered


async def test_extraction_prompt_speaks_first_person(db_pool):
    """#82: the seeded extraction prompt instructs first-person self-memories."""
    async with db_pool.acquire() as conn:
        content = await conn.fetchval(
            "SELECT content FROM prompt_modules WHERE key = 'conscious_extraction'"
        )
    assert "Facts about **myself** are first person" in content
    assert "One self, one voice" in content


async def test_promise_turn_clears_extraction_floor(db_pool):
    """#58: a promise scores importance 0.8, above the 0.6 extraction floor —
    the unit is claimed for extraction, never skipped."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
                RETURNS vector[] AS $$
                    SELECT COALESCE(array_agg(array_fill(0.1, ARRAY[embedding_dimension()])::vector), ARRAY[]::vector[])
                    FROM unnest(text_contents)
                $$ LANGUAGE sql;
                """
            )
            result = json.loads(await conn.fetchval(
                """SELECT record_chat_turn_memory(
                    'Will you keep this between us?',
                    'I promise I''ll tell you mine too.',
                    $1, NULL, '{}'::jsonb)""",
                str(uuid.uuid4()),
            ))
            importance = await conn.fetchval(
                "SELECT importance FROM subconscious_units WHERE id = $1::uuid",
                result["raw_unit_id"],
            )
            floor = await conn.fetchval(
                "SELECT COALESCE(get_config_float('extraction.min_importance'), 0.6)"
            )
            claimed = await conn.fetch("SELECT id FROM claim_conscious_extraction_batch()")
            claimed_ids = {str(row["id"]) for row in claimed}
            status = await conn.fetchval(
                "SELECT extraction_status FROM subconscious_units WHERE id = $1::uuid",
                result["raw_unit_id"],
            )
        finally:
            await tr.rollback()

    assert importance >= floor, f"promise turn importance {importance} fell below floor {floor}"
    assert result["raw_unit_id"] in claimed_ids or status != "skipped"


async def test_conscious_extraction_is_the_sole_semantic_minter(db_pool):
    """#57: conversation-sourced semantic facts have exactly one minter.
    RecMem consolidation is scoped to episodic (semantic_refine retired in
    0ca04bc); no recmem-named function references create_semantic_memory."""
    async with db_pool.acquire() as conn:
        offenders = await conn.fetch(
            """
            SELECT p.proname FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname LIKE '%recmem%'
              AND p.prosrc LIKE '%create_semantic_memory%'
            """
        )
    assert offenders == [], f"recmem functions minting semantic rows: {[r['proname'] for r in offenders]}"
