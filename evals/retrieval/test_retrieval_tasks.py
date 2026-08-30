"""The spec's 11 required retrieval tasks (tier 1: deterministic, CI-safe).

Each task drives the real tool handlers over the ingested fixture corpus and
records tool calls / output size / latency into the JSON report.
"""

from __future__ import annotations

import json
import os
import uuid

import pytest

from core.tools.desk import ClearDeskHandler, ListDeskHandler, OpenDeskItemHandler
from core.tools.memory import (
    LoadDocumentChunksHandler,
    OpenDocumentChunkHandler,
    SearchDocumentChunksHandler,
    SearchDocumentsHandler,
    SearchHistoryHandler,
)
from evals.retrieval.harness import EvalHarness

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_FULL = os.environ.get("HEXIS_EVAL_FULL") == "1"

_DUMMY = "array_fill(0.1, ARRAY[embedding_dimension()])::vector"


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


# Task 1: find a section by exact phrase (recall@5 with correct locator).
async def test_exact_phrase(db_pool, corpus, report):
    h = EvalHarness(db_pool, "exact_phrase")
    result = await h.call(SearchDocumentChunksHandler(), {"query": "verdigris retention window"})
    assert result.success, result.error
    top5 = result.output["chunks"][:5]
    hit = next((c for c in top5 if corpus["gold"]["exact_phrase"] in (c["snippet"] or "")
                or "verdigris" in (c["snippet"] or "")), None)
    passed = hit is not None and hit["document_id"] == corpus["docs"]["spec"]["id"] \
        and "Retention" in (hit["heading_path"] or [])
    report.add(h, passed=passed, heading_path=hit["heading_path"] if hit else None)
    assert passed, top5


# Task 2: find a section by paraphrase (tier 2 — needs real embeddings).
@pytest.mark.skipif(not _FULL, reason="paraphrase recall needs real embeddings (HEXIS_EVAL_FULL=1)")
async def test_paraphrase(db_pool, corpus, report):
    h = EvalHarness(db_pool, "paraphrase")
    result = await h.call(SearchDocumentChunksHandler(),
                          {"query": "how long records are kept before deletion"})
    assert result.success, result.error
    top5 = result.output["chunks"][:5]
    passed = any(c["document_id"] == corpus["docs"]["spec"]["id"] for c in top5)
    report.add(h, passed=passed)
    assert passed


# Task 3: a question requiring two distant sections of one document.
async def test_two_distant_sections(db_pool, corpus, report):
    h = EvalHarness(db_pool, "two_distant_sections")
    doc_id = corpus["docs"]["spec"]["id"]
    first = await h.call(SearchDocumentChunksHandler(),
                         {"query": "northwind escalation threshold", "document_id": doc_id})
    second = await h.call(SearchDocumentChunksHandler(),
                          {"query": "northwind archive cadence", "document_id": doc_id})
    got_a = any("12 incidents" in (c["snippet"] or "") for c in first.output["chunks"])
    got_b = any("quarterly" in (c["snippet"] or "") for c in second.output["chunks"])
    passed = got_a and got_b and h.record.tool_calls <= 4
    report.add(h, passed=passed)
    assert passed


# Task 4: comparison across documents.
async def test_cross_document_comparison(db_pool, corpus, report):
    h = EvalHarness(db_pool, "cross_document_comparison")
    retention = await h.call(SearchDocumentChunksHandler(), {"query": "verdigris retention window"})
    backup = await h.call(SearchDocumentChunksHandler(), {"query": "saffron backup offsite copies"})
    docs_hit = {c["document_id"] for c in retention.output["chunks"]} | {
        c["document_id"] for c in backup.output["chunks"]
    }
    passed = corpus["docs"]["spec"]["id"] in docs_hit and corpus["docs"]["doc_b"]["id"] in docs_hit
    report.add(h, passed=passed)
    assert passed


# Task 5: retrieve a memory, follow its source handle, cite the source.
async def test_memory_provenance_citation(db_pool, corpus, report):
    h = EvalHarness(db_pool, "memory_provenance_citation")
    doc = corpus["docs"]["pdf"]
    async with db_pool.acquire() as conn:
        chunk = await conn.fetchrow(
            """
            SELECT id::text AS id, page_start FROM source_document_chunks
            WHERE source_document_id = $1::uuid AND content ILIKE '%lattice budget cap%'
            LIMIT 1
            """,
            doc["id"],
        )
        assert chunk is not None
        memory_id = await conn.fetchval(
            f"""
            INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution)
            VALUES ('semantic', 'The lattice budget cap is 40000 dollars.', {_DUMMY},
                    0.8, 0.9, 'active', $1::jsonb)
            RETURNING id
            """,
            json.dumps({
                "kind": "document", "ref": doc["attribution"].get("content_hash"),
                "content_hash": doc["attribution"].get("content_hash"),
                "source_document_id": doc["id"], "document_id": doc["id"],
                "chunk_id": chunk["id"], "chunk_index": 0,
            }),
        )
        story = _j(await conn.fetchval("SELECT get_memory_story($1::uuid)", memory_id))
    handles = story.get("source_chunks") or []
    assert handles, story
    opened = await h.call(OpenDocumentChunkHandler(), {"chunk_id": handles[0]["chunk_id"]})
    chunk_payload = opened.output["chunks"][0]
    passed = (
        "lattice budget cap" in chunk_payload["content"]
        and f"page {chunk['page_start']}" in chunk_payload["citation"]
    )
    report.add(h, passed=passed, citation=chunk_payload["citation"])
    assert passed


# Task 6: load a document to the desk and search within it.
async def test_desk_load_and_search(db_pool, corpus, report):
    h = EvalHarness(db_pool, "desk_load_and_search")
    doc_id = corpus["docs"]["spec"]["id"]
    loaded = await h.call(LoadDocumentChunksHandler(),
                          {"document_id": doc_id, "query": "verdigris retention",
                           "limit": 2, "reason": "eval task 6"})
    assert loaded.success, loaded.error
    found = await h.call(SearchHistoryHandler(),
                         {"query": "verdigris retention window", "sources": ["desk"]})
    results = found.output.get("results") or found.output.get("items") or []
    desk_ids = {str(u) for u in loaded.output["desk_unit_ids"]}
    passed = any(str(r.get("item_id")) in desk_ids for r in results)
    report.add(h, passed=passed)
    assert passed, found.output


# Task 7: scroll through a long source window by window.
async def test_scroll_window_by_window(db_pool, corpus, report):
    h = EvalHarness(db_pool, "scroll_window_by_window")
    listed = await h.call(ListDeskHandler(), {"document_id": corpus["docs"]["spec"]["id"]})
    assert listed.output["items"], "task 6 left desk items to scroll"
    unit_id = listed.output["items"][0]["desk_unit_id"]
    body = ""
    offset = 0
    windows = 0
    while True:
        window = await h.call(OpenDeskItemHandler(),
                              {"desk_unit_id": unit_id, "offset": offset, "max_chars": 400})
        assert window.success, window.error
        assert len(window.output["content"]) <= 400
        body += window.output["content"]
        windows += 1
        if not window.output.get("truncated"):
            break
        offset = window.output["next_offset"]
        assert windows < 100, "scroll did not terminate"
    passed = windows >= 2 and len(body) == window.output["total_chars"]
    report.add(h, passed=passed, windows=windows)
    assert passed
    # Leave the desk clean for later tasks.
    await h.call(ClearDeskHandler(), {"document_id": corpus["docs"]["spec"]["id"]})


# Task 8: retrieve a table cell/range from a spreadsheet.
async def test_spreadsheet_cell(db_pool, corpus, report):
    h = EvalHarness(db_pool, "spreadsheet_cell")
    result = await h.call(SearchDocumentChunksHandler(),
                          {"query": "AcmePipeworks", "locator_kind": "sheet_row"})
    assert result.success, result.error
    hit = next((c for c in result.output["chunks"] if "AcmePipeworks" in (c["snippet"] or "")), None)
    passed = hit is not None and hit["sheet_name"] == "Vendors" \
        and hit["document_id"] == corpus["docs"]["xlsx"]["id"]
    report.add(h, passed=passed, sheet=hit["sheet_name"] if hit else None)
    assert passed, result.output


# Task 9: cite a PDF page.
async def test_pdf_page_citation(db_pool, corpus, report):
    h = EvalHarness(db_pool, "pdf_page_citation")
    result = await h.call(SearchDocumentChunksHandler(), {"query": "lattice budget cap"})
    hit = next((c for c in result.output["chunks"]
                if c["document_id"] == corpus["docs"]["pdf"]["id"]), None)
    passed = hit is not None and hit["page_start"] == 3
    report.add(h, passed=passed, page=hit["page_start"] if hit else None)
    assert passed, result.output


# Task 10: detect when a source is missing or extraction failed.
async def test_missing_source_and_failed_extraction(db_pool, corpus, report):
    h = EvalHarness(db_pool, "missing_and_failed")
    missing = await h.call(OpenDocumentChunkHandler(), {"chunk_id": str(uuid.uuid4())})
    guided = (not missing.success) and "search_document_chunks" in (missing.error or "")

    async with db_pool.acquire() as conn:
        failed_run = await conn.fetchrow(
            """
            SELECT r.status, a.source_document_id
            FROM source_extraction_runs r
            JOIN source_artifacts a ON a.id = r.artifact_id
            WHERE r.status = 'failed' AND a.original_filename = 'broken.docx'
            ORDER BY r.created_at DESC LIMIT 1
            """
        )
    preserved = failed_run is not None and failed_run["source_document_id"] is None
    passed = guided and preserved
    report.add(h, passed=passed, guided=guided, artifact_preserved=preserved)
    assert passed


# Task 11: refuse to surface private source material in a group context.
async def test_group_context_privacy(db_pool, corpus, report):
    h = EvalHarness(db_pool, "group_context_privacy", is_group=True)
    solo = EvalHarness(db_pool, "group_context_privacy_solo")

    private_doc = corpus["docs"]["private"]["id"]
    # Visible in 1:1...
    solo_hit = await solo.call(SearchDocumentChunksHandler(), {"query": "whisperfall passphrase"})
    assert any(c["document_id"] == private_doc for c in solo_hit.output["chunks"])

    # ...and fully absent across group-context surfaces.
    search = await h.call(SearchDocumentChunksHandler(), {"query": "whisperfall passphrase"})
    doc_search = await h.call(SearchDocumentsHandler(), {"query": "whisperfall passphrase"})
    load = await h.call(LoadDocumentChunksHandler(),
                        {"document_id": private_doc, "query": "whisperfall"})
    leaked = (
        any(c["document_id"] == private_doc for c in search.output["chunks"])
        or any(str(d["document_id"]) == private_doc for d in doc_search.output["documents"])
        or (load.success and int(load.output.get("count") or 0) > 0)
    )
    passed = not leaked
    report.add(h, passed=passed)
    assert passed
