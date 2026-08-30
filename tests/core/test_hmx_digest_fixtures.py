"""Cross-implementation compatibility vectors for HMX digest v1 algorithms."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from core.digest import audit_record_digest_v1, protected_section_digest_v1

FIXTURE_DIR = Path(__file__).parents[1] / "fixtures" / "digest"


def _load(name: str) -> dict:
    return json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))


PROTECTED = _load("protected_section_digest_v1.json")
AUDIT = _load("audit_record_digest_v1.json")

REQUIRED_PROTECTED_RELATIONS = {
    "json_key_order",
    "ref_remap",
    "transport_fields",
    "operational_metadata",
    "goal_ref_remap",
    "identity_derived_projection",
    "float_rounding",
    "worldview_set_order",
    "emotional_trigger_set_order",
    "ordered_chapters",
    "unknown_fields",
    "worldview_semantic_change",
    "drive_semantic_change",
    "identity_semantic_change",
}


@pytest.mark.parametrize("vector", PROTECTED["vectors"], ids=lambda item: item["name"])
def test_protected_section_digest_fixture(vector):
    assert (
        protected_section_digest_v1(vector["section"], vector["input"])
        == vector["expected_digest"]
    )


@pytest.mark.parametrize("vector", AUDIT["vectors"], ids=lambda item: item["name"])
def test_audit_record_digest_fixture(vector):
    assert audit_record_digest_v1(vector["input"]) == vector["expected_digest"]


@pytest.mark.parametrize(
    "fixture", [PROTECTED, AUDIT], ids=lambda item: item["algorithm"]
)
def test_fixture_relations(fixture):
    vectors = {
        vector["name"]: vector["expected_digest"] for vector in fixture["vectors"]
    }
    for relation in fixture["relations"]:
        if relation["kind"] == "equal":
            assert vectors[relation["left"]] == vectors[relation["right"]]
        else:
            assert vectors[relation["left"]] != vectors[relation["right"]]


def test_protected_fixture_covers_slice_8_acceptance_gate():
    covered = {relation["covers"] for relation in PROTECTED["relations"]}
    assert REQUIRED_PROTECTED_RELATIONS <= covered
