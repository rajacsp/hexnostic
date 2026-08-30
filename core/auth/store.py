"""Filesystem-based credential store for auth providers.

Stores credentials as JSON files in ``~/.hexis/auth/`` so they survive
database resets (``docker-compose down -v``).
"""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Generator

AUTH_DIR = Path.home() / ".hexis" / "auth"


def _auth_file(key: str) -> Path:
    """Map a config key like ``oauth.openai_codex`` to a JSON file path."""
    return AUTH_DIR / f"{key}.json"


def _ensure_dir() -> None:
    AUTH_DIR.mkdir(parents=True, exist_ok=True)
    # Restrict permissions to owner only (credentials are sensitive)
    try:
        os.chmod(AUTH_DIR, 0o700)
    except OSError:
        pass


def load_auth(key: str) -> Any | None:
    """Load credentials for *key*. Returns parsed JSON or ``None``."""
    path = _auth_file(key)
    try:
        data = path.read_text(encoding="utf-8")
        return json.loads(data)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def save_auth(key: str, data: dict[str, Any]) -> None:
    """Atomically write credentials for *key* as JSON."""
    _ensure_dir()
    path = _auth_file(key)

    # Atomic write: temp file in same dir, then rename
    fd, tmp = tempfile.mkstemp(dir=AUTH_DIR, suffix=".tmp", prefix=f"{key}.")
    try:
        os.write(fd, json.dumps(data, indent=2).encode("utf-8"))
        os.fsync(fd)
        os.close(fd)
        os.replace(tmp, str(path))
        os.chmod(str(path), 0o600)
    except BaseException:
        os.close(fd) if not os.get_inheritable(fd) else None  # noqa: B018
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def delete_auth(key: str) -> None:
    """Delete stored credentials for *key*."""
    path = _auth_file(key)
    try:
        path.unlink()
    except FileNotFoundError:
        pass


@contextmanager
def auth_lock(key: str) -> Generator[None, None, None]:
    """Exclusive file lock scoped to a provider key.

    Replaces ``pg_advisory_xact_lock`` for serialising token refreshes.
    """
    _ensure_dir()
    lock_path = AUTH_DIR / f"{key}.lock"
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
