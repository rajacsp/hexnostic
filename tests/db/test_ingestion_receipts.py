"""Per-section ingestion receipts (#85/#90 stage 1): completion is recorded
atomically with persistence, looked up with a legacy whole-document UNION.
"""
from __future__ import annotations

import json
import uuid

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _stub_get_embedding(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                ARRAY[2.0 + abs(hashtext(t)) % 100 / 100.0::float] ||
                array_fill(0.1::float, ARRAY[embedding_dimension() - 1])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents) t
        $$ LANGUAGE sql;
        """
    )


async def test_record_is_idempotent_and_lookup_matches(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                "SELECT record_ingestion_receipt('doc-r', 'sec-1', NULL, 3, '/a.md')"
            )
            await conn.execute(
                "SELECT record_ingestion_receipt('doc-r', 'sec-1', NULL, 99, '/a.md')"
            )
            receipts = json.loads(await conn.fetchval(
                "SELECT get_ingestion_receipts('doc-r', ARRAY['sec-1', 'sec-2'])"
            ))
            kept = await conn.fetchval(
                "SELECT memories_created FROM ingestion_receipts WHERE doc_ref = 'doc-r' AND section_hash = 'sec-1'"
            )
        finally:
            await tr.rollback()

    assert set(receipts.keys()) == {"sec-1"}
    assert kept == 3  # first write wins; re-records are no-ops


async def test_legacy_document_receipts_still_skip(db_pool):
    """Documents ingested before the table exist only as memory attributions;
    the UNION keeps their skip working."""
    doc_hash = f"legacy-{uuid.uuid4().hex[:12]}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute(
                """
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution)
                VALUES ('episodic', 'Legacy receipt pin',
                        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
                        0.4, 0.9, 'active',
                        jsonb_build_object('ref', $1::text, 'content_hash', $1::text))
                """,
                doc_hash,
            )
            receipts = json.loads(await conn.fetchval(
                "SELECT get_ingestion_receipts($1, ARRAY[$1])", doc_hash
            ))
        finally:
            await tr.rollback()

    assert doc_hash in receipts
    assert receipts[doc_hash] is not None


async def test_persist_records_section_receipt_atomically(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            source = {
                "kind": "documentation",
                "ref": "doc-atomic",
                "content_hash": "doc-atomic",
                "section_hash": "sec-atomic-1",
                "label": "Receipt atomicity pin",
                "trust": 0.8,
            }
            result = json.loads(await conn.fetchval(
                "SELECT ingest_persist_extractions($1::jsonb, $2::jsonb, NULL, 0.0, '{}'::jsonb)",
                json.dumps([{
                    "content": "Receipt atomicity pin fact one.",
                    "confidence": 0.9,
                    "importance": 0.6,
                }]),
                json.dumps(source),
            ))
            receipt = await conn.fetchrow(
                "SELECT memories_created FROM ingestion_receipts WHERE doc_ref = 'doc-atomic' AND section_hash = 'sec-atomic-1'"
            )
        finally:
            await tr.rollback()

    assert len(result["created"]) == 1
    assert receipt is not None
    assert receipt["memories_created"] == 1


async def test_persist_without_section_hash_records_nothing(db_pool):
    """Stage-1 inertness: the current Python (no section_hash) is unaffected."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await conn.fetchval(
                "SELECT ingest_persist_extractions($1::jsonb, $2::jsonb, NULL, 0.0, '{}'::jsonb)",
                json.dumps([{"content": "No-receipt fact.", "confidence": 0.9}]),
                json.dumps({"kind": "documentation", "ref": "doc-plain", "content_hash": "doc-plain"}),
            )
            count = await conn.fetchval(
                "SELECT COUNT(*) FROM ingestion_receipts WHERE doc_ref = 'doc-plain'"
            )
        finally:
            await tr.rollback()

    assert count == 0
