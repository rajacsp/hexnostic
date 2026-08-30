"""Hexis ingestion — split from the former services/ingest.py (#89).
Module: cli.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Optional
from uuid import UUID

from .config import Config, IngestionMode, _emit, _hash_text, _normalize_mode
from .pipeline import IngestionPipeline
from .sectioning import CHUNKER_VERSION, Sectioner
from .store import MemoryStore

# =========================================================================
# CLI
# =========================================================================


def _get_db_env_defaults() -> dict[str, Any]:
    """Get database configuration from environment variables."""
    env_db_port_raw = os.getenv("POSTGRES_PORT")
    try:
        env_db_port = int(env_db_port_raw) if env_db_port_raw else 43815
    except ValueError:
        env_db_port = 43815
    return {
        "db_host": os.getenv("POSTGRES_HOST", "localhost"),
        "db_port": env_db_port,
        "db_name": os.getenv("POSTGRES_DB", "hexis_memory"),
        "db_user": os.getenv("POSTGRES_USER", "postgres"),
        "db_password": os.getenv("POSTGRES_PASSWORD", "password"),
    }


def _add_common_args(parser: argparse.ArgumentParser, env_defaults: dict[str, Any]) -> None:
    """Add common arguments shared across subcommands."""
    parser.add_argument("--endpoint", "-e", default=None, help="LLM endpoint (overrides DB config)")
    parser.add_argument("--model", "-m", default=None, help="LLM model name (overrides DB config)")
    parser.add_argument("--api-key", default=None, help="LLM API key (overrides DB config)")
    parser.add_argument("--provider", default=None, help="LLM provider (overrides DB config)")

    parser.add_argument("--db-host", default=env_defaults["db_host"], help="Database host")
    parser.add_argument("--db-port", type=int, default=env_defaults["db_port"], help="Database port")
    parser.add_argument("--db-name", default=env_defaults["db_name"], help="Database name")
    parser.add_argument("--db-user", default=env_defaults["db_user"], help="Database user")
    parser.add_argument("--db-password", default=env_defaults["db_password"], help="Database password")

    parser.add_argument("--quiet", "-q", action="store_true", help="Suppress verbose output")


def _load_llm_config_from_db(args: argparse.Namespace) -> dict[str, Any] | None:
    """Load fully-resolved LLM config using the same path as `hexis chat`.

    Uses core.llm_config.load_llm_config() which handles provider-specific
    credential loading (OAuth tokens for Codex, etc.).
    """
    import asyncio

    import asyncpg

    async def _load() -> dict[str, Any] | None:
        try:
            dsn = (
                f"postgresql://{args.db_user}:{args.db_password}"
                f"@{args.db_host}:{args.db_port}/{args.db_name}"
            )
            conn = await asyncpg.connect(dsn)
            try:
                from core.llm_config import load_llm_config

                from .config import load_ingest_settings

                cfg = await load_llm_config(conn, "llm.chat", fallback_key="llm")
                # DB-owned ingest policy rides along (#91).
                return {"llm": cfg, "settings": await load_ingest_settings(conn)}
            finally:
                await conn.close()
        except Exception:
            return None

    return asyncio.run(_load())


def _build_config_from_args(args: argparse.Namespace) -> Config:
    """Build Config from parsed arguments.

    Priority: CLI flags > DB config (with full credential resolution) > defaults.
    """
    # Load fully-resolved config from DB (handles OAuth, etc.)
    db_loaded = _load_llm_config_from_db(args) or {}
    db_llm = db_loaded.get("llm") or {}
    db_settings = db_loaded.get("settings") or {}

    # CLI overrides (only if explicitly set — None means "not provided")
    cli_endpoint = getattr(args, "endpoint", None)
    cli_model = getattr(args, "model", None)
    cli_api_key = getattr(args, "api_key", None)
    cli_provider = getattr(args, "provider", None)

    llm_config: dict[str, Any] = dict(db_llm)
    if cli_endpoint:
        llm_config["endpoint"] = cli_endpoint
    if cli_model:
        llm_config["model"] = cli_model
    if cli_api_key:
        llm_config["api_key"] = cli_api_key
    if cli_provider:
        llm_config["provider"] = cli_provider

    return Config(
        llm_config=llm_config,
        db_host=args.db_host,
        db_port=args.db_port,
        db_name=args.db_name,
        db_user=args.db_user,
        db_password=args.db_password,
        mode=_normalize_mode(getattr(args, "mode", "auto")),
        min_importance_floor=getattr(args, "min_importance", None),
        permanent=getattr(args, "permanent", False),
        base_trust=getattr(args, "base_trust", None),
        sensitivity=getattr(args, "sensitivity", None),
        # CLI ingestion is always the user's own act.
        acquisition="user",
        verbose=not getattr(args, "quiet", False),
        # DB-owned policy (#91); dataclass defaults cover absent keys.
        **db_settings,
    )


def _cmd_ingest(args: argparse.Namespace) -> None:
    """Handle the ingest subcommand — the one sync shell (#88): a single
    asyncio.run at the very top of the CLI."""
    asyncio.run(_cmd_ingest_async(args))


async def _cmd_ingest_async(args: argparse.Namespace) -> None:
    config = _build_config_from_args(args)
    pipeline = IngestionPipeline(config)

    try:
        if args.stdin:
            count = await _ingest_stdin(pipeline, args)
        elif args.url:
            count = await _ingest_url(pipeline, args)
        elif getattr(args, "github", None):
            count = await _ingest_github(pipeline, args)
        elif args.file:
            count = await pipeline.ingest_file(args.file)
        elif args.input:
            count = await pipeline.ingest_directory(args.input, recursive=not args.no_recursive)
        else:
            print("Error: No input source specified")
            return
        pipeline.print_stats()
    except KeyboardInterrupt:
        print("\nInterrupted by user")
    finally:
        await pipeline.close()


async def _ingest_stdin(pipeline: IngestionPipeline, args: argparse.Namespace) -> int:
    """Ingest content from stdin — a reader over the shared core (#89)."""
    content = sys.stdin.read()
    if not content.strip():
        _emit(pipeline.config, "No content received from stdin")
        return 0

    content_type = getattr(args, "stdin_type", "text") or "text"
    title = getattr(args, "stdin_title", None) or f"stdin-{_hash_text(content)[:8]}"
    source_type_map = {
        "text": "document",
        "markdown": "document",
        "code": "code",
        "json": "data",
        "yaml": "data",
        "data": "data",
    }
    _emit(pipeline.config, f"Processing stdin: {title}")
    return await pipeline.ingest_text(
        content,
        title=title,
        source_type=source_type_map.get(content_type, "document"),
    )


async def _ingest_url(pipeline: IngestionPipeline, args: argparse.Namespace) -> int:
    """Ingest content from a URL."""
    title = getattr(args, "title", None)
    return await pipeline.ingest_url(args.url, title=title)


async def _ingest_github(pipeline: IngestionPipeline, args: argparse.Namespace) -> int:
    """Clone a GitHub repo to a temp dir and ingest its contents."""
    import shutil
    import subprocess
    import tempfile

    repo = args.github.strip()
    # Accept owner/repo shorthand
    if "/" in repo and not repo.startswith("http"):
        repo = f"https://github.com/{repo}"

    tmpdir = tempfile.mkdtemp(prefix="hexis_git_")
    try:
        cmd = ["git", "clone", "--depth", "1"]
        branch = getattr(args, "branch", None)
        if branch:
            cmd.extend(["--branch", branch])
        cmd.extend([repo, tmpdir])

        _emit(pipeline.config, f"Cloning {repo} ...")
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        count = await pipeline.ingest_directory(
            Path(tmpdir),
            recursive=True,
            exclude_dirs=IngestionPipeline.GIT_IGNORE_DIRS,
        )
        _emit(pipeline.config, f"Ingested {count} memories from {repo}")
        return count
    except subprocess.CalledProcessError as e:
        _emit(pipeline.config, f"Git clone failed: {e}")
        return 0
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def _cmd_status(args: argparse.Namespace) -> None:
    """Handle the status subcommand."""
    asyncio.run(_cmd_status_async(args))


async def _cmd_status_async(args: argparse.Namespace) -> None:
    config = _build_config_from_args(args)
    store = MemoryStore(config)
    await store.connect()

    try:
        if args.pending:
            # Query the ingestion job queue; archived-content processing is
            # retired in favor of preserved source documents.
            rows = await store._fetchval(
                """
                SELECT jsonb_agg(jsonb_build_object(
                    'id', id,
                    'kind', kind,
                    'hash', content_hash,
                    'status', status,
                    'attempts', attempts,
                    'next_attempt_at', next_attempt_at,
                    'created_at', created_at
                ))
                FROM ingestion_jobs
                WHERE status IN ('pending', 'in_progress')
                ORDER BY created_at DESC
                LIMIT 50
                """
            )
            pending = json.loads(rows) if rows else []

            if args.json:
                print(json.dumps(pending, indent=2, default=str))
            else:
                if not pending:
                    print("No pending ingestion jobs")
                else:
                    print(f"Pending ingestion jobs: {len(pending)}")
                    for p in pending:
                        print(
                            "  - "
                            f"{p.get('kind', 'unknown')} "
                            f"{p.get('status', 'unknown')} "
                            f"({str(p.get('hash') or '')[:8]}...)"
                        )
        else:
            # General ingestion stats
            stats = await store._fetchval(
                """
                SELECT jsonb_build_object(
                    'total_memories', (SELECT COUNT(*) FROM memories),
                    'episodic', (SELECT COUNT(*) FROM memories WHERE type = 'episodic'),
                    'semantic', (SELECT COUNT(*) FROM memories WHERE type = 'semantic'),
                    'source_documents', (SELECT COUNT(*) FROM source_documents WHERE status = 'active'),
                    'source_chunks', (SELECT COUNT(*) FROM source_document_chunks),
                    'chunks_pending_embedding', (SELECT COUNT(*) FROM source_document_chunks WHERE embedding_status IN ('pending', 'in_progress')),
                    'artifacts', (SELECT COUNT(*) FROM source_artifacts WHERE status = 'active'),
                    'pending_jobs', (SELECT COUNT(*) FROM ingestion_jobs WHERE status IN ('pending', 'in_progress')),
                    'recent_24h', (SELECT COUNT(*) FROM memories WHERE created_at > NOW() - INTERVAL '24 hours')
                )
                """
            )
            stats_data = json.loads(stats) if stats else {}

            runs_raw = await store._fetchval(
                """
                SELECT jsonb_agg(run_doc) FROM (
                    SELECT jsonb_build_object(
                        'title', COALESCE(d.title, '(extraction failed — artifact preserved)'),
                        'status', r.status,
                        'extractor', r.extractor_name
                            || CASE WHEN r.extractor_version <> '' THEN ' ' || r.extractor_version ELSE '' END,
                        'warnings', COALESCE((
                            SELECT string_agg(w->>'code', ', ')
                            FROM jsonb_array_elements(r.warnings) w
                        ), ''),
                        'errors', COALESCE((
                            SELECT string_agg(e->>'message', '; ')
                            FROM jsonb_array_elements(r.errors) e
                        ), ''),
                        'completed_at', r.completed_at
                    ) AS run_doc
                    FROM source_extraction_runs r
                    LEFT JOIN source_documents d ON d.id = r.source_document_id
                    ORDER BY r.created_at DESC
                    LIMIT 10
                ) sub
                """
            )
            runs = json.loads(runs_raw) if isinstance(runs_raw, str) else (runs_raw or [])
            stats_data["recent_extraction_runs"] = runs or []

            if args.json:
                print(json.dumps(stats_data, indent=2, default=str))
            else:
                print("Ingestion Status:")
                print(f"  Total memories:     {stats_data.get('total_memories', 0)}")
                print(f"  Episodic memories:  {stats_data.get('episodic', 0)}")
                print(f"  Semantic memories:  {stats_data.get('semantic', 0)}")
                print(f"  Source documents:   {stats_data.get('source_documents', 0)}")
                print(f"  Source chunks:      {stats_data.get('source_chunks', 0)} "
                      f"({stats_data.get('chunks_pending_embedding', 0)} awaiting embedding)")
                print(f"  Original artifacts: {stats_data.get('artifacts', 0)}")
                print(f"  Pending jobs:       {stats_data.get('pending_jobs', 0)}")
                print(f"  Last 24 hours:      {stats_data.get('recent_24h', 0)}")
                if runs:
                    print("\nRecent extraction runs:")
                    for run in runs:
                        line = f"  [{run.get('status')}] {run.get('title')} — {run.get('extractor')}"
                        if run.get("warnings"):
                            line += f" ⚠ {run['warnings']}"
                        if run.get("errors"):
                            line += f" ✗ {run['errors']}"
                        print(line)
    finally:
        await store.close()


def _cmd_backfill_chunks(args: argparse.Namespace) -> None:
    """Handle the backfill-chunks subcommand."""
    asyncio.run(_cmd_backfill_chunks_async(args))


async def _cmd_backfill_chunks_async(args: argparse.Namespace) -> None:
    """Re-chunk stored source documents that have no durable chunks yet (or
    whose chunks came from an older sectioner). Locators are re-derived from
    the inline markers readers leave in stored content ("[Page N]", ...).
    Embedding happens in the background maintenance worker afterwards."""
    config = _build_config_from_args(args)
    store = MemoryStore(config)
    await store.connect()
    sectioner = Sectioner(config.max_section_chars, config.chunk_overlap)

    limit = getattr(args, "limit", None)
    processed = 0
    chunk_total = 0
    failures: list[str] = []
    seen: set[str] = set()
    try:
        while True:
            batch = 20 if limit is None else max(1, min(20, limit - processed))
            raw = await store._fetchval(
                "SELECT source_chunk_backfill_candidates($1::int, $2::text)",
                batch, CHUNKER_VERSION,
            )
            candidates = json.loads(raw) if isinstance(raw, str) else (raw or [])
            candidates = [c for c in candidates if c.get("document_id") not in seen]
            if not candidates:
                break
            for cand in candidates:
                doc_id = str(cand["document_id"])
                seen.add(doc_id)
                title = cand.get("title") or doc_id[:8]
                row = await store._fetchval(
                    """
                    SELECT jsonb_build_object('content', content, 'file_type', file_type)
                    FROM source_documents WHERE id = $1::uuid AND status = 'active'
                    """,
                    doc_id,
                )
                doc = json.loads(row) if isinstance(row, str) else (row or {})
                content = doc.get("content")
                if not content:
                    continue
                file_type = doc.get("file_type") or ".txt"
                if not file_type.startswith("."):
                    file_type = f".{file_type}"
                try:
                    sections = sectioner.split(content, Path(f"document{file_type}"))
                    result = await store.upsert_source_document_chunks(
                        doc_id, sections, CHUNKER_VERSION
                    )
                except Exception as exc:
                    failures.append(f"{title}: {exc}")
                    print(f"  FAILED  {title}: {exc}")
                    continue
                count = int(result.get("count") or 0)
                chunk_total += count
                processed += 1
                print(
                    f"  {title}: {count} chunks "
                    f"({result.get('unchanged', 0)} unchanged, "
                    f"{result.get('re_embedded', 0)} re-embed, "
                    f"{result.get('trimmed', 0)} trimmed)"
                )
                if limit is not None and processed >= limit:
                    break
            if limit is not None and processed >= limit:
                break
        print(f"\nBackfilled {processed} document(s), {chunk_total} chunk(s).")
        if failures:
            print(f"{len(failures)} document(s) failed — see lines above; re-run to retry.")
        if chunk_total:
            print(
                "Embeddings are generated in the background by the maintenance "
                "worker (docker compose --profile active up -d, or hexis worker)."
            )
    finally:
        await store.close()


def _cmd_process(args: argparse.Namespace) -> None:
    """Handle the retired process subcommand."""
    asyncio.run(_cmd_process_async(args))


async def _cmd_process_async(_args: argparse.Namespace) -> None:
    print(
        "Archived-content processing is retired. Ingested artifacts are now "
        "preserved in source_documents. Use source-document tools to search, "
        "open, or load them onto the RecMem desk."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Hexis Universal Ingestion Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Subcommands:
  ingest           Ingest files, directories, URLs, or stdin
  status           Show ingestion status and pending items
  backfill-chunks  Chunk stored source documents that predate durable chunks
  process          Deprecated compatibility stub; archived processing is retired

Examples:
  %(prog)s ingest --file doc.md --mode fast
  %(prog)s ingest --input ./docs --mode slow
  %(prog)s ingest --url https://example.com/article
  echo "Some text" | %(prog)s ingest --stdin --stdin-type text
  %(prog)s status --pending
  %(prog)s backfill-chunks --limit 100
        """,
    )

    env_defaults = _get_db_env_defaults()
    subparsers = parser.add_subparsers(dest="subcommand")

    # Ingest subcommand
    ingest_p = subparsers.add_parser("ingest", help="Ingest content into memory")
    input_group = ingest_p.add_mutually_exclusive_group()
    input_group.add_argument("--file", "-f", type=Path, help="Single file to ingest")
    input_group.add_argument("--input", "-i", type=Path, help="Directory to ingest")
    input_group.add_argument("--url", "-u", type=str, help="URL to fetch and ingest")
    input_group.add_argument("--stdin", action="store_true", help="Read content from stdin")
    input_group.add_argument("--github", "-g", type=str, help="GitHub repo URL or owner/repo to clone and ingest")

    ingest_p.add_argument("--branch", type=str, default=None, help="Branch to clone (default: repo default)")
    ingest_p.add_argument("--stdin-type", choices=["text", "markdown", "code", "json", "yaml", "data"], default="text", help="Content type for stdin input")
    ingest_p.add_argument("--stdin-title", type=str, help="Title for stdin content")
    ingest_p.add_argument("--title", type=str, help="Override document title")

    ingest_p.add_argument("--mode", default="fast", choices=[m.value for m in IngestionMode], help="Ingestion mode")
    ingest_p.add_argument("--no-recursive", action="store_true", help="Don't recurse into subdirectories")
    ingest_p.add_argument("--min-importance", type=float, help="Minimum importance floor")
    ingest_p.add_argument("--permanent", action="store_true", help="Mark memories as permanent (no decay)")
    ingest_p.add_argument("--base-trust", type=float, help="Base trust level for source")
    ingest_p.add_argument(
        "--sensitivity", choices=["private"], default=None,
        help="Mark resulting memories private: excluded from group-channel "
             "recall and default HMX export",
    )

    _add_common_args(ingest_p, env_defaults)

    # Status subcommand
    status_p = subparsers.add_parser("status", help="Show ingestion status")
    status_p.add_argument("--pending", action="store_true", help="Show pending ingestion jobs")
    status_p.add_argument("--json", action="store_true", help="Output as JSON")
    _add_common_args(status_p, env_defaults)

    # Backfill-chunks subcommand
    backfill_p = subparsers.add_parser(
        "backfill-chunks",
        help="Chunk stored source documents that have no durable chunks yet",
    )
    backfill_p.add_argument(
        "--limit", type=int, default=None,
        help="Maximum documents to backfill this run (default: all)",
    )
    _add_common_args(backfill_p, env_defaults)

    # Process subcommand
    process_p = subparsers.add_parser("process", help="Deprecated: archived processing is retired")
    process_p.add_argument("--content-hash", type=str, help=argparse.SUPPRESS)
    process_p.add_argument("--all-archived", action="store_true", help=argparse.SUPPRESS)
    process_p.add_argument("--limit", type=int, default=10, help=argparse.SUPPRESS)
    _add_common_args(process_p, env_defaults)

    args = parser.parse_args()

    # Default to ingest if no subcommand (for backwards compatibility)
    if args.subcommand is None:
        # Check if any ingest-style args were provided
        if hasattr(args, "file") or hasattr(args, "input"):
            parser.print_help()
            print("\nError: Please use 'ingest' subcommand. Example: python -m services.ingest ingest --file doc.md")
        else:
            parser.print_help()
        return

    if args.subcommand == "ingest":
        if not (args.file or args.input or args.url or args.stdin or getattr(args, "github", None)):
            print("Error: One of --file, --input, --url, --stdin, or --github is required")
            return
        _cmd_ingest(args)
    elif args.subcommand == "status":
        _cmd_status(args)
    elif args.subcommand == "backfill-chunks":
        _cmd_backfill_chunks(args)
    elif args.subcommand == "process":
        _cmd_process(args)


if __name__ == "__main__":
    main()
