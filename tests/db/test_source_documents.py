from __future__ import annotations

import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_DUMMY = "array_fill(0.1, ARRAY[embedding_dimension()])::vector"


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def test_source_document_search_open_and_memory_story(db_pool):
    marker = get_test_identifier("sourcedoc")
    content_hash = f"hash-{marker}"
    content = (
        f"# Raw Source {marker}\n\n"
        f"This preserved artifact contains the nebula-retention clause for {marker}.\n"
        "It should be searchable as a source document and openable verbatim."
    )

    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            stored = _j(await conn.fetchval(
                """
                SELECT upsert_source_document(
                    $1, 'document', $2, $3, '.md', $4, 18,
                    $5::jsonb, $6::jsonb
                )
                """,
                f"Raw Source {marker}",
                content_hash,
                f"/tmp/{marker}.md",
                content,
                json.dumps({"kind": "document", "ref": content_hash, "content_hash": content_hash}),
                json.dumps({"test_marker": marker}),
            ))
            doc_id = stored["document_id"]

            rows = await conn.fetch(
                "SELECT * FROM search_source_documents($1, 5)",
                f"nebula-retention {marker}",
            )
            assert len(rows) == 1
            assert str(rows[0]["document_id"]) == doc_id
            assert "nebula-retention" in rows[0]["snippet"]

            opened = _j(await conn.fetchval(
                "SELECT open_source_document($1::uuid)",
                doc_id,
            ))
            assert opened["content"] == content
            assert opened["truncated"] is False

            mid = await conn.fetchval(
                f"""
                INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution, metadata)
                VALUES ('semantic', $1, {_DUMMY}, 0.6, 0.9, 'active', $2::jsonb, $3::jsonb)
                RETURNING id
                """,
                f"The nebula-retention clause exists for {marker}.",
                json.dumps({
                    "kind": "document",
                    "ref": content_hash,
                    "content_hash": content_hash,
                    "source_document_id": doc_id,
                }),
                json.dumps({"confidence": 0.8}),
            )
            story = _j(await conn.fetchval("SELECT get_memory_story($1::uuid)", mid))
            assert story["source_documents"][0]["document_id"] == doc_id

            batch = _j(await conn.fetchval(
                "SELECT open_source_documents(ARRAY[$1::uuid], NULL::text[], NULL::text[], 0, 20)",
                doc_id,
            ))
            assert batch["count"] == 1
            assert batch["documents"][0]["content"] == content[:20]
            assert batch["documents"][0]["truncated"] is True

            loaded = _j(await conn.fetchval(
                """
                SELECT load_source_documents_to_recmem(
                    ARRAY[$1::uuid], NULL::text[], NULL::text[],
                    0, NULL, 500, 10, false, 'test filing cabinet desk load'
                )
                """,
                doc_id,
            ))
            assert loaded["count"] == 1
            desk_unit_id = loaded["desk_unit_ids"][0]
            assert loaded["loaded_units"][0]["document_id"] == doc_id

            desk_hits = await conn.fetch(
                """
                SELECT source_kind, item_id::text, content
                FROM search_cross_session_history($1, 5, ARRAY['desk']::text[])
                """,
                f"nebula-retention {marker}",
            )
            assert [(row["source_kind"], row["item_id"]) for row in desk_hits] == [
                ("desk", desk_unit_id)
            ]
            assert "nebula-retention" in desk_hits[0]["content"]

            turn_hits = await conn.fetch(
                """
                SELECT source_kind, item_id::text
                FROM search_cross_session_history($1, 5, ARRAY['turn']::text[])
                """,
                f"nebula-retention {marker}",
            )
            assert all(row["item_id"] != desk_unit_id for row in turn_hits)

            await conn.execute("SELECT set_config('memory.recmem_gc_enabled', 'true'::jsonb)")
            await conn.execute("SELECT set_config('memory.recmem_gc_idle_days', '1'::jsonb)")
            await conn.execute(
                """
                UPDATE subconscious_units
                SET created_at = CURRENT_TIMESTAMP - INTERVAL '40 days',
                    updated_at = CURRENT_TIMESTAMP - INTERVAL '40 days',
                    last_accessed = CURRENT_TIMESTAMP - INTERVAL '40 days'
                WHERE id = $1::uuid
                """,
                desk_unit_id,
            )
            gc = _j(await conn.fetchval("SELECT recmem_gc(10)"))
            assert gc["archived_units"] >= 1
            assert await conn.fetchval(
                "SELECT status FROM subconscious_units WHERE id = $1::uuid",
                desk_unit_id,
            ) == "archived"
            assert await conn.fetchval(
                "SELECT status FROM source_documents WHERE id = $1::uuid",
                doc_id,
            ) == "active"
        finally:
            await tr.rollback()


async def test_source_document_upsert_does_not_rehydrate_redacted_rows(db_pool):
    marker = get_test_identifier("sourcedocredact")
    content_hash = f"hash-{marker}"

    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                """
                SELECT upsert_source_document(
                    'Original', 'document', $1, '/tmp/original.txt', '.txt',
                    'original content', 2, '{}'::jsonb, '{}'::jsonb
                )
                """,
                content_hash,
            )
            await conn.execute(
                """
                UPDATE source_documents
                SET status = 'redacted',
                    content = '[redacted]',
                    title = 'Redacted',
                    source_attribution = '{"sensitivity": "private"}'::jsonb,
                    metadata = '{"redacted": true}'::jsonb
                WHERE content_hash = $1
                """,
                content_hash,
            )

            await conn.fetchval(
                """
                SELECT upsert_source_document(
                    'New', 'document', $1, '/tmp/new.txt', '.txt',
                    'new content should not return', 5,
                    '{"kind": "document"}'::jsonb,
                    '{"new": true}'::jsonb
                )
                """,
                content_hash,
            )
            row = await conn.fetchrow(
                "SELECT status, title, path, content, source_attribution, metadata FROM source_documents WHERE content_hash = $1",
                content_hash,
            )
            assert row["status"] == "redacted"
            assert row["title"] == "Redacted"
            assert row["path"] == "/tmp/original.txt"
            assert row["content"] == "[redacted]"
            assert _j(row["source_attribution"]) == {"sensitivity": "private"}
            assert _j(row["metadata"]) == {"redacted": True}
        finally:
            await tr.rollback()
