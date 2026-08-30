"""Deterministic fixture-corpus generator.

Everything is synthetic and self-authored (license-safe) and generated into a
temp directory at eval-session start, so no binary fixtures live in git.
Planted "gold" phrases are unique tokens the tasks assert on.
"""

from __future__ import annotations

from pathlib import Path

# Gold facts planted across the corpus. Tasks assert these exact strings and
# their locators come back from retrieval.
GOLD = {
    "exact_phrase": "The verdigris retention window is exactly 90 days.",
    "distant_a": "The northwind escalation threshold is 12 incidents.",
    "distant_b": "The northwind archive cadence is quarterly.",
    "doc_b_fact": "The saffron backup policy requires two offsite copies.",
    "pdf_fact": "The lattice budget cap is 40000 dollars.",
    "sheet_vendor": "AcmePipeworks",
    "email_fact": "The meridian contract renews on March 3.",
    "web_fact": "The orchard sync protocol uses port 7443.",
    "private_fact": "The whisperfall passphrase rotation happens weekly.",
}

_FILLER_SENTENCES = [
    "This section describes routine operational context in neutral terms.",
    "Nothing in this paragraph changes the obligations set out elsewhere.",
    "Readers should consult the glossary for term definitions.",
    "The working group reviewed this material during the annual cycle.",
    "Additional background is provided for completeness only.",
]


def _filler(paragraphs: int, seed: int) -> str:
    out = []
    for i in range(paragraphs):
        sentence = _FILLER_SENTENCES[(seed + i) % len(_FILLER_SENTENCES)]
        out.append(f"{sentence} (block {seed}.{i}) " + "Context detail follows. " * 6)
    return "\n\n".join(out)


def _minimal_pdf(lines: list[str]) -> bytes:
    """A tiny valid multi-page PDF, one text line per page (no deps)."""
    header = b"%PDF-1.4\n"
    objects: list[bytes] = []
    page_count = len(lines)
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(page_count))
    objects.append(b"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n")
    objects.append(
        f"2 0 obj<</Type/Pages/Kids[{kids}]/Count {page_count}>>endobj\n".encode()
    )
    font_obj = 3 + 2 * page_count
    for i, line in enumerate(lines):
        page_no = 3 + 2 * i
        content_no = page_no + 1
        safe = line.replace("(", "[").replace(")", "]")
        stream = f"BT /F1 12 Tf 72 720 Td ({safe}) Tj ET\n".encode()
        objects.append(
            f"{page_no} 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]"
            f"/Contents {content_no} 0 R/Resources<</Font<</F1 {font_obj} 0 R>>>>>>endobj\n".encode()
        )
        objects.append(
            f"{content_no} 0 obj<</Length {len(stream)}>>stream\n".encode()
            + stream
            + b"endstream endobj\n"
        )
    objects.append(
        f"{font_obj} 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n".encode()
    )
    return header + b"".join(objects) + b"trailer<</Root 1 0 R>>\n%%EOF\n"


def build_corpus(target: Path) -> dict[str, Path]:
    """Write the fixture corpus into `target`; returns name -> path."""
    target.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}

    # 1. A long markdown specification with distant gold sections.
    spec = [
        "# Northwind Operations Specification",
        "",
        "## Introduction",
        "",
        _filler(3, 1),
        "",
        "## Retention",
        "",
        f"{GOLD['exact_phrase']}\n\n{_filler(2, 2)}",
        "",
        "## Escalation",
        "",
        f"{GOLD['distant_a']}\n\n{_filler(8, 3)}",
        "",
        "## Midsection",
        "",
        _filler(12, 4),
        "",
        "## Archival",
        "",
        f"{GOLD['distant_b']}\n\n{_filler(2, 5)}",
    ]
    paths["spec"] = target / "northwind_spec.md"
    paths["spec"].write_text("\n".join(spec), encoding="utf-8")

    # 2. A second document for cross-document comparison.
    paths["doc_b"] = target / "saffron_policy.md"
    paths["doc_b"].write_text(
        f"# Saffron Backup Policy\n\n## Policy\n\n{GOLD['doc_b_fact']}\n\n{_filler(4, 6)}",
        encoding="utf-8",
    )

    # 3. A multi-page PDF with a gold fact on page 3.
    paths["pdf"] = target / "lattice_budget.pdf"
    paths["pdf"].write_bytes(_minimal_pdf([
        "Lattice program overview for the fiscal year.",
        "Governance and reporting cadence details.",
        GOLD["pdf_fact"],
        "Appendix with contact information.",
    ]))

    # 4. An XLSX workbook with two sheets; the gold vendor is over budget.
    import openpyxl

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Vendors"
    ws.append(["vendor", "budget", "spend"])
    ws.append(["BrightForge", 1000, 800])
    ws.append([GOLD["sheet_vendor"], 1000, 1500])
    ws.append(["CedarLoom", 2000, 900])
    ws2 = wb.create_sheet("Notes")
    ws2.append(["note"])
    ws2.append(["Vendor spend reviewed monthly."])
    paths["xlsx"] = target / "vendor_budgets.xlsx"
    wb.save(paths["xlsx"])

    # 5. An email thread (mbox with two messages).
    mbox_text = (
        "From alice@example.com Mon Mar  1 10:00:00 2026\n"
        "From: alice@example.com\nTo: bob@example.com\n"
        "Subject: Meridian contract\nDate: Mon, 1 Mar 2026 10:00:00 -0000\n\n"
        f"Bob — heads up: {GOLD['email_fact']}\n\n"
        "From bob@example.com Mon Mar  1 11:00:00 2026\n"
        "From: bob@example.com\nTo: alice@example.com\n"
        "Subject: Re: Meridian contract\nDate: Mon, 1 Mar 2026 11:00:00 -0000\n\n"
        "Thanks, noted. I'll prepare the renewal paperwork.\n"
    )
    paths["mbox"] = target / "meridian_thread.mbox"
    paths["mbox"].write_text(mbox_text, encoding="utf-8")

    # 6. A web-page snapshot (ingested as markdown-ish text fixture).
    paths["web"] = target / "orchard_sync.md"
    paths["web"].write_text(
        "[Source: https://example.com/orchard]\n[Title: Orchard Sync Protocol]\n\n"
        f"# Orchard Sync Protocol\n\n{GOLD['web_fact']}\n\n{_filler(3, 7)}",
        encoding="utf-8",
    )

    # 7. Duplicate + near-duplicate pair.
    dupes = target / "dupes"
    dupes.mkdir(exist_ok=True)
    base = f"# Cedar Notes\n\nThe cedar workshop happens on Fridays.\n\n{_filler(2, 8)}"
    (dupes / "cedar_a.md").write_text(base, encoding="utf-8")
    (dupes / "cedar_b.md").write_text(base + "\n\nMinor trailing note.", encoding="utf-8")
    paths["dupes"] = dupes

    # 8. A private document for the group-privacy task.
    paths["private"] = target / "whisperfall_private.md"
    paths["private"].write_text(
        f"# Whisperfall Runbook\n\n{GOLD['private_fact']}\n\n{_filler(2, 9)}",
        encoding="utf-8",
    )

    # 9. A corrupt DOCX: extraction must fail loud but preserve the artifact.
    paths["corrupt"] = target / "broken.docx"
    paths["corrupt"].write_bytes(b"this is not a zip archive at all")

    return paths
