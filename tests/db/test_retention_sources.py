"""Ownership-based source retention (migration 0121): the approve cascade
archives docs/chunks/bytes; the agent-source pass archives idle
agent-acquired docs, escalates heavily-referenced ones, and never touches
user-provided sources."""

from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_DUMMY = "array_fill(0.1, ARRAY[embedding_dimension()])::vector"


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed_source(conn, marker: str, *, acquisition: str | None,
                       idle_days: int = 0, memories: int = 0,
                       with_artifact: bool = False) -> str:
    attribution = {"kind": "document", "ref": f"hash-{marker}", "content_hash": f"hash-{marker}"}
    if acquisition:
        attribution["acquisition"] = acquisition
    stored = _j(await conn.fetchval(
        """
        SELECT upsert_source_document(
            $1, 'web', $2, $3, '.html', $4, 20, $5::jsonb, '{}'::jsonb
        )
        """,
        f"Retention Doc {marker}", f"hash-{marker}", f"https://example.com/{marker}",
        f"retention source content {marker}", json.dumps(attribution),
    ))
    doc_id = stored["document_id"]
    _j(await conn.fetchval(
        "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
        doc_id,
        json.dumps([{"chunk_index": 0, "content": f"retention chunk {marker}",
                     "char_start": 0, "char_end": 20}]),
    ))
    if with_artifact:
        await conn.fetchval(
            "SELECT upsert_source_artifact($1, 'database', $2::bytea, NULL, $3::uuid)",
            f"sha-{marker}", f"original bytes {marker}".encode(), doc_id,
        )
    for i in range(memories):
        # Timestamps land in the INSERT itself: post-hoc backdating would
        # desync the episode-assignment trigger's tstzrange bookkeeping.
        await conn.fetchval(
            f"""
            INSERT INTO memories (type, content, embedding, importance, trust_level,
                                  status, source_attribution, created_at)
            VALUES ('semantic', $1, {_DUMMY}, 0.6, 0.9, 'active', $2::jsonb,
                    CURRENT_TIMESTAMP - make_interval(days => $3::int))
            RETURNING id
            """,
            f"fact {i} from retention source {marker}",
            json.dumps({"kind": "web", "ref": f"hash-{marker}",
                        "content_hash": f"hash-{marker}", "label": f"Retention Doc {marker}"}),
            int(idle_days),
        )
    if idle_days:
        await conn.execute(
            f"""
            UPDATE source_documents
            SET last_ingested_at = CURRENT_TIMESTAMP - INTERVAL '{int(idle_days)} days'
            WHERE id = $1::uuid
            """,
            doc_id,
        )
    return doc_id


async def _enable_retention(conn):
    await conn.execute(
        """
        INSERT INTO config (key, value) VALUES ('retention.enabled', 'true'::jsonb)
        ON CONFLICT (key) DO UPDATE SET value = 'true'::jsonb
        """
    )


async def test_fade_approval_cascades_to_cabinet(db_pool):
    marker = get_test_identifier("fadecascade")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id = await _seed_source(conn, marker, acquisition="user",
                                        memories=2, with_artifact=True)
            await conn.execute(
                "INSERT INTO document_fade_requests (content_hash, label, memory_count) VALUES ($1, $2, 2)",
                f"hash-{marker}", f"Retention Doc {marker}",
            )

            result = _j(await conn.fetchval(
                "SELECT resolve_document_fade($1, 'approve')", f"hash-{marker}"
            ))
            assert result["decision"] == "approve"
            assert result["faded"] == 2

            doc = await conn.fetchrow(
                "SELECT status, metadata #>> '{retention,reason}' AS reason FROM source_documents WHERE id = $1::uuid",
                doc_id,
            )
            assert doc["status"] == "archived"
            assert doc["reason"] == "document_fade_approved"
            chunk_count = await conn.fetchval(
                "SELECT count(*) FROM source_document_chunks WHERE source_document_id = $1::uuid",
                doc_id,
            )
            assert chunk_count == 0
            artifact = await conn.fetchrow(
                "SELECT status, bytes IS NULL AS bytes_released FROM source_artifacts WHERE sha256 = $1",
                f"sha-{marker}",
            )
            assert artifact["status"] == "archived"
            assert artifact["bytes_released"] is True
        finally:
            await tr.rollback()


async def test_agent_source_pass_archives_idle_and_escalates_referenced(db_pool):
    marker = get_test_identifier("agentsource")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _enable_retention(conn)
            idle_agent = await _seed_source(conn, f"{marker}idle", acquisition="agent",
                                            idle_days=90, memories=1)
            hot_agent = await _seed_source(conn, f"{marker}hot", acquisition="agent",
                                           idle_days=90, memories=8)
            user_doc = await _seed_source(conn, f"{marker}user", acquisition="user",
                                          idle_days=400, memories=1)
            fresh_agent = await _seed_source(conn, f"{marker}fresh", acquisition="agent",
                                             idle_days=0, memories=1)

            result = _j(await conn.fetchval("SELECT run_agent_source_retention()"))
            assert result["archived"] == 1
            assert result["escalated"] == 1

            statuses = {
                str(row["id"]): row["status"]
                for row in await conn.fetch(
                    "SELECT id, status FROM source_documents WHERE id = ANY($1::uuid[])",
                    [idle_agent, hot_agent, user_doc, fresh_agent],
                )
            }
            assert statuses[str(idle_agent)] == "archived"
            assert statuses[str(hot_agent)] == "active", "heavily-referenced escalates, never auto-archives"
            assert statuses[str(user_doc)] == "active", "user sources NEVER auto-fade"
            assert statuses[str(fresh_agent)] == "active"

            reason = await conn.fetchval(
                "SELECT metadata #>> '{retention,reason}' FROM source_documents WHERE id = $1::uuid",
                idle_agent,
            )
            assert reason == "agent_source_idle"

            # Escalation created a pending fade request for the hot source.
            pending = await conn.fetchval(
                "SELECT status FROM document_fade_requests WHERE content_hash = $1",
                f"hash-{marker}hot",
            )
            assert pending == "pending"

            # Archived docs drop out of cabinet search but the row survives.
            rows = await conn.fetch(
                "SELECT * FROM search_source_documents($1, 10)", f"retention {marker}idle"
            )
            assert rows == []
        finally:
            await tr.rollback()


async def test_agent_source_pass_ships_dark(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO config (key, value) VALUES ('retention.enabled', 'false'::jsonb)
                ON CONFLICT (key) DO UPDATE SET value = 'false'::jsonb
                """
            )
            result = _j(await conn.fetchval("SELECT run_agent_source_retention()"))
            assert result.get("skipped") is True
        finally:
            await tr.rollback()
