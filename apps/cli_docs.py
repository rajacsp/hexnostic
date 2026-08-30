"""`hexis docs` and `hexis desk` — the filing cabinet and RecMem desk from
the terminal.

Every command completes in place or hands back the exact next step (no dead
ends): search results carry open/load hints, truncated opens carry the next
offset, and clear reports what was kept and why.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


def _j(value: Any) -> Any:
    return json.loads(value) if isinstance(value, str) else value


def _parse_pages(raw: str | None) -> tuple[int | None, int | None]:
    """'4' -> (4, 4); '4-7' -> (4, 7)."""
    if not raw:
        return None, None
    m = re.fullmatch(r"(\d+)(?:-(\d+))?", raw.strip())
    if not m:
        raise ValueError("--page expects N or N-M (e.g. --page 4 or --page 4-7)")
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else start
    return start, end


def _selector_kwargs(ref: str) -> dict[str, list[str]]:
    """A ref can be a document UUID, a content hash, or a (partial) path."""
    ref = ref.strip()
    if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", ref):
        return {"document_ids": [ref], "content_hashes": [], "paths": []}
    if re.fullmatch(r"[0-9a-fA-F]{40,64}", ref):
        return {"document_ids": [], "content_hashes": [ref], "paths": []}
    return {"document_ids": [], "content_hashes": [], "paths": [ref]}


async def _with_pool(dsn: str):
    import asyncpg

    return await asyncpg.create_pool(dsn, min_size=1, max_size=2)


# ---------------------------------------------------------------------------
# hexis docs ...
# ---------------------------------------------------------------------------


async def docs_search(dsn: str, args: argparse.Namespace) -> int:
    query = " ".join(args.query) if args.query else None
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            if args.chunks:
                rows = await conn.fetch(
                    """
                    SELECT * FROM search_source_chunks(
                        $1::text, $2::int, NULL, $3::text, $4::text,
                        NULL, NULL, NULL, NULL, NULL, NULL, false, $5::int
                    )
                    """,
                    query, args.limit, args.path, args.type, args.offset,
                )
            else:
                rows = await conn.fetch(
                    """
                    SELECT * FROM search_source_documents(
                        $1::text, $2::int, $3::text, $4::text,
                        NULL, NULL, false, $5::int
                    )
                    """,
                    query, args.limit, args.path, args.type, args.offset,
                )
    finally:
        await pool.close()

    if args.json:
        payload = [dict(r) for r in rows]
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, make_table, warn

    if not rows:
        warn("No matches.")
        console.print(
            "Try: [bold]hexis docs search --chunks \"...\"[/bold] for passage search, "
            "drop filters, or ingest it first: [bold]hexis ingest --file <path>[/bold]"
        )
        return 0

    if args.chunks:
        table = make_table(
            ("Chunk", {"style": "bold"}), "Document", "Locator", ("Rank", {"justify": "right"}),
            title=f"Passages ({len(rows)})",
        )
        for r in rows:
            locator_bits = []
            if r["page_start"]:
                pages = str(r["page_start"])
                if r["page_end"] and r["page_end"] != r["page_start"]:
                    pages += f"-{r['page_end']}"
                locator_bits.append(f"page {pages}")
            if r["sheet_name"]:
                locator_bits.append(f"sheet {r['sheet_name']}")
            if r["heading_path"]:
                locator_bits.append(" > ".join(r["heading_path"]))
            table.add_row(
                str(r["chunk_id"])[:8],
                (r["title"] or r["path"] or "?")[:48],
                ", ".join(locator_bits) or f"chunk {r['chunk_index']}",
                f"{r['rank']:.3f}",
            )
        console.print(table)
        for r in rows[:5]:
            console.print(f"  [dim]{str(r['chunk_id'])[:8]}[/dim] {(r['snippet'] or '').strip()[:220]}")
        console.print(
            "\nOpen a passage: [bold]hexis docs open <document-ref> --page N[/bold]  ·  "
            "Load to desk: [bold]hexis docs load <document-ref> --pages N-M[/bold]"
        )
    else:
        table = make_table(
            ("Title", {"style": "bold"}), "Path", "Type", ("Rank", {"justify": "right"}), "Warnings",
            title=f"Documents ({len(rows)})",
        )
        for r in rows:
            warnings = _j(r["extraction_warnings"]) or []
            codes = ", ".join(sorted({w.get("code", "?") for w in warnings})) if warnings else ""
            table.add_row(
                (r["title"] or "?")[:48],
                (r["path"] or "")[:44],
                r["source_type"] or "",
                f"{r['rank']:.3f}",
                f"[warn]{codes}[/warn]" if codes else "",
            )
        console.print(table)
        for r in rows[:5]:
            console.print(f"  [dim]{str(r['document_id'])[:8]}[/dim] {(r['snippet'] or '').strip()[:220]}")
        console.print(
            "\nOpen: [bold]hexis docs open <id|path>[/bold]  ·  "
            "Details: [bold]hexis docs info <id|path>[/bold]  ·  "
            "Passages: [bold]hexis docs search --chunks \"...\"[/bold]"
        )
    return 0


async def docs_open(dsn: str, args: argparse.Namespace) -> int:
    page_start, page_end = _parse_pages(args.page)
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            if page_start is not None:
                sel = _selector_kwargs(args.ref)
                document_id = sel["document_ids"][0] if sel["document_ids"] else None
                if document_id is None:
                    doc = _j(await conn.fetchval(
                        "SELECT open_source_document(NULL, $1, $2, 0, 1)",
                        (sel["content_hashes"] or [None])[0], (sel["paths"] or [None])[0],
                    ))
                    if doc.get("error"):
                        return _docs_open_error(doc, args.ref)
                    document_id = doc["document_id"]
                payload = _j(await conn.fetchval(
                    "SELECT open_source_chunks(NULL, $1::uuid, NULL, NULL, $2::int, $3::int)",
                    document_id, page_start, page_end,
                ))
            else:
                sel = _selector_kwargs(args.ref)
                payload = _j(await conn.fetchval(
                    "SELECT open_source_document($1::uuid, $2, $3, $4::int, $5::int)",
                    (sel["document_ids"] or [None])[0],
                    (sel["content_hashes"] or [None])[0],
                    (sel["paths"] or [None])[0],
                    args.offset, args.chars,
                ))
    finally:
        await pool.close()

    if args.json:
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, heading, warn

    if payload.get("error"):
        return _docs_open_error(payload, args.ref)

    if "chunks" in payload:
        for chunk in payload["chunks"]:
            heading(f"{chunk.get('title') or chunk.get('path') or ''} — chunk {chunk['chunk_index']}"
                    + (f" (pages {chunk['page_start']}-{chunk['page_end']})" if chunk.get("page_start") else ""))
            console.print(chunk["content"])
            console.print("")
        return 0

    heading(payload.get("title") or args.ref)
    for w in payload.get("extraction_warnings") or []:
        warn(f"extraction [{w.get('code')}]: {w.get('message')}")
    console.print(payload.get("content") or "")
    if payload.get("truncated"):
        console.print(
            f"\n[dim]…truncated at {payload['returned_chars']} of {payload['total_chars']} chars.[/dim] "
            f"More: [bold]hexis docs open {args.ref} --offset {payload['next_offset']}[/bold]"
        )
    return 0


def _docs_open_error(payload: dict, ref: str) -> int:
    from apps.cli_theme import console, error

    if payload.get("error") == "not_found":
        error(f"No source document matches '{ref}'.")
        console.print("Find it first: [bold]hexis docs search \"...\"[/bold]")
    else:
        error(f"Could not open '{ref}': {payload.get('error')}")
    return 1


async def docs_info(dsn: str, args: argparse.Namespace) -> int:
    sel = _selector_kwargs(args.ref)
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            doc = _j(await conn.fetchval(
                "SELECT open_source_document($1::uuid, $2, $3, 0, 1)",
                (sel["document_ids"] or [None])[0],
                (sel["content_hashes"] or [None])[0],
                (sel["paths"] or [None])[0],
            ))
            if doc.get("error"):
                return _docs_open_error(doc, args.ref)
            document_id = doc["document_id"]
            chunk_stats = await conn.fetchrow(
                """
                SELECT count(*) AS chunks,
                       count(*) FILTER (WHERE embedding_status = 'embedded') AS embedded
                FROM source_document_chunks WHERE source_document_id = $1::uuid
                """,
                document_id,
            )
            artifact = _j(await conn.fetchval("SELECT get_source_artifact($1::uuid)", document_id))
            runs = await conn.fetch(
                """
                SELECT extractor_name, extractor_version, status, warnings, completed_at
                FROM source_extraction_runs
                WHERE source_document_id = $1::uuid
                ORDER BY created_at DESC LIMIT 5
                """,
                document_id,
            )
            desk_count = await conn.fetchval(
                """
                SELECT count(*) FROM subconscious_units
                WHERE status = 'active'
                  AND metadata #>> '{recmem,kind}' = 'source_document_desk'
                  AND metadata #>> '{recmem,document_id}' = $1
                """,
                str(document_id),
            )
    finally:
        await pool.close()

    if args.json:
        payload = {
            "document": {k: doc.get(k) for k in (
                "document_id", "title", "source_type", "path", "file_type",
                "content_hash", "original_hash", "word_count", "size_bytes",
                "created_at", "updated_at", "source_attribution")},
            "chunks": dict(chunk_stats),
            "artifact": artifact,
            "extraction_runs": [dict(r) for r in runs],
            "desk_items": desk_count,
        }
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, heading, kv, warn

    heading(doc.get("title") or args.ref)
    kv("Document ID", str(doc["document_id"]))
    kv("Path", str(doc.get("path") or ""))
    kv("Type", f"{doc.get('source_type')} ({doc.get('file_type')})")
    kv("Size", f"{doc.get('word_count')} words / {doc.get('size_bytes')} bytes")
    kv("Chunks", f"{chunk_stats['chunks']} ({chunk_stats['embedded']} embedded)")
    kv("On desk", str(desk_count))
    attribution = doc.get("source_attribution") or {}
    if attribution.get("acquisition"):
        kv("Acquired by", str(attribution["acquisition"]))
    if attribution.get("sensitivity"):
        kv("Sensitivity", str(attribution["sensitivity"]))
    if artifact and not artifact.get("error"):
        kv("Original", f"{artifact.get('storage_kind')} ({artifact.get('byte_size')} bytes, sha256 {str(artifact.get('sha256'))[:12]}…)")
    else:
        console.print("[dim]No original artifact preserved — content is normalized text only.[/dim]")
    if runs:
        console.print("\nExtraction runs:")
        for r in runs:
            warnings = _j(r["warnings"]) or []
            line = f"  [{r['status']}] {r['extractor_name']} {r['extractor_version']}".rstrip()
            console.print(line)
            for w in warnings:
                warn(f"    [{w.get('code')}] {w.get('message')}")
    console.print(
        f"\nRead it: [bold]hexis docs open {str(doc['document_id'])[:8]}…[/bold] "
        f"(full id above)  ·  Load to desk: [bold]hexis docs load <ref>[/bold]"
    )
    return 0


async def docs_load(dsn: str, args: argparse.Namespace) -> int:
    page_start, page_end = _parse_pages(args.pages)
    sel = _selector_kwargs(args.ref)
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            if page_start is not None:
                document_id = (sel["document_ids"] or [None])[0]
                if document_id is None:
                    doc = _j(await conn.fetchval(
                        "SELECT open_source_document(NULL, $1, $2, 0, 1)",
                        (sel["content_hashes"] or [None])[0], (sel["paths"] or [None])[0],
                    ))
                    if doc.get("error"):
                        return _docs_open_error(doc, args.ref)
                    document_id = doc["document_id"]
                payload = _j(await conn.fetchval(
                    """
                    SELECT load_source_chunks_to_recmem(
                        NULL, $1::uuid, NULL, NULL, $2::int, $3::int,
                        50, false, $4::text, NULL, 'cli', NULL, $5::boolean
                    )
                    """,
                    document_id, page_start, page_end, args.reason, bool(args.pin),
                ))
            else:
                payload = _j(await conn.fetchval(
                    """
                    SELECT load_source_documents_to_recmem(
                        $1::uuid[], $2::text[], $3::text[], 0, NULL, NULL, 10, false, $4::text
                    )
                    """,
                    sel["document_ids"], sel["content_hashes"], sel["paths"], args.reason,
                ))
    finally:
        await pool.close()

    if args.json:
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, error, success

    if payload.get("error"):
        error(f"Could not load '{args.ref}': {payload['error']}")
        console.print("Find it first: [bold]hexis docs search \"...\"[/bold]")
        return 1
    count = int(payload.get("count") or 0)
    if count == 0:
        error(f"No desk material loaded for '{args.ref}'.")
        console.print("Check the reference with [bold]hexis docs info <ref>[/bold]")
        return 1
    success(f"Loaded {count} item(s) onto the desk.")
    console.print(
        "See them: [bold]hexis desk list[/bold]  ·  "
        "Search them: [bold]hexis desk search \"...\"[/bold]"
    )
    return 0


# ---------------------------------------------------------------------------
# hexis desk ...
# ---------------------------------------------------------------------------


async def desk_list(dsn: str, args: argparse.Namespace) -> int:
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT * FROM list_recmem_desk($1::int, 0, NULL, $2::boolean)",
                args.limit, bool(args.pinned),
            )
    finally:
        await pool.close()

    if args.json:
        sys.stdout.write(json.dumps([dict(r) for r in rows], indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, make_table

    if not rows:
        console.print("The desk is clear.")
        console.print("Load something: [bold]hexis docs load <id|path>[/bold]")
        return 0
    table = make_table(
        ("Item", {"style": "bold"}), "Source", "Locator", "Pinned", "Last accessed",
        title=f"Desk ({rows[0]['total_count']} item(s))",
    )
    for r in rows:
        locator = _j(r["locator"]) or {}
        locator_bits = []
        if locator.get("page_start"):
            locator_bits.append(f"page {locator['page_start']}")
        if locator.get("sheet"):
            locator_bits.append(f"sheet {locator['sheet']}")
        if r["chunk_index"] is not None:
            locator_bits.append(f"chunk {r['chunk_index']}")
        table.add_row(
            str(r["desk_unit_id"])[:8],
            (r["title"] or r["path"] or "?")[:48],
            ", ".join(locator_bits) or "—",
            "📌" if r["pinned"] else "",
            str(r["last_accessed"] or "")[:16],
        )
    console.print(table)
    console.print(
        "\nRead: [bold]hexis desk open <item-id>[/bold]  ·  "
        "Pin: [bold]hexis desk pin <item-id>[/bold]  ·  "
        "Clear: [bold]hexis desk clear --all[/bold]"
    )
    return 0


async def _resolve_desk_unit(conn, prefix: str) -> str | None:
    """Allow the 8-char prefixes shown by desk list."""
    if re.fullmatch(r"[0-9a-fA-F-]{36}", prefix):
        return prefix
    row = await conn.fetchrow(
        """
        SELECT id FROM subconscious_units
        WHERE status = 'active'
          AND metadata #>> '{recmem,kind}' = 'source_document_desk'
          AND id::text LIKE $1
        LIMIT 2
        """,
        f"{prefix.lower()}%",
    )
    return str(row["id"]) if row else None


async def desk_open(dsn: str, args: argparse.Namespace) -> int:
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            unit_id = await _resolve_desk_unit(conn, args.id)
            if unit_id is None:
                from apps.cli_theme import console, error

                error(f"No desk item matches '{args.id}'.")
                console.print("List items: [bold]hexis desk list[/bold]")
                return 1
            payload = _j(await conn.fetchval(
                "SELECT open_recmem_desk_item($1::uuid, $2::int, $3::int)",
                unit_id, args.offset, args.chars,
            ))
    finally:
        await pool.close()

    if args.json:
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, error, heading

    if payload.get("error"):
        error(payload.get("hint") or "Desk item not found.")
        return 1
    heading(payload.get("title") or unit_id)
    console.print(payload.get("content") or "")
    if payload.get("truncated"):
        console.print(
            f"\n[dim]…{payload['returned_chars']} of {payload['total_chars']} chars.[/dim] "
            f"More: [bold]hexis desk open {args.id} --offset {payload['next_offset']}[/bold]"
        )
    if payload.get("next_desk_unit_id"):
        console.print(f"Next item in this document: [bold]hexis desk open {payload['next_desk_unit_id'][:8]}[/bold]")
    return 0


async def desk_search(dsn: str, args: argparse.Namespace) -> int:
    query = " ".join(args.query)
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT * FROM search_cross_session_history($1, $2::int, ARRAY['desk'])",
                query, args.limit,
            )
    finally:
        await pool.close()

    if args.json:
        sys.stdout.write(json.dumps([dict(r) for r in rows], indent=2, default=str) + "\n")
        return 0

    from apps.cli_theme import console, warn

    if not rows:
        warn("Nothing on the desk matches.")
        console.print(
            "See what's loaded: [bold]hexis desk list[/bold]  ·  "
            "Search the cabinet instead: [bold]hexis docs search \"...\"[/bold]"
        )
        return 0
    for r in rows:
        console.print(f"[bold]{str(r['item_id'])[:8]}[/bold] {(r['content'] or '').strip()[:300]}\n")
    console.print("Read one: [bold]hexis desk open <item-id>[/bold]")
    return 0


async def desk_pin(dsn: str, args: argparse.Namespace, *, pinned: bool) -> int:
    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            unit_id = await _resolve_desk_unit(conn, args.id)
            if unit_id is None:
                from apps.cli_theme import console, error

                error(f"No desk item matches '{args.id}'.")
                console.print("List items: [bold]hexis desk list[/bold]")
                return 1
            payload = _j(await conn.fetchval(
                "SELECT pin_recmem_desk_item($1::uuid, $2::boolean, 'cli')",
                unit_id, pinned,
            ))
    finally:
        await pool.close()

    from apps.cli_theme import error, success

    if payload.get("error"):
        error(payload.get("hint") or "Desk item not found.")
        return 1
    success(("Pinned" if pinned else "Unpinned") + " — "
            + ("desk cleanup will keep it." if pinned else "normal desk cleanup applies again."))
    return 0


async def desk_clear(dsn: str, args: argparse.Namespace) -> int:
    from apps.cli_theme import console, error, success

    pool = await _with_pool(dsn)
    try:
        async with pool.acquire() as conn:
            unit_ids: list[str] = []
            for prefix in args.ids or []:
                unit_id = await _resolve_desk_unit(conn, prefix)
                if unit_id is None:
                    error(f"No desk item matches '{prefix}'.")
                    console.print("List items: [bold]hexis desk list[/bold]")
                    return 1
                unit_ids.append(unit_id)
            payload = _j(await conn.fetchval(
                """
                SELECT clear_recmem_desk($1::uuid[], $2::uuid, NULL, NULL, $3::boolean, $4::boolean)
                """,
                unit_ids or None, args.doc, bool(args.all), bool(args.include_pinned),
            ))
    finally:
        await pool.close()

    if payload.get("error"):
        error("Nothing selected. Pass item ids, --doc <document-id>, or --all.")
        return 1
    cleared = int(payload.get("cleared") or 0)
    kept = int(payload.get("kept_pinned") or 0)
    message = f"Archived {cleared} desk item(s)"
    if kept:
        message += f"; {kept} pinned item(s) kept (use --include-pinned to clear those too)"
    success(message + ". Sources remain in the filing cabinet.")
    return 0
