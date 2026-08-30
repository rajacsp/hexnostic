"""Tranche 2 of the stress-test fixes (#68/#69/#70/#71/#72): temporal browse,
sentence-boundary gut reactions, card macro resolution, session threading,
and day-of-life grounding.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def test_search_history_time_window_browse(db_pool):
    """#68: a time window with no keywords returns the window newest-first —
    a day with records must never read as blank."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            for idx in range(3):
                await conn.fetchval(
                    "SELECT recmem_ingest_turn($1, 'ok', NULL, $2)",
                    f"browse probe number {idx}",
                    f"browse-probe-{idx}",
                )
            await conn.execute(
                """
                UPDATE subconscious_units
                SET turn_at = CURRENT_TIMESTAMP - INTERVAL '1 day' - (INTERVAL '1 minute' * (
                    CASE WHEN source_identity = 'browse-probe-2' THEN 0 ELSE 30 END))
                WHERE source_identity LIKE 'browse-probe-%'
                """
            )
            rows = await conn.fetch(
                """
                SELECT * FROM search_cross_session_history(
                    '', 20, ARRAY['turn','memory'],
                    CURRENT_TIMESTAMP - INTERVAL '2 days',
                    CURRENT_TIMESTAMP)
                """
            )
            contents = [r["content"] for r in rows if "browse probe" in (r["content"] or "")]
            assert len(contents) == 3
            assert "browse probe number 2" in contents[0]

            wildcard = await conn.fetch(
                """
                SELECT * FROM search_cross_session_history(
                    '*', 20, ARRAY['turn','memory'],
                    CURRENT_TIMESTAMP - INTERVAL '2 days',
                    CURRENT_TIMESTAMP)
                """
            )
            assert len([r for r in wildcard if "browse probe" in (r["content"] or "")]) == 3

            no_window = await conn.fetch("SELECT * FROM search_cross_session_history('', 20)")
            assert no_window == []
        finally:
            await tr.rollback()


async def test_gut_reaction_truncates_at_sentence_boundary(db_pool):
    """#69: long gut reactions end at a sentence, never mid-word."""
    async with db_pool.acquire() as conn:
        long_reaction = (
            "A cold, immediate jolt runs through the appraisal of this moment. "
        ) * 12  # ~792 chars, sentence-terminated segments
        rendered = await conn.fetchval(
            "SELECT render_subconscious_signals(jsonb_build_object('subconscious_response', $1::text, 'instincts', '[{\"impulse\": \"x\", \"intensity\": 0.5, \"reason\": \"y\"}]'::jsonb))",
            long_reaction,
        )
        gut_line = next(line for line in rendered.split("\n") if line.startswith("- Gut reaction:"))
        assert gut_line.rstrip().endswith(".")
        assert len(gut_line) < 700


async def test_card_macros_resolve_in_profile_context(db_pool):
    """#70: {{user}}/{{char}} resolve at render time from the init profile."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                SELECT set_config('agent.init_profile', $1::jsonb)
                """,
                json.dumps({
                    "agent": {"name": "Vera"},
                    "relationship": {"name": "Sam"},
                    "character_card": {"data": {
                        "scenario": "{{char}} has just met {{user}}.",
                        "system_prompt": "Speak to {{user}} warmly.",
                        "mes_example": "{{user}}: hi\n{{char}}: hello",
                    }},
                }),
            )
            profile = _json(await conn.fetchval("SELECT get_agent_profile_context()"))
            persona = profile["persona"]
            assert persona["scenario"] == "Vera has just met Sam."
            assert persona["character_instructions"] == "Speak to Sam warmly."
            assert "{{" not in persona["example_dialogue"]
        finally:
            await tr.rollback()


async def test_chat_turn_memory_keeps_session_uuid(db_pool):
    """#71: a UUID session id survives into the ingested unit."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            session = "11111111-2222-4333-8444-555555555555"
            result = _json(await conn.fetchval(
                "SELECT record_chat_turn_memory('session probe', 'ok', $1, 'session-probe-1', '{}'::jsonb)",
                session,
            ))
            stored = await conn.fetchval(
                "SELECT session_id::text FROM subconscious_units WHERE id = $1::uuid",
                result["raw_unit_id"],
            )
            assert stored == session
        finally:
            await tr.rollback()


async def test_temporal_context_day_of_life(db_pool):
    """#72: the agent's age reads as a calendar day-of-life, not floored days."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, metadata, created_at)
                VALUES ('episodic', 'I came online.',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        1.0, 0.95, 'active', '{"type": "initialization"}'::jsonb,
                        CURRENT_TIMESTAMP - INTERVAL '6 days')
                """
            )
            ctx = _json(await conn.fetchval("SELECT get_temporal_context()"))
            assert ctx["day_of_life"] == 7
            assert ctx["age_days"] == 6
        finally:
            await tr.rollback()


async def test_browse_mode_returns_previews_with_higher_cap(db_pool):
    """#76: keyword-less window rows come back preview-grain; memories full."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            long_text = "a rambling turn " * 40  # ~640 chars
            await conn.fetchval(
                "SELECT recmem_ingest_turn($1, 'ok', NULL, 'preview-probe-1')",
                long_text,
            )
            await conn.execute(
                "UPDATE subconscious_units SET turn_at = CURRENT_TIMESTAMP - INTERVAL '1 hour' WHERE source_identity = 'preview-probe-1'"
            )
            rows = await conn.fetch(
                """
                SELECT content FROM search_cross_session_history(
                    '', 250, ARRAY['turn'],
                    CURRENT_TIMESTAMP - INTERVAL '2 hours', CURRENT_TIMESTAMP)
                """
            )
            probe = next(r for r in rows if "a rambling turn" in r["content"])
            assert probe["content"].endswith(" …")
            assert len(probe["content"]) < 300

            # Keyword mode returns the verbatim content.
            kw = await conn.fetch(
                "SELECT content FROM search_cross_session_history('rambling', 10)"
            )
            assert any(len(r["content"]) > 500 for r in kw)
        finally:
            await tr.rollback()


async def test_open_memory_returns_verbatim_units(db_pool):
    """#76: open_memory re-hydrates the exact turns behind a memory."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            unit_result = _json(await conn.fetchval(
                "SELECT recmem_ingest_turn('the exact words matter here', 'indeed they do', NULL, 'open-probe-1')"
            ))
            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status)
                VALUES ('episodic', 'A short scene about exact words.',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.6, 0.9, 'active')
                RETURNING id
                """
            )
            await conn.fetchval(
                "SELECT link_memory_to_source_unit($1::uuid, $2::uuid, 'source')",
                mem_id, unit_result["unit_id"],
            )
            result = _json(await conn.fetchval(
                "SELECT execute_memory_tool('open_memory', jsonb_build_object('memory_id', $1::text))",
                str(mem_id),
            ))
            units = result["output"]["source_units"]
            assert len(units) == 1
            assert "the exact words matter here" in units[0]["content"]
            assert "source unit(s)" in result["display_output"]
        finally:
            await tr.rollback()


async def test_open_memory_surfaces_pre_gist_full_content(db_pool):
    """#76: a gisted memory opens to its preserved full text."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mem_id = await conn.fetchval(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, metadata, fidelity)
                VALUES ('episodic', 'The gist.', array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.5, 0.9, 'active',
                        '{"consolidation": {"full_content": "The long original story, word for word."}}'::jsonb,
                        0.7)
                RETURNING id
                """
            )
            result = _json(await conn.fetchval(
                "SELECT get_memory_story($1::uuid)", mem_id
            ))
            assert result["full_content"] == "The long original story, word for word."
            assert result["memory"]["fidelity"] == 0.7
        finally:
            await tr.rollback()
