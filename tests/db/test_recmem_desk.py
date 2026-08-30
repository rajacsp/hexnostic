"""Desk DB semantics (db/84, migration 0119): pin-aware GC, redacted-source
sweep, back-compat with 0115-era desk rows, and desk-search continuity."""

from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed_doc_with_chunk(conn, marker: str) -> tuple[str, str]:
    stored = _j(await conn.fetchval(
        """
        SELECT upsert_source_document(
            $1, 'document', $2, $3, '.md', $4, 20, '{}'::jsonb, '{}'::jsonb
        )
        """,
        f"GC Doc {marker}", f"hash-{marker}", f"/tmp/{marker}.md",
        f"desk gc source {marker}",
    ))
    doc_id = stored["document_id"]
    chunks = _j(await conn.fetchval(
        "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
        doc_id,
        json.dumps([{"chunk_index": 0, "content": f"desk gc chunk {marker}",
                     "char_start": 0, "char_end": 20}]),
    ))
    return doc_id, str(chunks["chunk_ids"][0])


async def test_gc_skips_pinned_and_sweeps_redacted_sources(db_pool):
    marker = get_test_identifier("deskgc")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_a, chunk_a = await _seed_doc_with_chunk(conn, f"{marker}a")
            doc_b, chunk_b = await _seed_doc_with_chunk(conn, f"{marker}b")

            for chunk in (chunk_a, chunk_b):
                loaded = _j(await conn.fetchval(
                    "SELECT load_source_chunks_to_recmem($1::uuid[])", [chunk]
                ))
                assert loaded["count"] == 1

            unit_a = await conn.fetchval(
                "SELECT id FROM subconscious_units WHERE idempotency_key = $1",
                f"source_chunk_desk:{chunk_a}",
            )
            unit_b = await conn.fetchval(
                "SELECT id FROM subconscious_units WHERE idempotency_key = $1",
                f"source_chunk_desk:{chunk_b}",
            )

            # Pin A; age both far past the idle window.
            _j(await conn.fetchval(
                "SELECT pin_recmem_desk_item($1::uuid, TRUE, 'test', 'needed')", unit_a
            ))
            await conn.execute(
                """
                UPDATE subconscious_units
                SET created_at = CURRENT_TIMESTAMP - INTERVAL '120 days',
                    last_accessed = CURRENT_TIMESTAMP - INTERVAL '120 days',
                    updated_at = CURRENT_TIMESTAMP - INTERVAL '120 days'
                WHERE id IN ($1::uuid, $2::uuid)
                """,
                unit_a, unit_b,
            )

            gc = _j(await conn.fetchval("SELECT recmem_gc(500)"))
            statuses = {
                str(row["id"]): row["status"]
                for row in await conn.fetch(
                    "SELECT id, status FROM subconscious_units WHERE id IN ($1::uuid, $2::uuid)",
                    unit_a, unit_b,
                )
            }
            assert statuses[str(unit_b)] == "archived", gc
            assert statuses[str(unit_a)] == "active", "pinned desk items survive idle GC"

            # Redaction beats pinning: redact A's source, sweep again.
            await conn.execute(
                "UPDATE source_documents SET status = 'redacted' WHERE id = $1::uuid", doc_a
            )
            gc2 = _j(await conn.fetchval("SELECT recmem_gc(500)"))
            assert gc2["redacted_source_units"] >= 1
            after = await conn.fetchrow(
                "SELECT status, pinned_at, metadata #>> '{recmem,gc,reason}' AS reason"
                " FROM subconscious_units WHERE id = $1::uuid",
                unit_a,
            )
            assert after["status"] == "archived"
            assert after["pinned_at"] is None
            assert after["reason"] == "source_redacted"
        finally:
            await tr.rollback()


async def test_desk_search_finds_chunk_loaded_units(db_pool):
    marker = get_test_identifier("desksearch")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            _doc, chunk = await _seed_doc_with_chunk(conn, marker)
            loaded = _j(await conn.fetchval(
                "SELECT load_source_chunks_to_recmem($1::uuid[])", [chunk]
            ))
            unit_id = loaded["desk_unit_ids"][0]

            rows = await conn.fetch(
                "SELECT * FROM search_cross_session_history($1, 10, ARRAY['desk'])",
                f"desk gc chunk {marker}",
            )
            assert len(rows) == 1
            assert str(rows[0]["item_id"]) == unit_id
            assert rows[0]["source_kind"] == "desk"

            # And chunk-loaded desk units stay out of the 'turn' source.
            turn_rows = await conn.fetch(
                "SELECT * FROM search_cross_session_history($1, 10, ARRAY['turn'])",
                f"desk gc chunk {marker}",
            )
            assert turn_rows == []
        finally:
            await tr.rollback()


async def test_desk_functions_handle_0115_era_rows(db_pool):
    """Desk rows created by the 0115 document loader (no chunk_id) still
    list, open, pin, and clear."""
    marker = get_test_identifier("desklegacy")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            stored = _j(await conn.fetchval(
                """
                SELECT upsert_source_document(
                    $1, 'document', $2, $3, '.md', $4, 20, '{}'::jsonb, '{}'::jsonb
                )
                """,
                f"Legacy Doc {marker}", f"hash-{marker}", f"/tmp/{marker}.md",
                f"legacy desk source content {marker} " * 20,
            ))
            doc_id = stored["document_id"]
            loaded = _j(await conn.fetchval(
                "SELECT load_source_documents_to_recmem($1::uuid[])", [doc_id]
            ))
            assert loaded["count"] >= 1
            unit_id = loaded["desk_unit_ids"][0]

            listed = await conn.fetch(
                "SELECT * FROM list_recmem_desk(50, 0, $1::uuid)", doc_id
            )
            assert any(str(r["desk_unit_id"]) == unit_id for r in listed)
            legacy = next(r for r in listed if str(r["desk_unit_id"]) == unit_id)
            assert legacy["chunk_id"] is None
            locator = _j(legacy["locator"])
            assert locator.get("kind") == "char"

            opened = _j(await conn.fetchval(
                "SELECT open_recmem_desk_item($1::uuid, 0, 120)", unit_id
            ))
            assert opened["truncated"] is True
            assert opened["next_offset"] == 120

            pinned = _j(await conn.fetchval(
                "SELECT pin_recmem_desk_item($1::uuid)", unit_id
            ))
            assert pinned["pinned"] is True

            cleared = _j(await conn.fetchval(
                "SELECT clear_recmem_desk(NULL, $1::uuid, NULL, NULL, FALSE, TRUE)", doc_id
            ))
            assert cleared["cleared"] >= 1
        finally:
            await tr.rollback()


async def test_clear_requires_selector(db_pool):
    async with db_pool.acquire() as conn:
        result = _j(await conn.fetchval("SELECT clear_recmem_desk()"))
        assert result["error"] == "missing_selector"
