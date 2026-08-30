"""Original-artifact placement policy, shared by the pipeline and the API.

Bytes at or under the configured threshold live in-DB (they ride pg_dump
backups); larger artifacts go to the managed content-addressed directory
($HEXIS_ARTIFACT_DIR, default ~/.hexis/artifacts) with the sha recorded.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any

DEFAULT_MAX_DB_BYTES = 26214400  # 25 MB — mirrors config ingest.artifact_max_db_bytes


def default_artifact_dir() -> Path:
    return Path(os.environ.get("HEXIS_ARTIFACT_DIR") or "~/.hexis/artifacts").expanduser()


def prepare_artifact_info(
    raw: bytes,
    *,
    original_filename: str | None,
    mime_type: str | None,
    storage_kind: str | None = None,
    metadata: dict[str, Any] | None = None,
    max_db_bytes: int | None = None,
    artifact_dir: Path | None = None,
) -> dict[str, Any]:
    """Decide where original bytes live and stage them if filesystem-bound."""
    sha256 = hashlib.sha256(raw).hexdigest()
    info: dict[str, Any] = {
        "sha256": sha256,
        "byte_size": len(raw),
        "original_filename": original_filename,
        "mime_type": mime_type,
        "metadata": metadata or {},
    }
    threshold = max(0, int(max_db_bytes if max_db_bytes is not None else DEFAULT_MAX_DB_BYTES))
    if len(raw) <= threshold:
        info["storage_kind"] = storage_kind or "database"
        info["bytes"] = raw
        info["storage_ref"] = None
    else:
        target_dir = artifact_dir or default_artifact_dir()
        rel = Path(sha256[:2]) / sha256
        target = target_dir / rel
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_suffix(".tmp")
            tmp.write_bytes(raw)
            tmp.replace(target)
        info["storage_kind"] = "filesystem"
        info["bytes"] = None
        info["storage_ref"] = str(rel)
    return info
