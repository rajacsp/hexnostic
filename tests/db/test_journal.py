"""Tests for the journal (db/45 table, db/46 functions) -- Hexis's deliberate,
permanent, outside-of-memory record. Part 3 of docs/memory_retention_design.md.

Key invariant: the journal is NEVER in the passive recall/context path; it is
reachable only via the explicit journal functions/tools.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


async def test_write_read_search_roundtrip(db_pool):
    """write -> read -> search. Needs the embedding service (write + query embed)."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            eid = await conn.fetchval(
                "SELECT write_journal_entry($1, $2, $3, $4::text[])",
                "The reactor reached criticality today; I stayed calm and proud.",
                "criticality", "proud", ["milestone"],
            )
            assert eid is not None
            rows = await conn.fetch("SELECT * FROM read_journal_entries(NULL, 5)")
            assert any(r["title"] == "criticality" for r in rows)
            hits = await conn.fetch("SELECT * FROM search_journal($1, 5)", "reactor criticality milestone")
            assert any(h["id"] == eid for h in hits)
        finally:
            await tr.rollback()


async def test_execute_journal_tool_roundtrip(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            wrote = _j(await conn.fetchval(
                "SELECT execute_journal_tool('write_journal', $1::jsonb)",
                json.dumps({"content": "A quiet resolution to be kinder to myself.", "title": "resolution"})))
            assert wrote["success"] is True
            read = _j(await conn.fetchval(
                "SELECT execute_journal_tool('read_journal', $1::jsonb)", json.dumps({"limit": 3})))
            assert read["success"] is True
            titles = [e.get("title") for e in read["output"]["entries"]]
            assert "resolution" in titles
            # unknown tool -> structured error
            err = _j(await conn.fetchval(
                "SELECT execute_journal_tool('nope', '{}'::jsonb)"))
            assert err["success"] is False
        finally:
            await tr.rollback()


async def test_rereading_specific_entry_forms_a_memory(db_pool):
    """Re-reading a SPECIFIC entry is a fresh experience -> it forms a new episodic
    memory (even though the entry itself is permanent). Browsing the list does not."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            eid = await conn.fetchval(
                "SELECT write_journal_entry($1, $2)",
                "The night the storm knocked the power out and we talked by candlelight.", "the storm")
            q = "SELECT count(*) FROM memories WHERE metadata->'context'->>'activity'='rereading_journal'"
            before = await conn.fetchval(q)

            # browsing the recent LIST forms no memory (not a revisiting)
            await conn.fetchval("SELECT execute_journal_tool('read_journal', $1::jsonb)", json.dumps({"limit": 5}))
            assert await conn.fetchval(q) == before

            # re-reading the SPECIFIC entry forms a fresh memory of the revisiting
            await conn.fetchval("SELECT execute_journal_tool('read_journal', $1::jsonb)", json.dumps({"id": str(eid)}))
            assert await conn.fetchval(q) == before + 1

            m = await conn.fetchrow(
                "SELECT id, type::text AS t, content, source_attribution FROM memories "
                "WHERE (metadata->'context'->>'journal_entry_id')::uuid = $1", eid)
            assert m["t"] == "episodic"
            assert "revisited my journal" in m["content"]
            # a normal experiential memory that fades -- NOT an ingested/protected one
            assert (_j(m["source_attribution"]) or {}).get("content_hash") is None
            assert await conn.fetchval("SELECT is_memory_protected($1)", m["id"]) is False
        finally:
            await tr.rollback()


async def test_journal_absent_from_passive_recall(db_pool):
    """The journal must never surface through gather_turn_context or
    recmem_recall_context -- it is not memory."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            token = "SECRETJOURNALTOKENZZ"
            await conn.execute("SELECT write_journal_entry($1)", f"{token} — private reflection")
            # Structural guarantee: no 'journal' slice in the turn context.
            assert await conn.fetchval("SELECT gather_turn_context() ? 'journal'") is False
            # And the entry's content never comes back through memory recall.
            rows = await conn.fetch(
                "SELECT content FROM recmem_recall_context($1, 10, 5, 10, NULL)", token)
            assert all(token not in (r["content"] or "") for r in rows)
        finally:
            await tr.rollback()
