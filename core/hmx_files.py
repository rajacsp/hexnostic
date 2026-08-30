"""Safe JSON/JSONL file transport for Hexis Memory Exchange documents."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from core.memory_exchange import (
    HmxPolicyError,
    HmxSchemaError,
    iter_hmx_jsonl,
    parse_hmx_jsonl,
)


def parse_hmx_text(text: str, *, label: str = "input") -> dict[str, Any]:
    if not text.strip():
        raise HmxSchemaError(f"HMX input from {label} is empty")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return parse_hmx_jsonl(text.splitlines())
    if not isinstance(parsed, dict):
        raise HmxSchemaError(f"HMX input from {label} must be a JSON object")
    if parsed.get("record_type") == "envelope":
        return parse_hmx_jsonl(text.splitlines())
    return parsed


def load_hmx_file(path: str | Path) -> dict[str, Any]:
    resolved = Path(path).expanduser()
    try:
        text = resolved.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise HmxSchemaError(f"HMX file not found: {resolved}") from exc
    except OSError as exc:
        raise HmxSchemaError(f"could not read HMX file {resolved}: {exc}") from exc
    return parse_hmx_text(text, label=str(resolved))


def serialize_hmx_document(document: dict[str, Any], output_format: str) -> str:
    if output_format == "jsonl":
        return "\n".join(iter_hmx_jsonl(document)) + "\n"
    if output_format != "json":
        raise HmxPolicyError(f"unsupported HMX output format: {output_format!r}")
    return json.dumps(document, indent=2, sort_keys=True, default=str) + "\n"


def write_private_hmx_file(
    path: str | Path,
    content: str,
    *,
    overwrite: bool = False,
) -> Path:
    resolved = Path(path).expanduser()
    parent = resolved.parent
    if not parent.exists():
        raise HmxPolicyError(
            f"output directory does not exist: {parent}. Create it explicitly and retry."
        )
    if resolved.exists() and not overwrite:
        raise HmxPolicyError(
            f"output file already exists: {resolved}. Choose another path or enable overwrite "
            "explicitly (--overwrite in the CLI)."
        )

    fd, temporary = tempfile.mkstemp(prefix=f".{resolved.name}.", dir=parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if overwrite:
            os.replace(temporary, resolved)
        else:
            try:
                os.link(temporary, resolved)
            except FileExistsError as exc:
                raise HmxPolicyError(
                    f"output file already exists: {resolved}. Choose another path or enable overwrite "
                    "explicitly (--overwrite in the CLI)."
                ) from exc
            os.unlink(temporary)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return resolved
