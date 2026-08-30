"""RLM memory syscalls and workspace management.

Provides REPL-callable functions for two-stage memory retrieval
(stub search -> selective fetch) with workspace budgets.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable

from core.memory_repo import MemoryRepo

logger = logging.getLogger(__name__)


@dataclass
class WorkspaceBudgets:
    max_loaded_memories: int = 25
    max_loaded_chars: int = 20_000
    max_notes_chars: int = 8_000
    max_per_memory_chars: int = 2_000


@dataclass
class WorkspaceMetrics:
    search_count: int = 0
    fetch_count: int = 0
    fetched_chars_total: int = 0
    document_search_count: int = 0
    document_fetch_count: int = 0
    document_load_count: int = 0
    document_chunk_search_count: int = 0
    document_chunk_fetch_count: int = 0
    document_chunk_load_count: int = 0
    desk_list_count: int = 0
    desk_fetch_count: int = 0
    desk_pin_count: int = 0
    summarize_events: int = 0


@dataclass
class RLMWorkspace:
    task: str = ""
    turn_snapshot: dict[str, Any] = field(default_factory=dict)
    memory_stubs: list[dict] = field(default_factory=list)
    loaded_memories: list[dict] = field(default_factory=list)
    document_stubs: list[dict] = field(default_factory=list)
    document_chunk_stubs: list[dict] = field(default_factory=list)
    desk_stubs: list[dict] = field(default_factory=list)
    loaded_documents: list[dict] = field(default_factory=list)
    notes: str = ""
    metrics: WorkspaceMetrics = field(default_factory=WorkspaceMetrics)
    budgets: WorkspaceBudgets = field(default_factory=WorkspaceBudgets)


class RLMMemoryEnv:
    """
    Provides REPL-callable syscalls for memory access.

    All functions are synchronous (called from exec() in the REPL sandbox).
    """

    def __init__(
        self,
        repo: MemoryRepo,
        workspace: RLMWorkspace,
        llm_query_fn: Callable[[str], str] | None = None,
    ):
        self._repo = repo
        self._workspace = workspace
        self._llm_query = llm_query_fn

    # ------------------------------------------------------------------
    # Memory search (stubs only)
    # ------------------------------------------------------------------

    def memory_search(
        self,
        query: str,
        *,
        limit: int = 20,
        types: list[str] | None = None,
        min_importance: float = 0.0,
    ) -> list[dict]:
        """Search memories. Returns stubs (id + preview), not full content."""
        stubs = self._repo.search_stubs(
            query,
            limit=limit,
            types=types,
            min_importance=min_importance,
            preview_chars=256,
        )
        self._workspace.memory_stubs = stubs
        self._workspace.metrics.search_count += 1
        logger.debug(
            "memory_search: query=%r returned %d stubs", query[:60], len(stubs)
        )
        return stubs

    # ------------------------------------------------------------------
    # Memory fetch (full content, with budgets)
    # ------------------------------------------------------------------

    def memory_fetch(
        self, ids: list[str], *, max_chars: int | None = None
    ) -> list[dict]:
        """Fetch full memory content. Respects workspace budgets."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_per_memory_chars

        memories = self._repo.fetch_by_ids(ids, max_chars=max_chars)

        self._workspace.loaded_memories.extend(memories)
        self._workspace.metrics.fetch_count += 1
        chars = sum(len(m.get("content", "")) for m in memories)
        self._workspace.metrics.fetched_chars_total += chars

        self._enforce_budgets()
        self._repo.touch(ids)

        logger.debug(
            "memory_fetch: fetched %d memories (%d chars)", len(memories), chars
        )
        return memories

    # ------------------------------------------------------------------
    # Source document search/fetch/load
    # ------------------------------------------------------------------

    def document_search(
        self,
        query: str,
        *,
        limit: int = 10,
        source_path: str | None = None,
        source_type: str | None = None,
    ) -> list[dict]:
        """Search the source-document filing cabinet. Returns stubs."""
        stubs = self._repo.search_documents(
            query,
            limit=limit,
            source_path=source_path,
            source_type=source_type,
        )
        self._workspace.document_stubs = stubs
        self._workspace.metrics.document_search_count += 1
        logger.debug("document_search: query=%r returned %d stubs", query[:60], len(stubs))
        return stubs

    def document_fetch(
        self,
        *,
        document_ids: list[str] | None = None,
        content_hashes: list[str] | None = None,
        paths: list[str] | None = None,
        offset: int = 0,
        max_chars: int | None = None,
        limit: int = 10,
    ) -> dict[str, Any]:
        """Open source documents into the workspace without making memory."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_per_memory_chars
        payload = self._repo.fetch_documents(
            document_ids=document_ids,
            content_hashes=content_hashes,
            paths=paths,
            offset=offset,
            max_chars=max_chars,
            limit=limit,
        )
        documents = payload.get("documents") if isinstance(payload, dict) else []
        if isinstance(documents, list):
            self._workspace.loaded_documents.extend(documents)
            chars = sum(len(d.get("content", "")) for d in documents if isinstance(d, dict))
        else:
            chars = 0
        self._workspace.metrics.document_fetch_count += 1
        self._workspace.metrics.fetched_chars_total += chars
        self._enforce_budgets()
        document_count = len(documents) if isinstance(documents, list) else 0
        logger.debug("document_fetch: fetched %d documents (%d chars)", document_count, chars)
        return payload

    def document_load_to_desk(
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
        """Load source documents onto the RecMem desk for later desk search."""
        payload = self._repo.load_documents_to_desk(
            document_ids=document_ids,
            content_hashes=content_hashes,
            paths=paths,
            offset=offset,
            max_chars=max_chars,
            chunk_chars=chunk_chars,
            limit=limit,
            reason=reason,
        )
        self._workspace.metrics.document_load_count += 1
        return payload

    # ------------------------------------------------------------------
    # Source chunk search/fetch/load (passage grain)
    # ------------------------------------------------------------------

    def document_chunk_search(
        self,
        query: str,
        *,
        limit: int = 10,
        document_id: str | None = None,
        source_path: str | None = None,
        source_type: str | None = None,
    ) -> list[dict]:
        """Passage-level cabinet search: hybrid lexical+vector over durable
        chunks. Returns stubs with citable locators (page/section/sheet)."""
        stubs = self._repo.search_document_chunks(
            query,
            limit=limit,
            document_id=document_id,
            source_path=source_path,
            source_type=source_type,
        )
        self._workspace.document_chunk_stubs = stubs
        self._workspace.metrics.document_chunk_search_count += 1
        logger.debug("document_chunk_search: query=%r returned %d stubs", query[:60], len(stubs))
        return stubs

    def document_chunk_fetch(
        self,
        chunk_ids: list[str] | None = None,
        *,
        document_id: str | None = None,
        chunk_start: int | None = None,
        chunk_end: int | None = None,
        page_start: int | None = None,
        page_end: int | None = None,
        limit: int = 10,
    ) -> dict[str, Any]:
        """Open exact passages (with prev/next handles) into the workspace."""
        payload = self._repo.fetch_document_chunks(
            chunk_ids=chunk_ids,
            document_id=document_id,
            chunk_start=chunk_start,
            chunk_end=chunk_end,
            page_start=page_start,
            page_end=page_end,
            limit=limit,
        )
        chunks = payload.get("chunks") if isinstance(payload, dict) else []
        if isinstance(chunks, list):
            self._workspace.loaded_documents.extend(chunks)
            chars = sum(len(c.get("content", "")) for c in chunks if isinstance(c, dict))
        else:
            chars = 0
        self._workspace.metrics.document_chunk_fetch_count += 1
        self._workspace.metrics.fetched_chars_total += chars
        self._enforce_budgets()
        return payload

    def document_chunk_load_to_desk(
        self,
        chunk_ids: list[str] | None = None,
        *,
        document_id: str | None = None,
        page_start: int | None = None,
        page_end: int | None = None,
        limit: int = 10,
        reason: str | None = None,
        pin: bool = False,
    ) -> dict[str, Any]:
        """Put selected passages on the RecMem desk for later desk search."""
        payload = self._repo.load_document_chunks_to_desk(
            chunk_ids=chunk_ids,
            document_id=document_id,
            page_start=page_start,
            page_end=page_end,
            limit=limit,
            reason=reason,
            pin=pin,
        )
        self._workspace.metrics.document_chunk_load_count += 1
        return payload

    # ------------------------------------------------------------------
    # Desk syscalls
    # ------------------------------------------------------------------

    def desk_list(
        self,
        *,
        limit: int = 20,
        offset: int = 0,
        document_id: str | None = None,
        pinned_only: bool = False,
    ) -> list[dict]:
        """See what is already on the desk before re-loading a source."""
        stubs = self._repo.list_desk(
            limit=limit,
            offset=offset,
            document_id=document_id,
            pinned_only=pinned_only,
        )
        self._workspace.desk_stubs = stubs
        self._workspace.metrics.desk_list_count += 1
        return stubs

    def desk_fetch(
        self,
        desk_unit_id: str,
        *,
        offset: int = 0,
        max_chars: int | None = None,
    ) -> dict[str, Any]:
        """Read (and scroll) one desk item; counts toward workspace budget."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_per_memory_chars
        payload = self._repo.fetch_desk_item(
            desk_unit_id, offset=offset, max_chars=max_chars
        )
        if isinstance(payload, dict) and payload.get("content"):
            self._workspace.loaded_documents.append(payload)
            self._workspace.metrics.fetched_chars_total += len(payload.get("content", ""))
        self._workspace.metrics.desk_fetch_count += 1
        self._enforce_budgets()
        return payload

    def desk_pin(
        self, desk_unit_id: str, *, pinned: bool = True, note: str | None = None
    ) -> dict[str, Any]:
        """Pin (or unpin) a desk item so desk cleanup keeps it."""
        payload = self._repo.pin_desk_item(desk_unit_id, pinned=pinned, note=note)
        self._workspace.metrics.desk_pin_count += 1
        return payload

    # ------------------------------------------------------------------
    # Workspace management
    # ------------------------------------------------------------------

    def workspace_summarize(
        self,
        bucket: str = "loaded_memories",
        *,
        into: str = "notes",
        max_chars: int | None = None,
    ) -> str:
        """Summarize a workspace bucket using sub-LLM call."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_notes_chars

        if bucket == "loaded_memories":
            content = "\n\n".join(
                f"[{m.get('type', '?')}] {m.get('content', '')}"
                for m in self._workspace.loaded_memories
            )
        elif bucket == "loaded_documents":
            content = "\n\n".join(
                f"[source_document] {d.get('title', d.get('path', '?'))}\n{d.get('content', '')}"
                for d in self._workspace.loaded_documents
            )
        elif bucket == "all":
            memory_content = "\n\n".join(
                f"[{m.get('type', '?')}] {m.get('content', '')}"
                for m in self._workspace.loaded_memories
            )
            document_content = "\n\n".join(
                f"[source_document] {d.get('title', d.get('path', '?'))}\n{d.get('content', '')}"
                for d in self._workspace.loaded_documents
            )
            content = "\n\n".join(
                part for part in (memory_content, document_content, self._workspace.notes) if part
            )
        else:
            content = self._workspace.notes

        if not content:
            return ""

        if self._llm_query:
            summary = self._llm_query(
                f"Summarize the following memories concisely. "
                f"Keep key facts, dates, and relationships. "
                f"Max {max_chars} chars.\n\n{content}"
            )
        else:
            # Fallback: simple truncation
            summary = content[:max_chars]

        if into == "notes":
            self._workspace.notes = summary[:max_chars]

        self._workspace.metrics.summarize_events += 1
        return summary[:max_chars]

    def workspace_drop(
        self,
        bucket: str = "loaded_memories",
        *,
        keep_ids: list[str] | None = None,
    ) -> None:
        """Drop workspace bucket contents, optionally keeping specific IDs."""
        if bucket == "loaded_memories":
            if keep_ids:
                keep_set = set(str(i) for i in keep_ids)
                self._workspace.loaded_memories = [
                    m
                    for m in self._workspace.loaded_memories
                    if str(m.get("id")) in keep_set
                ]
            else:
                self._workspace.loaded_memories = []
        elif bucket == "loaded_documents":
            if keep_ids:
                keep_set = set(str(i) for i in keep_ids)
                self._workspace.loaded_documents = [
                    d
                    for d in self._workspace.loaded_documents
                    if str(d.get("document_id")) in keep_set
                ]
            else:
                self._workspace.loaded_documents = []
        elif bucket == "notes":
            self._workspace.notes = ""
        elif bucket == "all":
            self._workspace.loaded_memories = []
            self._workspace.loaded_documents = []
            self._workspace.notes = ""

    def workspace_status(self) -> dict[str, Any]:
        """Return current workspace sizes and budget usage."""
        loaded_chars = sum(
            len(m.get("content", "")) for m in self._workspace.loaded_memories
        )
        loaded_document_chars = sum(
            len(d.get("content", "")) for d in self._workspace.loaded_documents
        )
        return {
            "loaded_memories_count": len(self._workspace.loaded_memories),
            "loaded_memories_chars": loaded_chars,
            "loaded_documents_count": len(self._workspace.loaded_documents),
            "loaded_documents_chars": loaded_document_chars,
            "notes_chars": len(self._workspace.notes),
            "stubs_count": len(self._workspace.memory_stubs),
            "document_stubs_count": len(self._workspace.document_stubs),
            "document_chunk_stubs_count": len(self._workspace.document_chunk_stubs),
            "desk_stubs_count": len(self._workspace.desk_stubs),
            "budgets": {
                "max_loaded_memories": self._workspace.budgets.max_loaded_memories,
                "max_loaded_chars": self._workspace.budgets.max_loaded_chars,
                "max_notes_chars": self._workspace.budgets.max_notes_chars,
            },
            "metrics": {
                "search_count": self._workspace.metrics.search_count,
                "fetch_count": self._workspace.metrics.fetch_count,
                "fetched_chars_total": self._workspace.metrics.fetched_chars_total,
                "document_search_count": self._workspace.metrics.document_search_count,
                "document_fetch_count": self._workspace.metrics.document_fetch_count,
                "document_load_count": self._workspace.metrics.document_load_count,
                "document_chunk_search_count": self._workspace.metrics.document_chunk_search_count,
                "document_chunk_fetch_count": self._workspace.metrics.document_chunk_fetch_count,
                "document_chunk_load_count": self._workspace.metrics.document_chunk_load_count,
                "desk_list_count": self._workspace.metrics.desk_list_count,
                "desk_fetch_count": self._workspace.metrics.desk_fetch_count,
                "desk_pin_count": self._workspace.metrics.desk_pin_count,
                "summarize_events": self._workspace.metrics.summarize_events,
            },
        }

    # ------------------------------------------------------------------
    # Budget enforcement
    # ------------------------------------------------------------------

    def _enforce_budgets(self) -> None:
        """Auto-summarize and drop if budgets exceeded."""
        b = self._workspace.budgets
        loaded = self._workspace.loaded_memories

        # Count-based enforcement
        if len(loaded) > b.max_loaded_memories:
            logger.info(
                "Workspace budget exceeded: %d/%d memories, auto-summarizing",
                len(loaded),
                b.max_loaded_memories,
            )
            self.workspace_summarize("loaded_memories", into="notes")
            excess = len(loaded) - b.max_loaded_memories
            self._workspace.loaded_memories = loaded[excess:]

        # Char-based enforcement
        total_chars = sum(len(m.get("content", "")) for m in self._workspace.loaded_memories)
        total_chars += sum(len(d.get("content", "")) for d in self._workspace.loaded_documents)
        if total_chars > b.max_loaded_chars:
            logger.info(
                "Workspace char budget exceeded: %d/%d chars, auto-summarizing",
                total_chars,
                b.max_loaded_chars,
            )
            memory_summary = self.workspace_summarize("loaded_memories", into="return")
            document_summary = (
                self.workspace_summarize("loaded_documents", into="return")
                if self._workspace.loaded_documents else ""
            )
            self._workspace.notes = "\n\n".join(
                part for part in (memory_summary, document_summary) if part
            )[: b.max_notes_chars]
            while (
                total_chars > b.max_loaded_chars
                and self._workspace.loaded_memories
            ):
                removed = self._workspace.loaded_memories.pop(0)
                total_chars -= len(removed.get("content", ""))
            while (
                total_chars > b.max_loaded_chars
                and self._workspace.loaded_documents
            ):
                removed = self._workspace.loaded_documents.pop(0)
                total_chars -= len(removed.get("content", ""))

    # ------------------------------------------------------------------
    # REPL integration
    # ------------------------------------------------------------------

    def get_repl_functions(self) -> dict[str, Any]:
        """Return dict of functions to inject into REPL namespace."""
        return {
            "memory_search": self.memory_search,
            "memory_fetch": self.memory_fetch,
            "document_search": self.document_search,
            "document_fetch": self.document_fetch,
            "document_load_to_desk": self.document_load_to_desk,
            "document_chunk_search": self.document_chunk_search,
            "document_chunk_fetch": self.document_chunk_fetch,
            "document_chunk_load_to_desk": self.document_chunk_load_to_desk,
            "desk_list": self.desk_list,
            "desk_fetch": self.desk_fetch,
            "desk_pin": self.desk_pin,
            "workspace_summarize": self.workspace_summarize,
            "workspace_drop": self.workspace_drop,
            "workspace_status": self.workspace_status,
        }
