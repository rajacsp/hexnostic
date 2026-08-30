"""Stub-only memory access for RLM REPL syscalls.

Uses psycopg2 (sync) to match the existing MemoryToolHandler pattern.
All methods are synchronous -- designed to be called from exec() in the REPL.
"""

from __future__ import annotations

import json
import logging
from typing import Any
from uuid import UUID

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    psycopg2 = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)


class MemoryRepo:
    """Sync memory access for RLM environments."""

    def __init__(self, dsn: str):
        self._dsn = dsn
        self._conn = None

    def _get_conn(self):
        if psycopg2 is None:
            raise RuntimeError("psycopg2 is required for MemoryRepo")
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(self._dsn)
            self._conn.autocommit = True
            psycopg2.extras.register_uuid()
        return self._conn

    def search_stubs(
        self,
        query: str,
        *,
        limit: int = 20,
        types: list[str] | None = None,
        min_importance: float = 0.0,
        preview_chars: int = 256,
    ) -> list[dict[str, Any]]:
        """Search memories, return stubs only (no full content)."""
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            type_array = types if types else None
            cur.execute(
                "SELECT * FROM recall_memories_stub(%s, %s, %s, %s, %s)",
                (query, limit, type_array, min_importance, preview_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def fetch_by_ids(
        self, ids: list[str], *, max_chars: int = 2000
    ) -> list[dict[str, Any]]:
        """Fetch full memory content by IDs with truncation."""
        if not ids:
            return []
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT * FROM get_memories_by_ids(%s::uuid[], %s)",
                (ids, max_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def search_documents(
        self,
        query: str,
        *,
        limit: int = 10,
        source_path: str | None = None,
        source_type: str | None = None,
        preview_chars: int = 500,
    ) -> list[dict[str, Any]]:
        """Search preserved source documents, returning stubs only."""
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT document_id, title, source_type, path, file_type,
                       content_hash, word_count, size_bytes, created_at,
                       updated_at, rank, snippet
                FROM search_source_documents(
                    %s, %s, %s, %s, NULL, NULL, false, 0, %s, false
                )
                """,
                (query, limit, source_path, source_type, preview_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def fetch_documents(
        self,
        *,
        document_ids: list[str] | None = None,
        content_hashes: list[str] | None = None,
        paths: list[str] | None = None,
        offset: int = 0,
        max_chars: int | None = None,
        limit: int = 10,
    ) -> dict[str, Any]:
        """Open preserved source documents by id/hash/path."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT open_source_documents(
                    %s::uuid[], %s::text[], %s::text[], %s::int, %s::int, %s::int, false
                )
                """,
                (document_ids or [], content_hashes or [], paths or [], offset, max_chars, limit),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def load_documents_to_desk(
        self,
        *,
        document_ids: list[str] | None = None,
        content_hashes: list[str] | None = None,
        paths: list[str] | None = None,
        offset: int = 0,
        max_chars: int | None = None,
        chunk_chars: int | None = None,
        limit: int = 10,
        reason: str | None = None,
    ) -> dict[str, Any]:
        """Load preserved source documents onto the RecMem desk."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT load_source_documents_to_recmem(
                    %s::uuid[], %s::text[], %s::text[], %s::int,
                    %s::int, %s::int, %s::int, false, %s::text
                )
                """,
                (
                    document_ids or [],
                    content_hashes or [],
                    paths or [],
                    offset,
                    max_chars,
                    chunk_chars,
                    limit,
                    reason,
                ),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def search_document_chunks(
        self,
        query: str | None,
        *,
        limit: int = 10,
        document_id: str | None = None,
        source_path: str | None = None,
        source_type: str | None = None,
        snippet_chars: int = 400,
    ) -> list[dict[str, Any]]:
        """Hybrid passage-level search over durable source chunks (stubs)."""
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT chunk_id, document_id, chunk_index, title, path,
                       source_type, locator_kind, locator, heading_path,
                       page_start, page_end, sheet_name, snippet, content_hash,
                       rank, rank_components
                FROM search_source_chunks(
                    %s, %s, %s::uuid, %s, %s, NULL, NULL, NULL, NULL,
                    NULL, NULL, false, 0, %s
                )
                """,
                (query, limit, document_id, source_path, source_type, snippet_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def fetch_document_chunks(
        self,
        *,
        chunk_ids: list[str] | None = None,
        document_id: str | None = None,
        chunk_start: int | None = None,
        chunk_end: int | None = None,
        page_start: int | None = None,
        page_end: int | None = None,
        limit: int = 10,
    ) -> dict[str, Any]:
        """Open exact chunks with locators and prev/next scroll handles."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT open_source_chunks(
                    %s::uuid[], %s::uuid, %s::int, %s::int, %s::int, %s::int, %s::int, false
                )
                """,
                (chunk_ids or None, document_id, chunk_start, chunk_end,
                 page_start, page_end, limit),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def load_document_chunks_to_desk(
        self,
        *,
        chunk_ids: list[str] | None = None,
        document_id: str | None = None,
        page_start: int | None = None,
        page_end: int | None = None,
        limit: int = 10,
        reason: str | None = None,
        pin: bool = False,
    ) -> dict[str, Any]:
        """Load selected chunks onto the RecMem desk."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT load_source_chunks_to_recmem(
                    %s::uuid[], %s::uuid, NULL, NULL, %s::int, %s::int,
                    %s::int, false, %s, NULL, 'rlm', NULL, %s
                )
                """,
                (chunk_ids or None, document_id, page_start, page_end,
                 limit, reason, bool(pin)),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def list_desk(
        self,
        *,
        limit: int = 20,
        offset: int = 0,
        document_id: str | None = None,
        pinned_only: bool = False,
    ) -> list[dict[str, Any]]:
        """List current RecMem desk items."""
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT * FROM list_recmem_desk(
                    %s::int, %s::int, %s::uuid, %s, NULL, NULL, false
                )
                """,
                (limit, offset, document_id, bool(pinned_only)),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def fetch_desk_item(
        self,
        desk_unit_id: str,
        *,
        offset: int = 0,
        max_chars: int | None = None,
    ) -> dict[str, Any]:
        """Open one desk item with offset windowing (scroll)."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT open_recmem_desk_item(%s::uuid, %s::int, %s::int, false)",
                (desk_unit_id, offset, max_chars),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def pin_desk_item(
        self, desk_unit_id: str, *, pinned: bool = True, note: str | None = None
    ) -> dict[str, Any]:
        """Pin/unpin a desk item."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT pin_recmem_desk_item(%s::uuid, %s, 'rlm', %s)",
                (desk_unit_id, bool(pinned), note),
            )
            result = cur.fetchone()[0]
            return json.loads(result) if isinstance(result, str) else (result or {})

    def recent_stubs(
        self, *, limit: int = 5, preview_chars: int = 256
    ) -> list[dict[str, Any]]:
        """Get recent episodic memory stubs."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT get_recent_context_stub(%s, %s)", (limit, preview_chars)
            )
            result = cur.fetchone()[0]
            if result is None:
                return []
            return json.loads(result) if isinstance(result, str) else result

    def contradictions_stub(
        self, *, limit: int = 5, preview_chars: int = 256
    ) -> list[dict[str, Any]]:
        """Get contradiction pairs as stubs."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT get_contradictions_stub(%s, %s)", (limit, preview_chars)
            )
            result = cur.fetchone()[0]
            if result is None:
                return []
            return json.loads(result) if isinstance(result, str) else result

    def touch(self, ids: list[str | UUID]) -> None:
        """Mark memories as accessed (updates access_count/last_accessed)."""
        if not ids:
            return
        uuid_ids = [item if isinstance(item, UUID) else UUID(str(item)) for item in ids]
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT touch_memories(%s::uuid[])", (uuid_ids,))

    def close(self) -> None:
        if self._conn and not self._conn.closed:
            self._conn.close()
            self._conn = None


def _serialize_row(row: dict) -> dict[str, Any]:
    """Ensure all values are JSON-serializable."""
    out = {}
    for k, v in dict(row).items():
        if hasattr(v, "isoformat"):
            out[k] = v.isoformat()
        elif hasattr(v, "hex"):
            out[k] = str(v)
        else:
            out[k] = v
    return out
