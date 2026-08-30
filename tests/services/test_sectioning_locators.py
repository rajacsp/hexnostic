"""Sectioner v2 invariants: exact-substring chunks, overlap as context (not
content), heading paths, and marker-derived locators."""

from __future__ import annotations

from pathlib import Path

from services.ingest.config import Anchor
from services.ingest.sectioning import (
    CHUNKER_VERSION,
    Sectioner,
    assign_locators,
    derive_anchors_from_markers,
)


def _assert_exact_substrings(content: str, sections) -> None:
    assert sections, "expected at least one section"
    for s in sections:
        assert s.content == content[s.char_start:s.char_end], (
            f"section {s.index} ({s.title!r}) is not an exact substring"
        )


def test_chunker_version_is_v2():
    assert CHUNKER_VERSION == "v2"


def test_text_split_exact_substrings_and_overlap_prefix():
    paras = [f"Paragraph {i} " + "word " * 20 + f"end{i}." for i in range(8)]
    content = "\n\n".join(paras)
    sectioner = Sectioner(max_chars=200, overlap=30)
    sections = sectioner.split(content, Path("doc.txt"))

    assert len(sections) > 1
    _assert_exact_substrings(content, sections)
    assert [s.index for s in sections] == list(range(len(sections)))

    # Overlap rides in context_prefix, never in content.
    assert sections[0].context_prefix == ""
    for prev, cur in zip(sections, sections[1:]):
        assert cur.context_prefix, "later sections carry overlap context"
        assert cur.context_prefix == content[max(prev.char_start, prev.char_end - 30):prev.char_end]
        assert cur.extraction_view().startswith("...")
        assert cur.extraction_view().endswith(cur.content)


def test_small_text_is_single_section():
    content = "Just a short note."
    sections = Sectioner(max_chars=2000, overlap=200).split(content, Path("note.txt"))
    assert len(sections) == 1
    assert sections[0].content == content
    assert sections[0].char_start == 0
    assert sections[0].char_end == len(content)
    assert sections[0].context_prefix == ""


def test_markdown_heading_paths_and_coverage():
    content = (
        "intro before any header\n\n"
        "# Alpha\n\nAlpha body text.\n\n"
        "## Beta\n\nBeta body text.\n\n"
        "# Gamma\n\nGamma body text.\n"
    )
    sections = Sectioner(max_chars=2000, overlap=0).split(content, Path("doc.md"))
    _assert_exact_substrings(content, sections)

    by_title = {s.title: s for s in sections}
    assert by_title["Introduction"].heading_path == []
    assert by_title["Alpha"].heading_path == ["Alpha"]
    assert by_title["Beta"].heading_path == ["Alpha", "Beta"]
    assert by_title["Gamma"].heading_path == ["Gamma"]
    # Header lines stay inside their section so chunks cover the document.
    assert by_title["Alpha"].content.startswith("# Alpha")
    assert all(s.locator_kind == "section" for s in sections)


def test_oversized_markdown_section_subsplits_with_inherited_heading():
    body = " ".join(f"sentence {i} is here." for i in range(120))
    content = f"# Big\n\n{body}\n"
    sections = Sectioner(max_chars=300, overlap=0).split(content, Path("doc.md"))
    _assert_exact_substrings(content, sections)
    assert len(sections) > 1
    assert all(s.heading_path == ["Big"] for s in sections)
    assert any("(part" in s.title for s in sections)


def test_pdf_page_markers_become_page_locators():
    content = (
        "[Page 1]\nFirst page text about apples.\n\n"
        "[Page 2]\nSecond page text about oranges.\n\n"
        "[Page 3]\nThird page text about pears.\n"
    )
    sections = Sectioner(max_chars=2000, overlap=0).split(content, Path("doc.pdf"))
    _assert_exact_substrings(content, sections)
    assert sections[0].locator_kind == "page"
    assert sections[0].page_start == 1
    assert sections[-1].page_end == 3


def test_sheet_delimiter_sets_sheet_name():
    content = (
        "[Sheet: Alpha]\na\tb\tc\n1\t2\t3\n\n"
        "[Sheet: Beta]\nx\ty\tz\n4\t5\t6\n"
    )
    sections = Sectioner(max_chars=2000, overlap=0).split(content, Path("book.xlsx"))
    _assert_exact_substrings(content, sections)
    names = [s.sheet_name for s in sections]
    assert "Alpha" in names and "Beta" in names
    assert all(s.locator_kind == "sheet_row" for s in sections)


def test_message_delimiter_split():
    content = (
        "--- Message 1 ---\nFrom: a@example.com\nHi there.\n\n"
        "--- Message 2 ---\nFrom: b@example.com\nHello back.\n"
    )
    sections = Sectioner(max_chars=2000, overlap=0).split(content, Path("thread.mbox"))
    _assert_exact_substrings(content, sections)
    assert len(sections) == 2
    assert all(s.locator_kind == "message" for s in sections)
    assert sections[0].title == "Message 1"


def test_derive_anchors_from_markers_all_kinds():
    content = (
        "[Page 1] intro [Sheet: Q3] data [Slide 4] deck "
        "--- Message 7 --- mail [Page 2] more"
    )
    anchors = derive_anchors_from_markers(content, None)
    kinds = {(a.kind, a.value) for a in anchors}
    assert ("page", 1) in kinds
    assert ("page", 2) in kinds
    assert ("sheet", "Q3") in kinds
    assert ("slide", 4) in kinds
    assert ("message", 7) in kinds
    offsets = [a.char_offset for a in anchors]
    assert offsets == sorted(offsets)


def test_derive_anchors_respects_file_type_filter():
    content = "[Page 1] text [Sheet: Q3] data"
    anchors = derive_anchors_from_markers(content, ".pdf")
    assert {a.kind for a in anchors} == {"page"}


def test_assign_locators_row_anchors_within_sheet():
    content = "[Sheet: Q3]\nrow data one\nrow data two\n"
    sectioner = Sectioner(max_chars=2000, overlap=0)
    sections = sectioner.split(
        content,
        Path("book.xlsx"),
        anchors=[
            Anchor(kind="sheet", value="Q3", char_offset=0),
            Anchor(kind="row", value=10, char_offset=12),
            Anchor(kind="row", value=11, char_offset=25),
        ],
    )
    assert sections[0].sheet_name == "Q3"
    assert sections[0].row_start == 10
    assert sections[0].row_end == 11


def test_notebook_split_covers_code_and_text():
    content = (
        "Some intro text.\n\n"
        "```python\nprint('hello')\n```\n\n"
        "Closing commentary.\n"
    )
    sections = Sectioner(max_chars=2000, overlap=0).split(content, Path("nb.ipynb"))
    _assert_exact_substrings(content, sections)
    assert any(s.title.startswith("Code Cell") for s in sections)
    assert any(not s.title.startswith("Code") for s in sections)
