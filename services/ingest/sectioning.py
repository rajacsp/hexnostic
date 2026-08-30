"""Hexis ingestion — split from the former services/ingest.py (#89).
Module: sectioning.

v2 sectioner: every Section is an exact substring of the document
(``content == doc[char_start:char_end]``) so chunks are durable and citable.
Overlap context for the extraction LLM rides in ``Section.context_prefix``
and never mutates content. Locators (page/sheet/row/slide/message) come from
reader-provided anchors, or are re-derived from inline markers ("[Page N]",
"[Sheet: X]", ...) for stored content during backfill.
"""

from __future__ import annotations

import re
from pathlib import Path

from .config import Anchor, Section

# Bump when splitting/locator behavior changes; stored on every chunk row so
# backfill can find documents chunked by an older sectioner.
CHUNKER_VERSION = "v2"

_HEADER_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
_PAGE_MARKER_RE = re.compile(r"\[Page (\d+)\]")
_SHEET_MARKER_RE = re.compile(r"\[Sheet: ([^\]]+)\]")
_SLIDE_MARKER_RE = re.compile(r"\[Slide (\d+)\]")
_MESSAGE_MARKER_RE = re.compile(r"--- Message (\d+) ---")
_PARA_BREAK_RE = re.compile(r"\n{2,}")
_SENTENCE_BREAK_RE = re.compile(r"(?<=[.!?])\s+")
_FENCE_RE = re.compile(r"```\w*\n.*?```", re.DOTALL)

_MARKER_KINDS: list[tuple[str, re.Pattern[str]]] = [
    ("page", _PAGE_MARKER_RE),
    ("sheet", _SHEET_MARKER_RE),
    ("slide", _SLIDE_MARKER_RE),
    ("message", _MESSAGE_MARKER_RE),
]

_SUFFIX_MARKER_KINDS: dict[str, set[str]] = {
    ".pdf": {"page"},
    ".xlsx": {"sheet"},
    ".xls": {"sheet"},
    ".pptx": {"slide"},
    ".eml": {"message"},
    ".mbox": {"message"},
}


def derive_anchors_from_markers(content: str, file_type: str | None = None) -> list[Anchor]:
    """Re-derive structural anchors from inline markers in extracted text.

    Readers emit "[Page N]" / "[Sheet: X]" / "[Slide N]" / "--- Message N ---"
    markers into the normalized text; this parses them back into anchors so
    stored documents (backfill) get the same locators as fresh ingestion.
    """
    wanted = _SUFFIX_MARKER_KINDS.get((file_type or "").lower())
    anchors: list[Anchor] = []
    for kind, pattern in _MARKER_KINDS:
        if wanted is not None and kind not in wanted:
            continue
        for m in pattern.finditer(content):
            value: object = m.group(1)
            if kind in ("page", "slide", "message"):
                value = int(m.group(1))
            else:
                value = m.group(1).strip()
            anchors.append(Anchor(kind=kind, value=value, char_offset=m.start()))
    anchors.sort(key=lambda a: a.char_offset)
    return anchors


def assign_locators(sections: list[Section], anchors: list[Anchor]) -> list[Section]:
    """Map anchors onto section spans: page ranges, sheet names, row ranges.

    Explicit locator kinds set by the splitter win; anchors only upgrade a
    plain 'char' section (e.g. PDF text split as paragraphs gains pages).
    """
    if not anchors:
        return sections
    by_kind: dict[str, list[Anchor]] = {}
    for a in sorted(anchors, key=lambda a: a.char_offset):
        by_kind.setdefault(a.kind, []).append(a)

    def _at_or_before(items: list[Anchor], offset: int) -> Anchor | None:
        found = None
        for a in items:
            if a.char_offset <= offset:
                found = a
            else:
                break
        return found

    def _within(items: list[Anchor], start: int, end: int) -> list[Anchor]:
        return [a for a in items if start <= a.char_offset < end]

    pages = by_kind.get("page", [])
    sheets = by_kind.get("sheet", [])
    rows = by_kind.get("row", [])
    headings = by_kind.get("heading", [])
    for s in sections:
        if headings and not s.heading_path:
            heading_anchor = _at_or_before(headings, s.char_start)
            if heading_anchor is None:
                inside = _within(headings, s.char_start, s.char_end)
                heading_anchor = inside[0] if inside else None
            if heading_anchor is not None and isinstance(heading_anchor.value, (list, tuple)):
                s.heading_path = [str(h) for h in heading_anchor.value]
                if s.locator_kind == "char":
                    s.locator_kind = "section"
        if pages:
            start_anchor = _at_or_before(pages, s.char_start)
            inside = _within(pages, s.char_start, s.char_end)
            end_anchor = inside[-1] if inside else start_anchor
            if start_anchor is None and inside:
                start_anchor = inside[0]
            if start_anchor is not None:
                s.page_start = int(start_anchor.value)
                s.page_end = int(end_anchor.value) if end_anchor else s.page_start
                if s.locator_kind == "char":
                    s.locator_kind = "page"
        if sheets:
            sheet_anchor = _at_or_before(sheets, s.char_start)
            inside = _within(sheets, s.char_start, s.char_end)
            if sheet_anchor is None and inside:
                sheet_anchor = inside[0]
            if sheet_anchor is not None and s.sheet_name is None:
                s.sheet_name = str(sheet_anchor.value)
                if s.locator_kind == "char":
                    s.locator_kind = "sheet_row"
        if rows and s.sheet_name is not None:
            inside = _within(rows, s.char_start, s.char_end)
            if inside:
                values = [int(a.value) for a in inside]
                s.row_start = min(values)
                s.row_end = max(values)
    return sections


class Sectioner:
    def __init__(self, max_chars: int = 2000, overlap: int = 200):
        self.max_chars = max_chars
        self.overlap = overlap

    def split(
        self,
        content: str,
        file_path: Path,
        anchors: list[Anchor] | None = None,
    ) -> list[Section]:
        suffix = file_path.suffix.lower()
        if suffix in (".md", ".markdown"):
            sections = self._split_markdown(content)
        elif suffix == ".pdf":
            # Page-aware chunks: each page is its own section (oversized
            # pages sub-split), so page citations stay precise.
            sections = self._split_on_delimiter(content, _PAGE_MARKER_RE, locator_kind="page")
        elif suffix == ".pptx":
            sections = self._split_on_delimiter(content, _SLIDE_MARKER_RE, locator_kind="slide")
        elif suffix in {".xlsx", ".xls"}:
            sections = self._split_on_delimiter(content, _SHEET_MARKER_RE, locator_kind="sheet_row")
        elif suffix == ".ipynb":
            sections = self._split_notebook(content)
        elif suffix in {".eml", ".mbox"}:
            sections = self._split_on_delimiter(content, _MESSAGE_MARKER_RE, locator_kind="message")
        else:
            sections = self._split_text(content)

        if anchors is None:
            anchors = derive_anchors_from_markers(content, suffix)
        assign_locators(sections, anchors)
        self._apply_overlap(content, sections)
        for i, section in enumerate(sections):
            section.index = i
        return sections

    # ------------------------------------------------------------------
    # span helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _trim_span(content: str, start: int, end: int) -> tuple[int, int]:
        while start < end and content[start].isspace():
            start += 1
        while end > start and content[end - 1].isspace():
            end -= 1
        return start, end

    def _make_section(
        self,
        content: str,
        start: int,
        end: int,
        title: str,
        *,
        locator_kind: str = "char",
        heading_path: list[str] | None = None,
        sheet_name: str | None = None,
    ) -> Section | None:
        start, end = self._trim_span(content, start, end)
        if start >= end:
            return None
        return Section(
            title=title,
            content=content[start:end],
            index=0,
            char_start=start,
            char_end=end,
            locator_kind=locator_kind,
            heading_path=list(heading_path or []),
            sheet_name=sheet_name,
        )

    def _apply_overlap(self, content: str, sections: list[Section]) -> None:
        if self.overlap <= 0:
            return
        for i in range(1, len(sections)):
            prev = sections[i - 1]
            tail_start = max(prev.char_start, prev.char_end - self.overlap)
            sections[i].context_prefix = content[tail_start:prev.char_end]

    def _maybe_subsplit(self, content: str, section: Section) -> list[Section]:
        """Split an oversized section into max_chars parts, inheriting its
        title, heading path, and locator kind."""
        if len(section.content) <= self.max_chars:
            return [section]
        spans = self._pack_text_spans(content, section.char_start, section.char_end)
        parts: list[Section] = []
        for k, (s, e) in enumerate(spans):
            part = self._make_section(
                content, s, e,
                f"{section.title} (part {k + 1})" if len(spans) > 1 else section.title,
                locator_kind=section.locator_kind,
                heading_path=section.heading_path,
                sheet_name=section.sheet_name,
            )
            if part is not None:
                parts.append(part)
        return parts or [section]

    # ------------------------------------------------------------------
    # splitters
    # ------------------------------------------------------------------

    def _split_markdown(self, content: str) -> list[Section]:
        matches = list(_HEADER_RE.finditer(content))
        if not matches:
            return self._split_text(content)

        sections: list[Section] = []
        lead = self._make_section(content, 0, matches[0].start(), "Introduction", locator_kind="section")
        if lead is not None:
            sections.extend(self._maybe_subsplit(content, lead))

        heading_stack: list[tuple[int, str]] = []
        for i, m in enumerate(matches):
            level = len(m.group(1))
            title = m.group(2).strip() or "Untitled"
            heading_stack = [h for h in heading_stack if h[0] < level]
            heading_stack.append((level, title))
            end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
            section = self._make_section(
                content, m.start(), end, title,
                locator_kind="section",
                heading_path=[t for _, t in heading_stack],
            )
            if section is not None:
                sections.extend(self._maybe_subsplit(content, section))
        if not sections:
            fallback = self._make_section(content, 0, len(content), "Document", locator_kind="section")
            return [fallback] if fallback else []
        return sections

    def _split_text(self, content: str) -> list[Section]:
        trimmed = self._make_section(content, 0, len(content), "Section 1")
        if trimmed is None:
            return []
        if len(trimmed.content) <= self.max_chars:
            return [trimmed]
        spans = self._pack_text_spans(content, trimmed.char_start, trimmed.char_end)
        sections: list[Section] = []
        for i, (s, e) in enumerate(spans):
            section = self._make_section(content, s, e, f"Section {i + 1}")
            if section is not None:
                sections.append(section)
        return sections

    def _pack_text_spans(self, content: str, start: int, end: int) -> list[tuple[int, int]]:
        """Pack paragraph spans into ~max_chars chunks; oversized paragraphs
        fall back to sentence packing, pathological sentences hard-slice."""
        window = content[start:end]
        para_spans: list[tuple[int, int]] = []
        pos = 0
        for m in _PARA_BREAK_RE.finditer(window):
            if m.start() > pos:
                para_spans.append((start + pos, start + m.start()))
            pos = m.end()
        if pos < len(window):
            para_spans.append((start + pos, start + len(window)))

        chunks: list[tuple[int, int]] = []
        cur: tuple[int, int] | None = None
        for ps, pe in para_spans:
            if pe - ps > self.max_chars:
                if cur is not None:
                    chunks.append(cur)
                    cur = None
                chunks.extend(self._pack_sentence_spans(content, ps, pe))
                continue
            if cur is None:
                cur = (ps, pe)
            elif pe - cur[0] <= self.max_chars:
                cur = (cur[0], pe)
            else:
                chunks.append(cur)
                cur = (ps, pe)
        if cur is not None:
            chunks.append(cur)
        return chunks

    def _pack_sentence_spans(self, content: str, start: int, end: int) -> list[tuple[int, int]]:
        window = content[start:end]
        sentence_spans: list[tuple[int, int]] = []
        pos = 0
        for m in _SENTENCE_BREAK_RE.finditer(window):
            if m.start() > pos:
                sentence_spans.append((start + pos, start + m.start()))
            pos = m.end()
        if pos < len(window):
            sentence_spans.append((start + pos, start + len(window)))

        chunks: list[tuple[int, int]] = []
        cur: tuple[int, int] | None = None
        for ss, se in sentence_spans:
            if se - ss > self.max_chars:
                if cur is not None:
                    chunks.append(cur)
                    cur = None
                # Pathological single sentence: hard-slice.
                sliced = ss
                while sliced < se:
                    chunks.append((sliced, min(sliced + self.max_chars, se)))
                    sliced += self.max_chars
                continue
            if cur is None:
                cur = (ss, se)
            elif se - cur[0] <= self.max_chars:
                cur = (cur[0], se)
            else:
                chunks.append(cur)
                cur = (ss, se)
        if cur is not None:
            chunks.append(cur)
        return chunks

    def _split_on_delimiter(
        self,
        content: str,
        pattern: re.Pattern[str],
        *,
        locator_kind: str,
    ) -> list[Section]:
        """Split on a structural delimiter ("[Slide N]", "[Sheet: X]",
        "--- Message N ---"), keeping the delimiter inside its section so
        chunks cover the full document text."""
        matches = list(pattern.finditer(content))
        if not matches:
            section = self._make_section(content, 0, len(content), "Document", locator_kind=locator_kind)
            return self._maybe_subsplit(content, section) if section else []

        sections: list[Section] = []
        header = self._make_section(content, 0, matches[0].start(), "Header", locator_kind=locator_kind)
        if header is not None:
            sections.extend(self._maybe_subsplit(content, header))

        for i, m in enumerate(matches):
            title = m.group(0).strip().strip("[]").strip("-").strip()
            sheet_name = m.group(1).strip() if locator_kind == "sheet_row" else None
            end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
            section = self._make_section(
                content, m.start(), end, title,
                locator_kind=locator_kind,
                sheet_name=sheet_name,
            )
            if section is not None:
                sections.extend(self._maybe_subsplit(content, section))
        return sections

    def _split_notebook(self, content: str) -> list[Section]:
        """Split notebook content on cell boundaries (fenced code blocks and
        the text between them)."""
        sections: list[Section] = []
        pos = 0
        for m in _FENCE_RE.finditer(content):
            text_section = self._make_section(content, pos, m.start(), f"Cell {len(sections) + 1}")
            if text_section is not None:
                sections.extend(self._maybe_subsplit(content, text_section))
            code_section = self._make_section(content, m.start(), m.end(), f"Code Cell {len(sections) + 1}")
            if code_section is not None:
                sections.append(code_section)
            pos = m.end()
        tail = self._make_section(content, pos, len(content), f"Cell {len(sections) + 1}")
        if tail is not None:
            sections.extend(self._maybe_subsplit(content, tail))
        if not sections:
            fallback = self._make_section(content, 0, len(content), "Notebook")
            return [fallback] if fallback else []
        return sections
