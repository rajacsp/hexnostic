"""Instance-aware, AGE-safe backup & restore for a Hexis database.

Backup is a `pg_dump` custom-format (`-Fc`) dump of the whole database. On this
build Apache AGE marks its registration catalog (`ag_catalog.ag_graph` /
`ag_label`) as extension config, so the dump captures both the graph registration
and the `memory_graph.*` label tables — `cypher()` keeps working after a restore
(locked in by the round-trip test).

Restore drops and recreates the target database, then reloads the dump into the
empty database (a fresh restore avoids AGE `--clean` ordering hazards). It is
therefore **destructive** to the target instance's current contents — callers
confirm first, and services should be stopped so nothing reconnects mid-restore.

Uses the host `pg_dump`/`pg_restore`/`psql` client tools (as `core/tools/backup.py`
already does) against the active instance's DSN (`db_dsn_from_env`).
"""
from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from core.agent_api import db_dsn_from_env


def _parts(dsn: str) -> dict[str, str]:
    u = urlparse(dsn)
    return {
        "host": u.hostname or "localhost",
        "port": str(u.port or 5432),
        "user": u.username or "hexis_user",
        "password": u.password or "",
        "database": (u.path or "/hexis_memory").lstrip("/") or "hexis_memory",
    }


def _env(password: str) -> dict[str, str]:
    e = os.environ.copy()
    if password:
        e["PGPASSWORD"] = password
    return e


def _run(cmd: list[str], env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, env=env, capture_output=True, text=True)


def _safe(s: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in s)[:40]


def backup(dsn: str | None = None, out_dir: str | None = None, label: str | None = None) -> Path:
    """Write a custom-format dump of the active database; return its path."""
    dsn = dsn or db_dsn_from_env()
    p = _parts(dsn)
    out = Path(out_dir or os.path.expanduser("~/.hexis/backups"))
    out.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    name = f"hexis_{p['database']}_{ts}" + (f"_{_safe(label)}" if label else "") + ".dump"
    path = out / name
    r = _run(
        ["pg_dump", "-h", p["host"], "-p", p["port"], "-U", p["user"], "-d", p["database"],
         "-Fc", "--no-owner", "--no-acl", "-f", str(path)],
        _env(p["password"]),
    )
    if r.returncode != 0:
        raise RuntimeError(f"pg_dump failed: {(r.stderr or r.stdout).strip()}")
    # Continuity awareness (#95): a verified backup secures existence — the
    # DB records when/where and relaxes the continuity drive. Advisory: an
    # older schema without the function never blocks the backup itself.
    esc_label = (label or "").replace("'", "''")
    esc_path = str(path).replace("'", "''")
    r2 = _run(
        ["psql", "-h", p["host"], "-p", p["port"], "-U", p["user"], "-d", p["database"],
         "-qtc", f"SELECT record_backup_completed('{esc_label}', '{esc_path}')"],
        _env(p["password"]),
    )
    if r2.returncode != 0:
        print(f"note: backup completed but backup_status was not recorded: {(r2.stderr or '').strip()}")

    # Filesystem-stored source artifacts (originals larger than
    # ingest.artifact_max_db_bytes) live outside the dump — tar them as a
    # side-car so the backup preserves original artifacts too. Advisory.
    try:
        _backup_artifact_dir(path)
    except Exception as exc:
        print(f"note: artifact-directory side-car not written: {exc}")
    return path


def _artifact_dir() -> Path:
    return Path(os.environ.get("HEXIS_ARTIFACT_DIR") or "~/.hexis/artifacts").expanduser()


def _backup_artifact_dir(dump_path: Path) -> None:
    import tarfile

    src = _artifact_dir()
    if not src.is_dir() or not any(src.iterdir()):
        return
    side_car = dump_path.with_suffix(dump_path.suffix + ".artifacts.tar")
    with tarfile.open(side_car, "w") as tar:
        tar.add(src, arcname="artifacts")
    print(f"artifact side-car: {side_car}")


def _restore_artifact_dir(dump_path: Path) -> None:
    import tarfile

    side_car = dump_path.with_suffix(dump_path.suffix + ".artifacts.tar")
    if not side_car.exists():
        return
    dest = _artifact_dir()
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(side_car, "r") as tar:
        for member in tar.getmembers():
            rel = Path(member.name)
            if rel.parts and rel.parts[0] == "artifacts":
                rel = Path(*rel.parts[1:])
            if not rel.parts or rel.is_absolute() or ".." in rel.parts:
                continue
            target = dest / rel
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                # Content-addressed: never overwrite an existing artifact.
                if target.exists():
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                extracted = tar.extractfile(member)
                if extracted is not None:
                    target.write_bytes(extracted.read())
    print(f"artifact side-car restored into {dest}")


def restore(backup_path: str, dsn: str | None = None) -> None:
    """DESTRUCTIVE: drop + recreate the target database and reload the dump into it."""
    dsn = dsn or db_dsn_from_env()
    p = _parts(dsn)
    src = Path(backup_path).expanduser()
    if not src.exists():
        raise FileNotFoundError(f"backup file not found: {src}")
    env = _env(p["password"])
    db = p["database"]
    admin = ["psql", "-h", p["host"], "-p", p["port"], "-U", p["user"], "-d", "postgres",
             "-v", "ON_ERROR_STOP=1", "-qtc"]

    _run(admin + [f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                  f"WHERE datname = '{db}' AND pid <> pg_backend_pid()"], env)
    r = _run(admin + [f'DROP DATABASE IF EXISTS "{db}"'], env)
    if r.returncode != 0:
        raise RuntimeError(
            f"could not drop the target database (is something still connected? "
            f"stop the workers/API first): {r.stderr.strip()}")
    r = _run(admin + [f'CREATE DATABASE "{db}"'], env)
    if r.returncode != 0:
        raise RuntimeError(f"could not recreate the target database: {r.stderr.strip()}")

    r = _run(["pg_restore", "-h", p["host"], "-p", p["port"], "-U", p["user"], "-d", db,
              "--no-owner", "--no-acl", str(src)], env)
    # pg_restore returns nonzero even when it merely *ignored* benign errors and
    # completed (e.g. a newer client emitting GUCs like `transaction_timeout` that an
    # older server rejects). Fail only on genuinely fatal conditions.
    if r.returncode != 0:
        err = (r.stderr or "").lower()
        fatal = any(s in err for s in (
            "could not connect", "connection to server", "could not open input file",
            "does not appear to be a valid archive", "no such file", "fatal:",
        ))
        if fatal:
            raise RuntimeError(f"pg_restore failed: {r.stderr.strip()}")

    # Restore the filesystem artifact side-car, if one was written beside the
    # dump. Advisory: DB-stored artifacts already rode the dump itself.
    try:
        _restore_artifact_dir(src)
    except Exception as exc:
        print(f"note: artifact side-car not restored: {exc}")
