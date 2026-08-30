"""Original source artifacts + extraction runs (db/74, migration 0117):
sha256 dedup, bytes never rewritten, document link-on-retry, structured
warnings surfaced by open_source_document."""

from __future__ import annotations

import hashlib
import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed_document(conn, marker: str) -> str:
    stored = _j(await conn.fetchval(
        """
        SELECT upsert_source_document(
            $1, 'document', $2, $3, '.md', $4, 10, '{}'::jsonb, '{}'::jsonb
        )
        """,
        f"Artifact Doc {marker}",
        f"hash-{marker}",
        f"/tmp/{marker}.md",
        f"artifact test content {marker}",
    ))
    return stored["document_id"]


async def test_artifact_dedup_link_on_retry_and_original_hash(db_pool):
    marker = get_test_identifier("artifact")
    raw = f"original bytes {marker}".encode()
    sha = hashlib.sha256(raw).hexdigest()

    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            # Failed-extraction shape: artifact preserved with no document.
            first = _j(await conn.fetchval(
                """
                SELECT upsert_source_artifact($1, 'database', $2::bytea, NULL, NULL,
                                              $3, 'text/markdown', NULL, '{}'::jsonb)
                """,
                sha, raw, f"{marker}.md",
            ))
            assert first["deduplicated"] is False
            assert first["source_document_id"] is None
            assert first["byte_size"] == len(raw)

            # Retry after the document exists: same sha links the document,
            # keeps the bytes, stamps original_hash.
            doc_id = await _seed_document(conn, marker)
            second = _j(await conn.fetchval(
                """
                SELECT upsert_source_artifact($1, 'database', $2::bytea, NULL, $3::uuid,
                                              $4, 'text/markdown', NULL, '{"retry": true}'::jsonb)
                """,
                sha, b"DIFFERENT BYTES MUST NOT WIN", doc_id, f"{marker}.md",
            ))
            assert second["deduplicated"] is True
            assert second["artifact_id"] == first["artifact_id"]
            assert str(second["source_document_id"]) == str(doc_id)

            stored_bytes = await conn.fetchval(
                "SELECT bytes FROM source_artifacts WHERE id = $1::uuid",
                first["artifact_id"],
            )
            assert bytes(stored_bytes) == raw, "existing bytes are never rewritten"

            original_hash = await conn.fetchval(
                "SELECT original_hash FROM source_documents WHERE id = $1::uuid", doc_id
            )
            assert original_hash == sha

            handle = _j(await conn.fetchval(
                "SELECT get_source_artifact($1::uuid)", doc_id
            ))
            assert handle["sha256"] == sha
            assert handle["has_bytes"] is True
            assert "bytes" not in handle
        finally:
            await tr.rollback()


async def test_extraction_runs_and_open_document_warnings(db_pool):
    marker = get_test_identifier("extractrun")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            doc_id = await _seed_document(conn, marker)

            run = _j(await conn.fetchval(
                """
                SELECT record_source_extraction_run(
                    $1::uuid, NULL, 'pdfplumber', '0.11.9', 'completed',
                    $2::jsonb, '[]'::jsonb, NULL, '{}'::jsonb
                )
                """,
                doc_id,
                json.dumps([{"code": "ocr_used", "message": "OCR on 2 pages",
                             "detail": {"pages": [3, 4]}}]),
            ))
            # Warnings upgrade a 'completed' status automatically.
            assert run["status"] == "completed_with_warnings"

            opened = _j(await conn.fetchval(
                "SELECT open_source_document($1::uuid)", doc_id
            ))
            assert opened["extraction"]["extractor"] == "pdfplumber"
            assert opened["extraction"]["status"] == "completed_with_warnings"
            codes = [w["code"] for w in opened["extraction_warnings"]]
            assert codes == ["ocr_used"]

            # A failed run with no document is legal (artifact-only failures).
            failed = _j(await conn.fetchval(
                """
                SELECT record_source_extraction_run(
                    NULL, NULL, 'DocxReader', '', 'failed',
                    '[]'::jsonb, $1::jsonb, NULL, '{}'::jsonb
                )
                """,
                json.dumps([{"message": f"bad zip {marker}"}]),
            ))
            assert failed["status"] == "failed"
        finally:
            await tr.rollback()


async def test_redacted_artifact_is_frozen(db_pool):
    marker = get_test_identifier("artredact")
    raw = f"sensitive original {marker}".encode()
    sha = hashlib.sha256(raw).hexdigest()
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            first = _j(await conn.fetchval(
                "SELECT upsert_source_artifact($1, 'database', $2::bytea)",
                sha, raw,
            ))
            await conn.execute(
                "UPDATE source_artifacts SET status = 'redacted' WHERE id = $1::uuid",
                first["artifact_id"],
            )
            doc_id = await _seed_document(conn, marker)
            _j(await conn.fetchval(
                "SELECT upsert_source_artifact($1, 'database', NULL, NULL, $2::uuid, 'sneaky.md')",
                sha, doc_id,
            ))
            row = await conn.fetchrow(
                "SELECT source_document_id, original_filename FROM source_artifacts WHERE id = $1::uuid",
                first["artifact_id"],
            )
            assert row["source_document_id"] is None, "redacted artifacts never re-link"
            assert row["original_filename"] is None
        finally:
            await tr.rollback()
