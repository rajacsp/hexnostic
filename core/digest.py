"""HMX canonical hashing (plans/hmx.md, "Canonical Hashing").

HMX is an open standard: the byte contract here is defined entirely in
decimal/IEEE-754/Unicode terms (see "Canonical JSON Serialization v1" in the
spec) so ANY language can implement it, and the fixed vectors in
``tests/fixtures/digest/`` are the conformance suite. This module is the
Python reference implementation; ``db/57_functions_hmx_digest.sql`` is an
independent plpgsql implementation proving the contract is language-neutral.

Three versioned hash families:

- ``content_hash_v1``: coarse dedup hash over normalized text.
- ``protected_section_digest_v1``: canonical digest over a protected section's
  semantic state. Used by the Protected Section Replacement Protocol's Phase 0
  fast path and conflict detection. The same semantic state MUST produce the
  same digest regardless of which instance computes it, so canonicalization
  excludes transport metadata, sorts records by content-derived keys (never by
  local UUIDs), preserves ordered sequences, and rounds floats to a fixed
  precision.
- ``audit_record_digest_v1``: audit-record dedupe comparison with ``audit_id``
  and transport-local fields excluded.

Two spec resolutions, both following the overriding sort-key principle
(ref/remap independence — the v1.5 correctness fix) where the spec's field
lists conflict with it:

1. Reference fields: "edge connections within the section" cannot be included
   in digest input AND be independent of export-scoped refs/remapped local
   UUIDs. ``ref``, ``*_ref`` and ``*_refs`` fields are excluded entirely.
2. Provenance: its children ``import_chain``/``modification_chain`` are
   spec-excluded, and export enriches ``origin_instance``/``origin_id`` onto
   wire records asymmetrically with local rows, so including the subtree would
   make source and target digests differ for identical semantic state. The
   whole ``provenance`` subtree is excluded from digest input; per spec,
   ``provenance.origin_id`` still serves as the sort-key fallback (read from
   the original record before pruning).
3. Current life chapter: ``life_chapter_current`` is a projection of narrative
   state into the self-model, not independently owned identity state. It is
   excluded from the identity digest so replacing a chapter cannot appear to
   mutate two protected sections.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from typing import Any

FLOAT_PRECISION = 6

# A chapter array is an authored chronology, so its order is semantic. Other
# narrative collections are independent records and canonicalize as sets.
ORDERED_NARRATIVE_SUBSECTIONS = frozenset({"life_chapters"})

# Fields excluded from protected-section digests regardless of section
# (transport/storage metadata, never semantic state).
PROTECTED_DIGEST_EXCLUDED_FIELDS = frozenset(
    {
        "ref",
        "export_id",
        "import_chain",
        "modification_chain",
        "access_count",
        "last_accessed",
        "created_at",
        "updated_at",
        "hmx_id",
        "blocked_by",
        "parent_goal_id",
        "provenance",  # history/transport metadata; see module docstring note 2
    }
)

# Dotted paths excluded from audit-record digests, per spec.
AUDIT_DIGEST_EXCLUDED_FIELDS = frozenset(
    {
        "audit_id",
        "imported_at",
        "local_record_id",
        "metadata.unrecognized_hmx_fields",
    }
)

_TRANSIENT_PREFIX = "_transient_"
_REF_SUFFIXES = ("_ref", "_refs")

_WHITESPACE_RE = re.compile(r"\s+")


# ---------------------------------------------------------------------------
# content_hash_v1
# ---------------------------------------------------------------------------


def normalize_v1(content: str) -> str:
    """``lowercase(collapse_whitespace(trim(content)))`` per spec."""
    return _WHITESPACE_RE.sub(" ", content.strip()).lower()


def content_hash_v1(content: str) -> str:
    return hashlib.sha256(normalize_v1(content).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Canonicalization shared by the structured digests
# ---------------------------------------------------------------------------


def canonicalize_json(obj: Any) -> Any:
    """Sort dict keys recursively; round floats; preserve list order."""
    if isinstance(obj, dict):
        return {k: canonicalize_json(obj[k]) for k in sorted(obj.keys())}
    if isinstance(obj, list):
        return [canonicalize_json(item) for item in obj]
    if isinstance(obj, bool):  # bool before float/int: bool is an int subclass
        return obj
    if isinstance(obj, float):
        rounded = round(obj, FLOAT_PRECISION)
        return 0.0 if rounded == 0 else rounded
    return obj


def canonical_number_v1(value: float) -> str:
    """Serialize a non-integer number per Canonical JSON Serialization v1.

    Defined entirely in decimal/IEEE-754 terms (plans/hmx.md, "Canonical JSON
    Serialization v1") so any language can implement it:

    1. Reject non-finite values.
    2. Round the exact real value of the binary64 to the nearest integer
       multiple of 10^-6, ties to even (both steps exact over the reals), and
       take the binary64 nearest to that decimal. If the result is a zero of
       either sign, emit ``0.0``.
    3. Otherwise emit the shortest round-trip decimal representation of the
       result. With that representation written as d0.d1...dn x 10^e
       (normalized scientific form): use fixed notation when -4 <= e < 16
       (integral values keep a trailing ``.0``); otherwise scientific notation
       ``d0[.d1...dn]e<sign><exponent>`` with a mandatory sign and the exponent
       zero-padded to at least two digits.

    CPython's ``round(value, 6)`` and ``repr`` implement exactly this contract
    (correctly-rounded decimal rounding and Gay/Grisu shortest repr with the
    same notation thresholds); the conformance vectors in
    ``tests/fixtures/digest/`` pin every grammar branch for other
    implementations.
    """
    if math.isnan(value) or math.isinf(value):
        raise ValueError("non-finite numbers are not valid HMX canonical JSON")
    rounded = round(value, FLOAT_PRECISION)
    if rounded == 0:
        return "0.0"
    return repr(rounded)


def _serialize_canonical(obj: Any, out: list[str]) -> None:
    """Append the canonical serialization of ``obj`` to ``out``.

    Explicit rule-by-rule implementation of Canonical JSON Serialization v1
    (plans/hmx.md) so every emitted byte is a specified decision rather than
    inherited serializer behavior.
    """
    if obj is None:
        out.append("null")
    elif isinstance(obj, bool):  # bool before int: bool is an int subclass
        out.append("true" if obj else "false")
    elif isinstance(obj, str):
        # RFC 8259 escaping with all non-ASCII escaped as lowercase-hex
        # \uXXXX UTF-16 code units (astral code points become surrogate
        # pairs). json.dumps(ensure_ascii=True) implements exactly this.
        out.append(json.dumps(obj, ensure_ascii=True))
    elif isinstance(obj, int):
        # Integers: minimal decimal digits, arbitrary precision, no exponent.
        out.append(str(obj))
    elif isinstance(obj, float):
        out.append(canonical_number_v1(obj))
    elif isinstance(obj, dict):
        out.append("{")
        first = True
        for key in sorted(obj.keys()):  # lexicographic by Unicode code point
            if not isinstance(key, str):
                raise TypeError(f"canonical JSON object keys must be strings, got {type(key).__name__}")
            if not first:
                out.append(",")
            first = False
            out.append(json.dumps(key, ensure_ascii=True))
            out.append(":")
            _serialize_canonical(obj[key], out)
        out.append("}")
    elif isinstance(obj, list):
        out.append("[")
        for index, item in enumerate(obj):
            if index:
                out.append(",")
            _serialize_canonical(item, out)
        out.append("]")
    else:
        raise TypeError(f"{type(obj).__name__} is not a canonical JSON value")


def _canonical_bytes(obj: Any) -> bytes:
    """UTF-8 bytes of the Canonical JSON Serialization v1 of ``obj``.

    No whitespace, keys sorted by code point, ASCII-escaped strings, numbers
    per :func:`canonical_number_v1`. The fixed vectors in
    ``tests/fixtures/digest/`` pin this byte contract for all implementations.
    """
    out: list[str] = []
    _serialize_canonical(obj, out)
    return "".join(out).encode("utf-8")


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _is_excluded_key(key: str) -> bool:
    if key in PROTECTED_DIGEST_EXCLUDED_FIELDS:
        return True
    if key.startswith(_TRANSIENT_PREFIX):
        return True
    return key.endswith(_REF_SUFFIXES)


def strip_excluded_fields(value: Any) -> Any:
    """Remove transport/reference fields from a protected-section record tree.

    Also drops ``metadata.unrecognized_hmx_fields`` (preserved-but-not-understood
    data must not affect digest equality).
    """
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            if _is_excluded_key(key):
                continue
            if key == "metadata" and isinstance(item, dict):
                item = {
                    k: v
                    for k, v in item.items()
                    if k not in {"hmx", "unrecognized_hmx_fields"}
                    and not k.startswith("embedding_")
                }
            out[key] = strip_excluded_fields(item)
        return out
    if isinstance(value, list):
        return [strip_excluded_fields(item) for item in value]
    return value


def strip_paths(
    record: dict[str, Any], paths: frozenset[str] | set[str]
) -> dict[str, Any]:
    """Remove top-level keys and single-level dotted paths (``a.b``) from a record.

    A parent dict emptied by stripping is dropped too: its only content was
    transport data, and ``{"metadata": {}}`` must digest like no metadata at all.
    """
    out = json.loads(json.dumps(record))  # deep copy, JSON-shaped by construction
    for path in paths:
        head, _, tail = path.partition(".")
        if not tail:
            out.pop(head, None)
        elif isinstance(out.get(head), dict):
            out[head].pop(tail, None)
            if not out[head]:
                out.pop(head)
    return out


# ---------------------------------------------------------------------------
# protected_section_digest_v1
# ---------------------------------------------------------------------------


def _record_hash(record: Any) -> str:
    """Canonical-JSON hash of a pruned record — the always-defined last-resort
    sort key (and final tiebreak)."""
    return _sha256_hex(_canonical_bytes(record))


def _semantic_key(section_name: str, record: dict[str, Any]) -> str | None:
    """Per-section stable semantic sort key (spec: "Per-section sort keys")."""
    if section_name == "identity":
        key = record.get("key")
        return str(key) if key else None
    if section_name == "worldview":
        content = record.get("content")
        return content_hash_v1(str(content)) if content else None
    if section_name == "goals":
        title = record.get("title")
        if not title:
            return None
        return content_hash_v1(str(title) + str(record.get("description") or ""))
    if section_name == "drives":
        name = record.get("name")
        return str(name) if name else None
    if section_name == "emotional_triggers":
        pattern = record.get("trigger_pattern")
        return content_hash_v1(str(pattern)) if pattern else None
    return None


def _sort_key(section_name: str, original: Any, pruned_record: Any) -> tuple[str, str]:
    """Fallback hierarchy: semantic key -> provenance.origin_id -> record hash.

    ``provenance`` is pruned from digest input, so the origin_id fallback reads
    the original record. The final element is always the canonical record hash
    so true ties break deterministically.
    """
    record_hash = _record_hash(pruned_record)
    if isinstance(pruned_record, dict):
        semantic = _semantic_key(section_name, pruned_record)
        if semantic is not None:
            return (semantic, record_hash)
    if isinstance(original, dict):
        provenance = original.get("provenance")
        origin_id = (
            provenance.get("origin_id") if isinstance(provenance, dict) else None
        )
        if origin_id:
            return (str(origin_id), record_hash)
    return (record_hash, record_hash)


def _prepare_record(section_name: str, record: Any) -> Any:
    pruned = strip_excluded_fields(record)
    if section_name == "identity" and isinstance(pruned, dict):
        facets = pruned.get("facets")
        if isinstance(facets, list):
            facets = [
                facet
                for facet in facets
                if not (
                    isinstance(facet, dict)
                    and (facet.get("kind") or facet.get("type"))
                    == "life_chapter_current"
                )
            ]
            pruned["facets"] = sorted(
                facets,
                key=lambda f: (
                    str(f.get("concept", "")) if isinstance(f, dict) else str(f)
                ),
            )
    return pruned


def sort_records(section_name: str, records: list[Any]) -> list[Any]:
    """Prune a section's records and sort them by content-derived keys.

    Narrative subsections intentionally do NOT pass through here at the
    top level — see protected_section_digest_v1.
    """
    prepared = [(record, _prepare_record(section_name, record)) for record in records]
    prepared.sort(key=lambda pair: _sort_key(section_name, pair[0], pair[1]))
    return [pruned for _, pruned in prepared]


def _prepare_protected_section(section_name: str, section_data: Any) -> Any:
    """Return a protected section in its digest-ready semantic order."""
    if section_name == "narrative":
        if not isinstance(section_data, dict):
            raise TypeError("narrative section_data must be a dict of subsection lists")
        canonical_narrative: dict[str, Any] = {}
        for subsection in sorted(section_data.keys()):
            entries = section_data[subsection]
            if not isinstance(entries, list):
                entries = [entries]
            pruned = [_prepare_record("narrative", entry) for entry in entries]
            if subsection not in ORDERED_NARRATIVE_SUBSECTIONS:
                pruned.sort(key=_record_hash)
            canonical_narrative[subsection] = pruned
        return canonical_narrative

    if isinstance(section_data, dict):
        section_data = [section_data]
    if not isinstance(section_data, list):
        raise TypeError(f"section_data for {section_name!r} must be a list or dict")
    return sort_records(section_name, section_data)


def protected_section_canonical_bytes_v1(section_name: str, section_data: Any) -> bytes:
    """Canonical bytes hashed by :func:`protected_section_digest_v1`.

    This is public so other HMX implementations can diagnose compatibility
    failures against ``tests/fixtures/digest`` before comparing hashes.
    """
    return _canonical_bytes(_prepare_protected_section(section_name, section_data))


def protected_section_digest_v1(section_name: str, section_data: Any) -> str:
    """Digest of a protected section's semantic state.

    ``section_data`` shapes:
    - list of records (identity, worldview, goals, drives, emotional_triggers)
    - single record dict (treated as a one-record list)
    - narrative: dict of subsection lists (life_chapters, turning_points,
      narrative_threads, value_conflicts). ``life_chapters`` preserves authored
      chronological order; the other subsections canonicalize as sets.
    """
    return _sha256_hex(protected_section_canonical_bytes_v1(section_name, section_data))


# ---------------------------------------------------------------------------
# audit_record_digest_v1
# ---------------------------------------------------------------------------


def audit_record_canonical_bytes_v1(record: dict[str, Any]) -> bytes:
    """Canonical bytes hashed by :func:`audit_record_digest_v1`."""
    record_for_digest = strip_paths(record, AUDIT_DIGEST_EXCLUDED_FIELDS)
    return _canonical_bytes(record_for_digest)


def audit_record_digest_v1(record: dict[str, Any]) -> str:
    return _sha256_hex(audit_record_canonical_bytes_v1(record))
