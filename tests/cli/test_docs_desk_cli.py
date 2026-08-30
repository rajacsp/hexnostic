"""`hexis docs` + `hexis desk`: the filing cabinet and desk from the
terminal, end to end against a seeded document."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.cli]

_ROOT = str(Path(__file__).resolve().parents[2])


def _run(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "apps.hexis_cli", *argv],
        capture_output=True,
        text=True,
        env=os.environ.copy(),
        cwd=_ROOT,
    )


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def _seed(db_pool, marker: str) -> str:
    async with db_pool.acquire() as conn:
        stored = _j(await conn.fetchval(
            """
            SELECT upsert_source_document(
                $1, 'document', $2, $3, '.md', $4, 30, '{}'::jsonb, '{}'::jsonb
            )
            """,
            f"CLI Doc {marker}", f"hash-{marker}", f"/tmp/{marker}.md",
            f"# CLI Doc {marker}\n\nThe glowmoss clause defines the retention window for {marker}.",
        ))
        doc_id = stored["document_id"]
        await conn.fetchval(
            "SELECT upsert_source_document_chunks($1::uuid, $2::jsonb, 'v2')",
            doc_id,
            json.dumps([{
                "chunk_index": 0, "locator_kind": "page",
                "content": f"The glowmoss clause defines the retention window for {marker}.",
                "char_start": 0, "char_end": 60, "page_start": 1, "page_end": 1,
            }]),
        )
    return doc_id


async def test_docs_search_open_info_and_desk_round_trip(db_pool):
    marker = get_test_identifier("clidocs")
    doc_id = await _seed(db_pool, marker)

    # docs search --json
    p = _run("docs", "search", f"glowmoss {marker}", "--json")
    assert p.returncode == 0, p.stderr
    rows = json.loads(p.stdout)
    assert any(str(r["document_id"]) == str(doc_id) for r in rows)

    # docs search --chunks --json carries locators + rank components
    p = _run("docs", "search", f"glowmoss {marker}", "--chunks", "--json")
    assert p.returncode == 0, p.stderr
    chunks = json.loads(p.stdout)
    assert chunks and chunks[0]["page_start"] == 1

    # docs open by path fragment
    p = _run("docs", "open", f"/tmp/{marker}.md", "--json")
    assert p.returncode == 0, p.stderr
    doc = json.loads(p.stdout)
    assert "glowmoss" in doc["content"]

    # docs info shows chunks and handles
    p = _run("docs", "info", str(doc_id), "--json")
    assert p.returncode == 0, p.stderr
    info = json.loads(p.stdout)
    assert info["chunks"]["chunks"] == 1

    # load to desk, list, search, pin, clear
    p = _run("docs", "load", str(doc_id), "--reason", "cli test", "--json")
    assert p.returncode == 0, p.stderr

    p = _run("desk", "list", "--json")
    assert p.returncode == 0, p.stderr
    items = json.loads(p.stdout)
    mine = [i for i in items if i["document_id"] == str(doc_id)]
    assert mine, items
    unit_id = mine[0]["desk_unit_id"]

    p = _run("desk", "search", "glowmoss", marker, "--json")
    assert p.returncode == 0, p.stderr
    hits = json.loads(p.stdout)
    assert any(str(h["item_id"]) == unit_id for h in hits)

    p = _run("desk", "pin", unit_id[:8])
    assert p.returncode == 0, p.stderr

    p = _run("desk", "clear", "--doc", str(doc_id))
    assert p.returncode == 0, p.stderr
    assert "pinned item(s) kept" in p.stdout

    p = _run("desk", "unpin", unit_id[:8])
    assert p.returncode == 0, p.stderr
    p = _run("desk", "clear", "--doc", str(doc_id))
    assert p.returncode == 0, p.stderr


async def test_docs_search_no_matches_gives_next_step(db_pool):
    p = _run("docs", "search", "definitely-not-present-zzz-quix")
    assert p.returncode == 0, p.stderr
    assert "hexis ingest" in p.stdout


async def test_desk_clear_requires_selector(db_pool):
    p = _run("desk", "clear")
    assert p.returncode == 1
    assert "--all" in p.stdout or "--all" in p.stderr
