"""Hybrid chunk retrieval (db/83, migration 0118): lexical ⟗ vector fusion
with inspectable rank_components, graceful lexical-only degradation,
sensitivity/locator filters, scroll-capable open, and document-search
best-chunk aggregation."""

from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _stub_get_embedding(conn, axis=1):
    """Deterministic one-hot query embedding (transaction-scoped)."""
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(
                array_agg((
                    array_fill(0.0::float, ARRAY[AXIS - 1]) ||
                    ARRAY[1.0::float] ||
                    array_fill(0.0::float, ARRAY[embedding_dimension() - AXIS])
                )::vector),
                ARRAY[]::vector[]
            )
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """.replace("AXIS", str(int(axis)))
    )


async def _failing_get_embedding(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
        BEGIN
            RAISE EXCEPTION 'embedding service unreachable';
        END;
        $$ LANGUAGE plpgsql;
        """
    )


async def _seed_doc_with_chunks(conn, marker: str, chunks: list[str],
                                 sensitivity: str | None = None) -> tuple[str, list[str]]:
    attribution = {"kind": "document", "ref": f"hash-{marker}"}
    if sensitivity:
        attribution["sensitivity"] = sensitivity
    stored = _j(await conn.fetchval(
        """
        SELECT upsert_source_document(
            $1, 'document', $2, $3, '.md', $4, 30, $5::jsonb, '{}'::jsonb
        )
        """,
        f"Hybrid Doc {marker}",
        f"hash-{marker}",
        f"/tmp/{marker}.md",
        "\n\n".join(chunks),
        json.dumps(attribution),
    ))
    doc_id = stored["document_id"]
    payload = json.dumps([
        {"chunk_index": i, "locator_kind": "section", "locator": {"kind": "section"},
         "heading_path": [f"H{i}"], "content": c,
         "char_start": 0, "char_end": len(c), "page_start": i + 1, "page_end": i + 1}
        for i, c in enumerate(chunks)
    ])
    result = _j(await conn.fetchval(
        "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
        doc_id, payload,
    ))
    return doc_id, [str(c) for c in result["chunk_ids"]]


async def _embed_chunk(conn, chunk_id: str, axis: int) -> None:
    await conn.execute(
        f"""
        UPDATE source_document_chunks
        SET embedding = (
                array_fill(0.0::float, ARRAY[{axis} - 1]) ||
                ARRAY[1.0::float] ||
                array_fill(0.0::float, ARRAY[embedding_dimension() - {axis}])
            )::vector,
            embedding_status = 'embedded'
        WHERE id = $1::uuid
        """,
        chunk_id,
    )


async def test_hybrid_fusion_vector_and_lexical_with_components(db_pool):
    marker = get_test_identifier("hybridfuse")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(conn, marker, [
                f"Semantically related passage about orbital mechanics {marker}.",
                f"The zephyrquark keyword appears only here {marker}.",
            ])
            # Chunk 0: vector hit (same axis as the stubbed query embedding).
            await _embed_chunk(conn, chunk_ids[0], axis=1)
            # Chunk 1: embedded far away — lexical-only hit.
            await _embed_chunk(conn, chunk_ids[1], axis=5)
            await _stub_get_embedding(conn, axis=1)

            rows = await conn.fetch(
                "SELECT * FROM search_source_chunks($1, 10, $2::uuid)",
                f"zephyrquark {marker}", doc_id,
            )
            assert len(rows) == 2
            by_chunk = {str(r["chunk_id"]): r for r in rows}

            vector_row = by_chunk[chunk_ids[0]]
            lexical_row = by_chunk[chunk_ids[1]]

            v_comp = _j(vector_row["rank_components"])
            l_comp = _j(lexical_row["rank_components"])
            assert v_comp["vector"] == pytest.approx(1.0, abs=1e-6)
            assert "lexical" not in v_comp or v_comp.get("lexical") is None
            assert l_comp["lexical"] == pytest.approx(1.0, abs=1e-6)
            assert l_comp["weights"]["vector"] == pytest.approx(0.6)
            assert "degraded" not in l_comp
            assert l_comp["trust"] == pytest.approx(0.5)
            assert 0.0 < l_comp["recency"] <= 1.0

            # Handles + locators ride every row.
            assert lexical_row["page_start"] == 2
            assert lexical_row["heading_path"] == ["H1"]
            assert "zephyrquark" in lexical_row["snippet"]
        finally:
            await tr.rollback()


async def test_search_degrades_to_lexical_when_embeddings_fail(db_pool):
    marker = get_test_identifier("hybriddegrade")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(conn, marker, [
                f"The quorlin threshold is defined in this passage {marker}.",
            ])
            await _failing_get_embedding(conn)

            rows = await conn.fetch(
                "SELECT * FROM search_source_chunks($1, 10, $2::uuid)",
                f"quorlin {marker}", doc_id,
            )
            assert len(rows) == 1
            comp = _j(rows[0]["rank_components"])
            assert comp["degraded"] == "embedding_unavailable"
            assert comp["lexical"] == pytest.approx(1.0, abs=1e-6)
            assert rows[0]["rank"] > 0
        finally:
            await tr.rollback()


async def test_sensitivity_gate_and_filters(db_pool):
    marker = get_test_identifier("hybridfilter")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn, axis=3)
            private_doc, _ = await _seed_doc_with_chunks(
                conn, f"{marker}priv", [f"private crystalfrost detail {marker}"],
                sensitivity="private",
            )
            public_doc, _ = await _seed_doc_with_chunks(
                conn, f"{marker}pub", [f"shared crystalfrost detail {marker}"],
            )

            open_rows = await conn.fetch(
                "SELECT * FROM search_source_chunks($1, 20)", f"crystalfrost {marker}"
            )
            open_docs = {str(r["document_id"]) for r in open_rows}
            assert {str(private_doc), str(public_doc)} <= open_docs

            gated = await conn.fetch(
                """
                SELECT * FROM search_source_chunks(
                    $1, 20, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, TRUE
                )
                """,
                f"crystalfrost {marker}",
            )
            gated_docs = {str(r["document_id"]) for r in gated}
            assert str(private_doc) not in gated_docs
            assert str(public_doc) in gated_docs

            # Page-range filter narrows to overlapping chunks.
            paged = await conn.fetch(
                """
                SELECT * FROM search_source_chunks(
                    $1, 20, $2::uuid, NULL, NULL, NULL, NULL, 1, 1
                )
                """,
                f"crystalfrost {marker}", public_doc,
            )
            assert len(paged) == 1
            assert paged[0]["page_start"] == 1
        finally:
            await tr.rollback()


async def test_browse_mode_lists_scoped_chunks_only(db_pool):
    marker = get_test_identifier("hybridbrowse")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(conn, marker, [
                f"first passage {marker}", f"second passage {marker}",
            ])
            unscoped = await conn.fetch("SELECT * FROM search_source_chunks(NULL, 10)")
            assert unscoped == []

            scoped = await conn.fetch(
                "SELECT * FROM search_source_chunks(NULL, 10, $1::uuid)", doc_id
            )
            assert [str(r["chunk_id"]) for r in scoped] == chunk_ids
            assert all(r["rank"] == 0.0 for r in scoped)
        finally:
            await tr.rollback()


async def test_open_source_chunks_scroll_handles_and_access(db_pool):
    marker = get_test_identifier("chunkopen")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(conn, marker, [
                f"page one text {marker}", f"page two text {marker}", f"page three text {marker}",
            ])

            opened = _j(await conn.fetchval(
                "SELECT open_source_chunks(NULL, $1::uuid, 1, 1)", doc_id
            ))
            assert opened["count"] == 1
            middle = opened["chunks"][0]
            assert middle["chunk_id"] == chunk_ids[1]
            assert middle["prev_chunk_id"] == chunk_ids[0]
            assert middle["next_chunk_id"] == chunk_ids[2]
            assert middle["content"] == f"page two text {marker}"

            accessed = await conn.fetchval(
                "SELECT access_count FROM source_document_chunks WHERE id = $1::uuid",
                chunk_ids[1],
            )
            assert accessed == 1

            # Page-range selector (page N == chunk N+1 in the fixture).
            paged = _j(await conn.fetchval(
                "SELECT open_source_chunks(NULL, $1::uuid, NULL, NULL, 3, 3)", doc_id
            ))
            assert [c["chunk_id"] for c in paged["chunks"]] == [chunk_ids[2]]

            # Explicit id list preserves request order.
            listed = _j(await conn.fetchval(
                "SELECT open_source_chunks($1::uuid[])",
                [chunk_ids[2], chunk_ids[0]],
            ))
            assert [c["chunk_id"] for c in listed["chunks"]] == [chunk_ids[2], chunk_ids[0]]

            missing = _j(await conn.fetchval("SELECT open_source_chunks(NULL, NULL)"))
            assert missing["error"] == "missing_selector"
        finally:
            await tr.rollback()


async def test_document_search_aggregates_best_chunk(db_pool):
    marker = get_test_identifier("docagg")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn, axis=2)
            doc_id, chunk_ids = await _seed_doc_with_chunks(conn, marker, [
                f"unrelated preamble {marker}",
                f"the flumewhistle clause lives here {marker}",
            ])

            rows = await conn.fetch(
                "SELECT * FROM search_source_documents($1, 5)",
                f"flumewhistle {marker}",
            )
            assert len(rows) == 1
            row = rows[0]
            assert str(row["document_id"]) == str(doc_id)
            assert str(row["best_chunk_id"]) == chunk_ids[1]
            comp = _j(row["rank_components"])
            assert comp["doc_lexical"] > 0
            assert comp["best_chunk_rank"] > 0
            assert comp["best_chunk"]["lexical"] == pytest.approx(1.0, abs=1e-6)
            assert row["rank"] >= comp["doc_lexical"]
            assert _j(row["extraction_warnings"]) == []

            # Browse mode regression: filters still page through documents.
            browse = await conn.fetch(
                "SELECT * FROM search_source_documents(NULL, 5, $1)",
                f"/tmp/{marker}",
            )
            assert len(browse) == 1
            assert browse[0]["rank"] == 0.0
            assert browse[0]["best_chunk_id"] is None
        finally:
            await tr.rollback()
