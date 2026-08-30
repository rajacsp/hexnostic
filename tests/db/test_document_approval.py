"""Tests for ingested-document approval (db/47) -- Phase 5. Ingested documents are
the USER's data: auto-fade-immune, removed only with explicit user approval sought
via the outbox. A document's memories are grouped by source_attribution.content_hash."""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_DUMMY = "array_fill(0.1, ARRAY[embedding_dimension()])::vector"


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


async def _enable(conn):
    await conn.execute("SELECT set_config('retention.enabled', 'true'::jsonb)")


async def _ingest_doc(conn, content_hash, label, *, age_days=300, n_facts=2):
    """One episodic 'encounter' + N semantic facts, all sharing a content_hash."""
    attr = json.dumps({"kind": "document", "ref": content_hash, "content_hash": content_hash,
                       "label": label, "observed_at": None})
    ids = []
    enc = await conn.fetchval(
        f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, source_attribution) "
        f"VALUES ('episodic', $1, {_DUMMY}, 0.4, 0.95, 'active', now() - ($2 || ' days')::interval, "
        f"       jsonb_set($3::jsonb, '{{observed_at}}', to_jsonb((now() - ($2 || ' days')::interval)::text))) RETURNING id",
        f"I read '{label}'.", str(age_days), attr)
    ids.append(enc)
    for k in range(n_facts):
        fid = await conn.fetchval(
            f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, created_at, source_attribution) "
            f"VALUES ('semantic', $1, {_DUMMY}, 0.3, 0.6, 'active', now() - ($2 || ' days')::interval, "
            f"       jsonb_set($3::jsonb, '{{observed_at}}', to_jsonb((now() - ($2 || ' days')::interval)::text))) RETURNING id",
            f"{label} fact {k}", str(age_days), attr)
        ids.append(fid)
    return ids


async def test_ingested_memory_is_protected(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            ingested = await conn.fetchval(
                f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution) "
                f"VALUES ('semantic','a fact from a doc', {_DUMMY}, 0.3, 0.6, 'active', "
                f"       '{{\"kind\":\"document\",\"content_hash\":\"h1\",\"label\":\"Doc\"}}'::jsonb) RETURNING id")
            self_made = await conn.fetchval(
                f"INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution) "
                f"VALUES ('semantic','a fact I concluded', {_DUMMY}, 0.3, 0.6, 'active', "
                f"       '{{\"kind\":\"internal\"}}'::jsonb) RETURNING id")
            assert await conn.fetchval("SELECT is_memory_protected($1)", ingested) is True
            assert await conn.fetchval("SELECT is_memory_protected($1)", self_made) is False
        finally:
            await tr.rollback()


async def test_gc_capacity_prune_spares_ingested(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute("LOAD 'age'")
        tr = conn.transaction()
        await tr.start()
        try:
            await _enable(conn)
            await conn.execute("SELECT set_config('retention.capacity', '0.001'::jsonb)")  # extreme pressure
            ids = await _ingest_doc(conn, "hcap", "Capacity Doc")
            _j(await conn.fetchval("SELECT run_retention_gc()"))
            # the ingested episodic encounter must survive the capacity prune
            assert await conn.fetchval(
                "SELECT count(*) FROM memories WHERE id = ANY($1::uuid[]) AND status='active'", ids) == len(ids)
        finally:
            await tr.rollback()


async def test_find_stale_and_request_via_outbox(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _enable(conn)
            await _ingest_doc(conn, "hstale", "Quarterly Strategy Memo", age_days=300)
            stale = await conn.fetch("SELECT content_hash, label, memory_count FROM find_stale_ingested_documents()")
            assert any(r["content_hash"] == "hstale" for r in stale)

            outbox_before = await conn.fetchval("SELECT count(*) FROM outbox_messages")
            res = _j(await conn.fetchval("SELECT request_stale_document_fades()"))
            assert res["requested"] >= 1
            assert await conn.fetchval(
                "SELECT status FROM document_fade_requests WHERE content_hash='hstale'") == "pending"
            # one outbox ask was queued, tagged with the document_fade intent
            assert await conn.fetchval("SELECT count(*) FROM outbox_messages") == outbox_before + res["requested"]
            assert await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM outbox_messages WHERE envelope->'payload'->>'intent'='document_fade')")

            # idempotent: a second pass does not re-ask (pending request already exists)
            res2 = _j(await conn.fetchval("SELECT request_stale_document_fades()"))
            assert res2["requested"] == 0
        finally:
            await tr.rollback()


async def test_request_noop_when_disabled(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("SELECT set_config('retention.enabled', 'false'::jsonb)")
            await _ingest_doc(conn, "hoff", "Off Doc", age_days=300)
            assert _j(await conn.fetchval("SELECT request_stale_document_fades()")).get("skipped") is True
        finally:
            await tr.rollback()


async def test_approve_deletes_the_whole_document(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute("LOAD 'age'")
        tr = conn.transaction()
        await tr.start()
        try:
            ids = await _ingest_doc(conn, "happrove", "Old Manual")
            await conn.execute(
                "INSERT INTO document_fade_requests (content_hash, label, memory_count) VALUES ('happrove','Old Manual',3)")
            res = _j(await conn.fetchval("SELECT resolve_document_fade('happrove', 'approve')"))
            assert res["decision"] == "approve"
            assert res["faded"] == len(ids)
            assert await conn.fetchval("SELECT count(*) FROM memories WHERE id = ANY($1::uuid[])", ids) == 0
            assert await conn.fetchval(
                "SELECT status FROM document_fade_requests WHERE content_hash='happrove'") == "approved"
        finally:
            await tr.rollback()


async def test_keep_retains_and_lifts(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            ids = await _ingest_doc(conn, "hkeep", "Beloved Reference")
            await conn.execute(
                "INSERT INTO document_fade_requests (content_hash, label, memory_count) VALUES ('hkeep','Beloved Reference',3)")
            # match by (fuzzy) label rather than hash
            res = _j(await conn.fetchval("SELECT resolve_document_fade('beloved reference', 'keep')"))
            assert res["decision"] == "keep"
            assert await conn.fetchval("SELECT count(*) FROM memories WHERE id = ANY($1::uuid[]) AND status='active'", ids) == len(ids)
            assert await conn.fetchval("SELECT bool_and(last_reinforced IS NOT NULL) FROM memories WHERE id = ANY($1::uuid[])", ids)
            assert await conn.fetchval(
                "SELECT status FROM document_fade_requests WHERE content_hash='hkeep'") == "kept"
        finally:
            await tr.rollback()


async def test_resolve_unknown_ref_errors(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            res = _j(await conn.fetchval("SELECT resolve_document_fade('nonexistent doc', 'approve')"))
            assert "error" in res
        finally:
            await tr.rollback()
