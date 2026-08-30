"""Durable source-document chunks: keep-if-unchanged upsert, embed queue,
provenance whitelist, and open_memory chunk handles (db/83, migration 0116)."""

from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_DUMMY = "array_fill(0.1, ARRAY[embedding_dimension()])::vector"


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed_document(conn, marker: str, content: str) -> str:
    stored = _j(await conn.fetchval(
        """
        SELECT upsert_source_document(
            $1, 'document', $2, $3, '.md', $4, 20, $5::jsonb, '{}'::jsonb
        )
        """,
        f"Chunk Source {marker}",
        f"hash-{marker}",
        f"/tmp/{marker}.md",
        content,
        json.dumps({"kind": "document", "ref": f"hash-{marker}"}),
    ))
    return stored["document_id"]


def _chunk_payload(chunks: list[str]) -> str:
    return json.dumps([
        {
            "chunk_index": i,
            "locator_kind": "section",
            "locator": {"kind": "section", "char_start": i * 100, "char_end": i * 100 + len(c)},
            "heading_path": [f"H{i}"],
            "content": c,
            "char_start": i * 100,
            "char_end": i * 100 + len(c),
        }
        for i, c in enumerate(chunks)
    ])


async def test_chunk_upsert_keeps_ids_and_embeddings_when_unchanged(db_pool):
    marker = get_test_identifier("chunkstable")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id = await _seed_document(conn, marker, f"chunk stability {marker}")

            first = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"alpha {marker}", f"beta {marker}", f"gamma {marker}"]),
            ))
            assert first.get("error") is None
            assert first["count"] == 3
            assert first["inserted"] == 3
            ids_before = [str(cid) for cid in first["chunk_ids"]]
            assert len(ids_before) == 3

            # Simulate the embed worker finishing chunk 0.
            await conn.execute(
                f"""
                UPDATE source_document_chunks
                SET embedding = {_DUMMY}, embedding_status = 'embedded',
                    embedded_at = CURRENT_TIMESTAMP, embedding_model = 'test-model'
                WHERE id = $1::uuid
                """,
                ids_before[0],
            )

            # Identical payload: ids and the embedding survive.
            second = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"alpha {marker}", f"beta {marker}", f"gamma {marker}"]),
            ))
            assert second["inserted"] == 0
            assert second["unchanged"] == 3
            assert second["re_embedded"] == 0
            assert [str(cid) for cid in second["chunk_ids"]] == ids_before
            kept = await conn.fetchrow(
                "SELECT embedding_status, embedding_model, embedding IS NOT NULL AS has_embedding"
                " FROM source_document_chunks WHERE id = $1::uuid",
                ids_before[0],
            )
            assert kept["embedding_status"] == "embedded"
            assert kept["has_embedding"] is True
            assert kept["embedding_model"] == "test-model"

            # Changed content on chunk 0: id survives, embedding resets.
            third = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"alpha CHANGED {marker}", f"beta {marker}", f"gamma {marker}"]),
            ))
            assert third["unchanged"] == 2
            assert third["re_embedded"] == 1
            assert [str(cid) for cid in third["chunk_ids"]] == ids_before
            reset = await conn.fetchrow(
                "SELECT embedding_status, embedding IS NULL AS embedding_cleared, content"
                " FROM source_document_chunks WHERE id = $1::uuid",
                ids_before[0],
            )
            assert reset["embedding_status"] == "pending"
            assert reset["embedding_cleared"] is True
            assert reset["content"] == f"alpha CHANGED {marker}"

            # Shorter chunk set trims the tail.
            fourth = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"alpha CHANGED {marker}", f"beta {marker}"]),
            ))
            assert fourth["trimmed"] == 1
            remaining = await conn.fetchval(
                "SELECT count(*) FROM source_document_chunks WHERE source_document_id = $1::uuid",
                doc_id,
            )
            assert remaining == 2
        finally:
            await tr.rollback()


async def test_chunk_upsert_frozen_for_redacted_documents(db_pool):
    marker = get_test_identifier("chunkredact")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id = await _seed_document(conn, marker, f"redaction freeze {marker}")
            await conn.execute(
                "UPDATE source_documents SET status = 'redacted' WHERE id = $1::uuid",
                doc_id,
            )
            result = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"leak attempt {marker}"]),
            ))
            assert result["error"] == "document_redacted"
            count = await conn.fetchval(
                "SELECT count(*) FROM source_document_chunks WHERE source_document_id = $1::uuid",
                doc_id,
            )
            assert count == 0
        finally:
            await tr.rollback()


async def test_chunk_embed_queue_claim_fail_and_doc_status_gate(db_pool):
    marker = get_test_identifier("chunkqueue")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            active_id = await _seed_document(conn, f"{marker}a", f"embed queue active {marker}")
            archived_id = await _seed_document(conn, f"{marker}b", f"embed queue archived {marker}")

            for doc_id, text in ((active_id, "active"), (archived_id, "archived")):
                result = _j(await conn.fetchval(
                    "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                    doc_id, _chunk_payload([f"{text} chunk {marker}"]),
                ))
                assert result.get("error") is None
            await conn.execute(
                "UPDATE source_documents SET status = 'archived' WHERE id = $1::uuid",
                archived_id,
            )
            # Make this test's chunks the oldest so the claim picks them first.
            await conn.execute(
                """
                UPDATE source_document_chunks
                SET created_at = TIMESTAMPTZ '2000-01-01'
                WHERE source_document_id IN ($1::uuid, $2::uuid)
                """,
                active_id, archived_id,
            )

            claimed = _j(await conn.fetchval(
                "SELECT claim_source_chunks_unembedded_batch(1)"
            ))
            assert len(claimed) == 1
            claimed_id = claimed[0]["chunk_id"]
            owner = await conn.fetchval(
                "SELECT source_document_id FROM source_document_chunks WHERE id = $1::uuid",
                claimed_id,
            )
            # Chunks of non-active documents are never claimed.
            assert str(owner) == str(active_id)
            status = await conn.fetchval(
                "SELECT embedding_status FROM source_document_chunks WHERE id = $1::uuid",
                claimed_id,
            )
            assert status == "in_progress"

            # First failure re-queues; exhausted attempts mark failed.
            failed = _j(await conn.fetchval(
                "SELECT fail_source_chunk_embedding($1::uuid, 'sidecar down')",
                claimed_id,
            ))
            assert failed["embedding_status"] == "pending"
            await conn.execute(
                "UPDATE source_document_chunks SET embedding_attempts = 99 WHERE id = $1::uuid",
                claimed_id,
            )
            exhausted = _j(await conn.fetchval(
                "SELECT fail_source_chunk_embedding($1::uuid, 'sidecar still down')",
                claimed_id,
            ))
            assert exhausted["embedding_status"] == "failed"
            error_meta = _j(await conn.fetchval(
                "SELECT metadata->'embedding_error' FROM source_document_chunks WHERE id = $1::uuid",
                claimed_id,
            ))
            assert error_meta["error"] == "sidecar still down"
        finally:
            await tr.rollback()


async def test_backfill_candidates_finds_unchunked_and_stale_versions(db_pool):
    marker = get_test_identifier("chunkbackfill")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            bare_id = await _seed_document(conn, f"{marker}bare", f"no chunks yet {marker}")
            chunked_id = await _seed_document(conn, f"{marker}done", f"already chunked {marker}")
            _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v1-old')",
                chunked_id, _chunk_payload([f"old chunker output {marker}"]),
            ))

            candidates = _j(await conn.fetchval(
                "SELECT source_chunk_backfill_candidates(1000)"
            ))
            ids = {c["document_id"] for c in candidates}
            assert str(bare_id) in ids
            assert str(chunked_id) not in ids

            versioned = _j(await conn.fetchval(
                "SELECT source_chunk_backfill_candidates(1000, 'v2')"
            ))
            ids = {c["document_id"] for c in versioned}
            assert str(bare_id) in ids
            assert str(chunked_id) in ids
        finally:
            await tr.rollback()


async def test_normalize_source_reference_preserves_chunk_handles(db_pool):
    async with db_pool.acquire() as conn:
        normalized = _j(await conn.fetchval(
            "SELECT normalize_source_reference($1::jsonb)",
            json.dumps({
                "kind": "document",
                "ref": "hash-xyz",
                "content_hash": "hash-xyz",
                "document_id": "0e3777f8-58b8-4a44-9a67-30f30fdb978c",
                "chunk_id": "9a129b1f-2f5e-4f5a-8f00-111111111111",
                "chunk_index": 4,
                "sensitivity": "private",
            }),
        ))
        assert normalized["chunk_id"] == "9a129b1f-2f5e-4f5a-8f00-111111111111"
        assert normalized["chunk_index"] == 4
        assert normalized["sensitivity"] == "private"
        assert normalized["content_hash"] == "hash-xyz"


async def test_get_memory_story_surfaces_chunk_handles(db_pool):
    marker = get_test_identifier("chunkstory")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id = await _seed_document(conn, marker, f"story chunk provenance {marker}")
            chunks = _j(await conn.fetchval(
                "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
                doc_id, _chunk_payload([f"cited passage {marker}"]),
            ))
            chunk_id = str(chunks["chunk_ids"][0])

            memory_id = await conn.fetchval(
                f"""
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution)
                VALUES ('semantic', $1, {_DUMMY}, 0.8, 0.9, 'active', $2::jsonb)
                RETURNING id
                """,
                f"A fact extracted from the cited passage {marker}.",
                json.dumps({
                    "kind": "document",
                    "ref": f"hash-{marker}",
                    "content_hash": f"hash-{marker}",
                    "source_document_id": doc_id,
                    "document_id": doc_id,
                    "chunk_id": chunk_id,
                    "chunk_index": 0,
                }),
            )

            story = _j(await conn.fetchval(
                "SELECT get_memory_story($1::uuid)", memory_id
            ))
            docs = story.get("source_documents") or []
            assert any(str(d["document_id"]) == str(doc_id) for d in docs)
            story_chunks = story.get("source_chunks") or []
            assert len(story_chunks) == 1
            assert str(story_chunks[0]["chunk_id"]) == chunk_id
            assert story_chunks[0]["chunk_index"] == 0
            assert story_chunks[0]["heading_path"] == ["H0"]
        finally:
            await tr.rollback()
