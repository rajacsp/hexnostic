"""The PL/pgSQL HMX digest implementation must reproduce the conformance
vectors byte-for-byte.

HMX is an open standard: the byte contract is specified language-neutrally in
plans/hmx.md ("Canonical JSON Serialization v1") and pinned by
tests/fixtures/digest/. core/digest.py is the Python reference
implementation; db/57_functions_hmx_digest.sql is an independent PL/pgSQL
implementation. Two languages agreeing on every vector is the proof that the
contract has no hidden language dependence.
"""

import json
import random
from decimal import Decimal
from pathlib import Path

import pytest

from core.digest import canonical_number_v1, content_hash_v1

pytestmark = [pytest.mark.asyncio(loop_scope="session")]

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "digest"


def _wire_json(value) -> str:
    """Serialize preserving number token kinds: a Decimal keeps its scale, so
    the SQL reader sees the same integer-vs-fraction tokens the fixture file
    carries (json.dumps would rewrite big floats as bare-exponent tokens)."""
    if isinstance(value, dict):
        return "{" + ",".join(f"{json.dumps(k, ensure_ascii=True)}:{_wire_json(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(_wire_json(v) for v in value) + "]"
    if isinstance(value, Decimal):
        return str(value)
    return json.dumps(value, ensure_ascii=True)


def _load_wire(name: str) -> dict:
    with open(FIXTURES / name) as f:
        return json.load(f, parse_float=Decimal)


async def test_sql_reproduces_every_protected_section_vector(db_pool):
    doc = _load_wire("protected_section_digest_v1.json")
    assert doc["algorithm"] == "protected_section_digest_v1"
    async with db_pool.acquire() as conn:
        for vector in doc["vectors"]:
            got = await conn.fetchval(
                "SELECT hmx_protected_section_digest_v1($1, $2::jsonb)",
                vector["section"],
                _wire_json(vector["input"]),
            )
            assert got == vector["expected_digest"], vector["name"]


async def test_sql_satisfies_every_fixture_relation(db_pool):
    doc = _load_wire("protected_section_digest_v1.json")
    by_name = {v["name"]: v for v in doc["vectors"]}
    async with db_pool.acquire() as conn:

        async def digest(name: str) -> str:
            vector = by_name[name]
            return await conn.fetchval(
                "SELECT hmx_protected_section_digest_v1($1, $2::jsonb)",
                vector["section"],
                _wire_json(vector["input"]),
            )

        for relation in doc["relations"]:
            left = await digest(relation["left"])
            right = await digest(relation["right"])
            if relation["kind"] == "equal":
                assert left == right, relation["covers"]
            else:
                assert left != right, relation["covers"]


async def test_sql_reproduces_every_audit_record_vector(db_pool):
    doc = _load_wire("audit_record_digest_v1.json")
    assert doc["algorithm"] == "audit_record_digest_v1"
    async with db_pool.acquire() as conn:
        for vector in doc["vectors"]:
            got = await conn.fetchval(
                "SELECT hmx_audit_record_digest_v1($1::jsonb)",
                _wire_json(vector["input"]),
            )
            assert got == vector["expected_digest"], vector["name"]


async def test_sql_number_grammar_matches_python_reference(db_pool):
    edges = [
        0.0, -0.0, 1.0, 5.0, -0.2, 0.5, 0.600001, 0.95,
        0.0001, 1e-05, 2e-06, 1e-07, -4.9e-07, 4.999999949999999e-07,
        0.1234565, 0.0078125, 123456789.987654,
        1e15, 9.9e15, 1e16, 1.5e20, 1e100, 5e-324,
        1.7976931348623157e308, 6.671587262097402e16,
    ]
    rng = random.Random(20260716)
    values = edges + (
        [rng.uniform(-1, 1) for _ in range(60)]
        + [rng.uniform(-1e9, 1e9) for _ in range(40)]
        + [rng.uniform(0, 1e-4) for _ in range(40)]
        + [rng.uniform(1e14, 1e18) for _ in range(30)]
    )
    async with db_pool.acquire() as conn:
        for value in values:
            got = await conn.fetchval("SELECT hmx_canonical_float_v1($1::float8)", value)
            assert got == canonical_number_v1(value), repr(value)


async def test_sql_content_hash_matches_python_reference(db_pool):
    samples = [
        "  Hello   WORLD  ",
        "caf\u00e9 \U0001f600 unicode",
        "\tleading tab\tand\nnewline\n",
        "",
        "MiXeD Case  with\u00a0nbsp and\u3000ideographic separators",
        "CAF\u00c9 STRAUSS",
        "file\u001cseparator",
    ]
    async with db_pool.acquire() as conn:
        for sample in samples:
            got = await conn.fetchval("SELECT hmx_content_hash_v1($1)", sample)
            assert got == content_hash_v1(sample), repr(sample)


async def test_sql_rejects_non_finite_numbers(db_pool):
    import asyncpg

    async with db_pool.acquire() as conn:
        for literal in ("'NaN'", "'Infinity'", "'-Infinity'"):
            with pytest.raises(asyncpg.exceptions.RaiseError):
                await conn.fetchval(f"SELECT hmx_canonical_float_v1({literal}::float8)")
