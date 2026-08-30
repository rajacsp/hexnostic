"""Desk + chunk tool round-trips through the handlers: search chunks, open
with citation, load to desk, list, scroll, pin, clear — plus group-context
sensitivity gating."""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolContext, ToolExecutionContext
from core.tools.desk import (
    ClearDeskHandler,
    ListDeskHandler,
    OpenDeskItemHandler,
    PinDeskItemHandler,
    UnpinDeskItemHandler,
    create_desk_tools,
)
from core.tools.memory import (
    LoadDocumentChunksHandler,
    OpenDocumentChunkHandler,
    SearchDocumentChunksHandler,
    create_memory_tools,
)
from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _ctx(db_pool, *, is_group: bool = False) -> ToolExecutionContext:
    registry = MagicMock()
    registry.pool = db_pool
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
        is_group=is_group,
    )


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed_doc_with_chunks(db_pool, marker: str, chunks: list[str],
                                 sensitivity: str | None = None) -> tuple[str, list[str]]:
    attribution = {"kind": "document", "ref": f"hash-{marker}"}
    if sensitivity:
        attribution["sensitivity"] = sensitivity
    async with db_pool.acquire() as conn:
        stored = _j(await conn.fetchval(
            """
            SELECT upsert_source_document(
                $1, 'document', $2, $3, '.md', $4, 30, $5::jsonb, '{}'::jsonb
            )
            """,
            f"Desk Doc {marker}",
            f"hash-{marker}",
            f"/tmp/{marker}.md",
            "\n\n".join(chunks),
            json.dumps(attribution),
        ))
        doc_id = stored["document_id"]
        result = _j(await conn.fetchval(
            "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
            doc_id,
            json.dumps([
                {"chunk_index": i, "locator_kind": "page", "locator": {"kind": "page"},
                 "heading_path": [], "content": c, "char_start": 0, "char_end": len(c),
                 "page_start": i + 1, "page_end": i + 1}
                for i, c in enumerate(chunks)
            ]),
        ))
    return doc_id, [str(c) for c in result["chunk_ids"]]


async def _cleanup(db_pool, marker: str) -> None:
    async with db_pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM subconscious_units WHERE source_attribution->>'ref' = $1",
            f"hash-{marker}",
        )
        await conn.execute(
            "DELETE FROM source_documents WHERE content_hash = $1", f"hash-{marker}"
        )


class TestChunkTools:
    async def test_search_open_and_citation(self, db_pool):
        marker = get_test_identifier("chunktools")
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(db_pool, marker, [
                f"first passage about migrations {marker}",
                f"the pindrop clause appears here {marker}",
            ])

            search = await SearchDocumentChunksHandler().execute(
                {"query": f"pindrop {marker}"}, _ctx(db_pool)
            )
            assert search.success, search.error
            hits = search.output["chunks"]
            assert any(h["chunk_id"] == chunk_ids[1] for h in hits)
            hit = next(h for h in hits if h["chunk_id"] == chunk_ids[1])
            assert hit["rank_components"]["weights"]["vector"] == pytest.approx(0.6)
            assert hit["page_start"] == 2

            opened = await OpenDocumentChunkHandler().execute(
                {"chunk_id": chunk_ids[1]}, _ctx(db_pool)
            )
            assert opened.success, opened.error
            chunk = opened.output["chunks"][0]
            assert chunk["content"] == f"the pindrop clause appears here {marker}"
            assert chunk["prev_chunk_id"] == chunk_ids[0]
            assert "page 2" in chunk["citation"]

            paged = await OpenDocumentChunkHandler().execute(
                {"document_id": doc_id, "page_start": 1, "page_end": 1}, _ctx(db_pool)
            )
            assert paged.success, paged.error
            assert [c["chunk_id"] for c in paged.output["chunks"]] == [chunk_ids[0]]
        finally:
            await _cleanup(db_pool, marker)

    async def test_chunk_tools_registered(self):
        names = {handler.spec.name for handler in create_memory_tools()}
        assert {"search_document_chunks", "open_document_chunk", "load_document_chunks"} <= names
        desk_names = {handler.spec.name for handler in create_desk_tools()}
        assert desk_names == {"list_desk", "open_desk_item", "pin_desk_item",
                              "unpin_desk_item", "clear_desk"}


class TestDeskRoundTrip:
    async def test_load_list_open_pin_clear(self, db_pool):
        marker = get_test_identifier("deskround")
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(db_pool, marker, [
                f"desk passage one {marker}",
                f"desk passage two {marker}",
            ])

            loaded = await LoadDocumentChunksHandler().execute(
                {"chunk_ids": chunk_ids, "reason": "round-trip test"}, _ctx(db_pool)
            )
            assert loaded.success, loaded.error
            desk_ids = [str(u) for u in loaded.output["desk_unit_ids"]]
            assert len(desk_ids) == 2

            listed = await ListDeskHandler().execute({"document_id": doc_id}, _ctx(db_pool))
            assert listed.success, listed.error
            assert {i["desk_unit_id"] for i in listed.output["items"]} == set(desk_ids)
            assert all(i["reason"] == "round-trip test" for i in listed.output["items"])

            # Scroll: small window walks the content via next_offset.
            first = await OpenDeskItemHandler().execute(
                {"desk_unit_id": desk_ids[0], "max_chars": 200}, _ctx(db_pool)
            )
            assert first.success, first.error
            body = first.output["content"]
            offset = first.output.get("next_offset")
            while offset is not None:
                nxt = await OpenDeskItemHandler().execute(
                    {"desk_unit_id": desk_ids[0], "offset": offset, "max_chars": 200},
                    _ctx(db_pool),
                )
                assert nxt.success, nxt.error
                assert nxt.output["offset"] == offset
                body += nxt.output["content"]
                offset = nxt.output.get("next_offset")
            assert f"desk passage one {marker}" in body
            # Desk items of the same document link to each other for walking.
            assert first.output.get("next_desk_unit_id") == desk_ids[1]

            pinned = await PinDeskItemHandler().execute(
                {"desk_unit_id": desk_ids[0], "note": "keep for the test"}, _ctx(db_pool)
            )
            assert pinned.success and pinned.output["pinned"] is True

            cleared = await ClearDeskHandler().execute(
                {"document_id": doc_id}, _ctx(db_pool)
            )
            assert cleared.success, cleared.error
            assert cleared.output["cleared"] == 1
            assert cleared.output["kept_pinned"] == 1

            still = await ListDeskHandler().execute({"document_id": doc_id}, _ctx(db_pool))
            assert [i["desk_unit_id"] for i in still.output["items"]] == [desk_ids[0]]
            assert still.output["items"][0]["pinned"] is True

            unpinned = await UnpinDeskItemHandler().execute(
                {"desk_unit_id": desk_ids[0]}, _ctx(db_pool)
            )
            assert unpinned.success and unpinned.output["pinned"] is False

            cleared_all = await ClearDeskHandler().execute(
                {"document_id": doc_id}, _ctx(db_pool)
            )
            assert cleared_all.output["cleared"] == 1
            empty = await ListDeskHandler().execute({"document_id": doc_id}, _ctx(db_pool))
            assert empty.output["items"] == []
        finally:
            await _cleanup(db_pool, marker)

    async def test_clear_requires_selector(self, db_pool):
        result = await ClearDeskHandler().execute({}, _ctx(db_pool))
        assert not result.success
        assert "all=true" in (result.error or "")

    async def test_load_by_document_query(self, db_pool):
        marker = get_test_identifier("deskquery")
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(db_pool, marker, [
                f"nothing interesting here {marker}",
                f"the sprocketvane budget threshold {marker}",
            ])
            loaded = await LoadDocumentChunksHandler().execute(
                {"document_id": doc_id, "query": f"sprocketvane {marker}", "limit": 1,
                 "reason": "query load", "pin": True},
                _ctx(db_pool),
            )
            assert loaded.success, loaded.error
            items = loaded.output["loaded_units"]
            assert len(items) == 1
            assert items[0]["chunk_id"] == chunk_ids[1]
            assert items[0]["pinned"] is True
        finally:
            await _cleanup(db_pool, marker)


class TestGroupSensitivity:
    async def test_group_context_excludes_private_sources(self, db_pool):
        marker = get_test_identifier("deskgroup")
        try:
            doc_id, chunk_ids = await _seed_doc_with_chunks(
                db_pool, marker, [f"private glimmerfact {marker}"], sensitivity="private"
            )

            # Private in 1:1: visible.
            solo = await SearchDocumentChunksHandler().execute(
                {"query": f"glimmerfact {marker}"}, _ctx(db_pool)
            )
            assert any(h["chunk_id"] == chunk_ids[0] for h in solo.output["chunks"])

            # Group turn: search, open, load, and desk list all exclude it.
            group_ctx = _ctx(db_pool, is_group=True)
            search = await SearchDocumentChunksHandler().execute(
                {"query": f"glimmerfact {marker}"}, group_ctx
            )
            assert search.output["chunks"] == []

            opened = await OpenDocumentChunkHandler().execute(
                {"chunk_id": chunk_ids[0]}, group_ctx
            )
            assert not opened.success

            loaded = await LoadDocumentChunksHandler().execute(
                {"chunk_ids": chunk_ids}, group_ctx
            )
            assert (not loaded.success) or int(loaded.output.get("count") or 0) == 0

            # Load privately, then confirm the desk hides it in group turns.
            solo_load = await LoadDocumentChunksHandler().execute(
                {"chunk_ids": chunk_ids}, _ctx(db_pool)
            )
            assert solo_load.success and solo_load.output["count"] == 1
            group_list = await ListDeskHandler().execute({"document_id": doc_id}, group_ctx)
            assert group_list.output["items"] == []
            solo_list = await ListDeskHandler().execute({"document_id": doc_id}, _ctx(db_pool))
            assert len(solo_list.output["items"]) == 1
        finally:
            await _cleanup(db_pool, marker)
