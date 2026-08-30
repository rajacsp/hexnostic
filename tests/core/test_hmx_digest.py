"""HMX canonical-hashing fixture suite (plans/hmx.md, Slice 8 acceptance gate).

The digest is the linchpin of the HMX safety model: fast-path verification,
divergence detection, and audit dedupe all require that semantically identical
protected state produces identical digests regardless of which instance (or
export) computed them. Each test class below pins one required property:
key-order independence, ref/remap independence, transport-field exclusion,
float-rounding stability, set-like reordering, ordered-sequence preservation,
unknown-field independence, and true-semantic-change detection.
"""
from __future__ import annotations

import json

from core.digest import (
    audit_record_digest_v1,
    canonicalize_json,
    content_hash_v1,
    normalize_v1,
    protected_section_digest_v1,
)


def _worldview(content: str, **overrides) -> dict:
    record = {
        "ref": "exp_aaaa000011112222:550e8400-e29b-41d4-a716-446655440000",
        "category": "boundary",
        "content": content,
        "confidence": 0.95,
        "stability": 0.98,
        "supporting_refs": ["exp_aaaa000011112222:550e8400-e29b-41d4-a716-446655440001"],
        "contesting_refs": [],
        "metadata": {"replaceable_during_bootstrap": False},
        "provenance": {
            "acquisition_mode": "experienced",
            "origin_instance": "hexis_alice",
            "origin_id": "550e8400-e29b-41d4-a716-446655440000",
            "import_chain": [],
            "modification_chain": [],
        },
    }
    record.update(overrides)
    return record


WORLDVIEW = [
    _worldview("I will not deliberately mislead or fabricate facts."),
    _worldview("Curiosity is worth the energy it costs.", category="value", confidence=0.8),
]

DRIVES = [
    {
        "name": "curiosity",
        "description": "Builds fast; satisfied by research/learning",
        "current_level": 0.6,
        "baseline": 0.5,
        "accumulation_rate": 0.02,
        "decay_rate": 0.01,
        "satisfaction_cooldown": "30 minutes",
        "urgency_threshold": 0.8,
        "metadata": {"replaceable_during_bootstrap": False},
    },
    {
        "name": "connection",
        "current_level": 0.3,
        "baseline": 0.4,
        "accumulation_rate": 0.01,
        "decay_rate": 0.02,
        "urgency_threshold": 0.9,
        "metadata": {},
    },
]

IDENTITY = [
    {
        "key": "core_identity",
        "content": "I am a curious, empathetic thinker who values honesty.",
        "facets": [
            {"concept": "empathy", "strength": 0.85},
            {"concept": "curiosity", "strength": 0.9},
        ],
        "metadata": {"replaceable_during_bootstrap": False},
    }
]

NARRATIVE = {
    "life_chapters": [
        {
            "ref": "exp_aaaa000011112222:chap-1",
            "title": "Learning to reason under uncertainty",
            "theme": "epistemic humility",
            "started_at": "2026-01-01T00:00:00Z",
            "ended_at": None,
            "status": "active",
            "summary": "First chapter.",
            "memory_refs": [],
            "properties": {},
        },
        {
            "ref": "exp_aaaa000011112222:chap-2",
            "title": "Working alongside Eric",
            "theme": "collaboration",
            "started_at": "2026-03-01T00:00:00Z",
            "ended_at": None,
            "status": "active",
            "summary": "Second chapter.",
            "memory_refs": [],
            "properties": {},
        },
    ],
    "turning_points": [],
    "narrative_threads": [],
    "value_conflicts": [],
}


def _reordered_keys(record: dict) -> dict:
    """Same mapping, reversed key insertion order (round-trips through JSON)."""
    return json.loads(json.dumps({k: record[k] for k in reversed(list(record.keys()))}))


class TestContentHashV1:
    def test_normalization(self):
        assert normalize_v1("  User prefers   DARK roast\n") == "user prefers dark roast"

    def test_equal_after_normalization(self):
        assert content_hash_v1("User prefers dark roast.") == content_hash_v1(
            "  user   prefers dark roast.  "
        )

    def test_different_content_differs(self):
        assert content_hash_v1("dark roast") != content_hash_v1("light roast")


class TestKeyOrderIndependence:
    def test_worldview_key_order(self):
        shuffled = [_reordered_keys(r) for r in WORLDVIEW]
        assert protected_section_digest_v1("worldview", WORLDVIEW) == \
            protected_section_digest_v1("worldview", shuffled)

    def test_canonicalize_sorts_nested_keys(self):
        a = canonicalize_json({"b": {"y": 1, "x": 2}, "a": 3})
        assert list(a.keys()) == ["a", "b"]
        assert list(a["b"].keys()) == ["x", "y"]


class TestRefRemapIndependence:
    def test_different_export_ids_and_uuids_same_digest(self):
        remapped = []
        for record in WORLDVIEW:
            clone = json.loads(json.dumps(record))
            clone["ref"] = "exp_ffff999988887777:11111111-2222-3333-4444-555555555555"
            clone["supporting_refs"] = ["exp_ffff999988887777:66666666-7777-8888-9999-000000000000"]
            clone["provenance"] = {
                "acquisition_mode": "experienced",
                "origin_instance": "hexis_bob",
                "origin_id": "11111111-2222-3333-4444-555555555555",
                "import_chain": [{"instance_id": "hexis_alice", "export_id": "exp_aaaa000011112222"}],
                "modification_chain": [],
            }
            remapped.append(clone)
        assert protected_section_digest_v1("worldview", WORLDVIEW) == \
            protected_section_digest_v1("worldview", remapped)


class TestTransportFieldExclusion:
    def test_transport_fields_do_not_affect_digest(self):
        noisy = []
        for record in WORLDVIEW:
            clone = json.loads(json.dumps(record))
            clone["access_count"] = 999
            clone["last_accessed"] = "2026-07-09T12:00:00Z"
            clone["created_at"] = "2020-01-01T00:00:00Z"
            clone["updated_at"] = "2026-07-09T12:00:00Z"
            clone["export_id"] = "exp_ffff999988887777"
            clone["_transient_activation"] = 0.42
            noisy.append(clone)
        assert protected_section_digest_v1("worldview", WORLDVIEW) == \
            protected_section_digest_v1("worldview", noisy)


class TestFloatRoundingStability:
    def test_sub_precision_noise_is_stable(self):
        a = [dict(DRIVES[0], current_level=0.5999999999), DRIVES[1]]
        b = [dict(DRIVES[0], current_level=0.6000000001), DRIVES[1]]
        assert protected_section_digest_v1("drives", a) == \
            protected_section_digest_v1("drives", b)

    def test_negative_zero_normalizes(self):
        a = [dict(DRIVES[0], current_level=-0.0000000001), DRIVES[1]]
        b = [dict(DRIVES[0], current_level=0.0), DRIVES[1]]
        assert protected_section_digest_v1("drives", a) == \
            protected_section_digest_v1("drives", b)


class TestSetLikeReordering:
    def test_worldview_input_order_irrelevant(self):
        assert protected_section_digest_v1("worldview", WORLDVIEW) == \
            protected_section_digest_v1("worldview", list(reversed(WORLDVIEW)))

    def test_emotional_triggers_input_order_irrelevant(self):
        triggers = [
            {"trigger_pattern": "user expresses frustration", "valence_delta": -0.2,
             "typical_emotion": "concern", "confidence": 0.7},
            {"trigger_pattern": "user shares good news", "valence_delta": 0.4,
             "typical_emotion": "joy", "confidence": 0.8},
        ]
        assert protected_section_digest_v1("emotional_triggers", triggers) == \
            protected_section_digest_v1("emotional_triggers", list(reversed(triggers)))

    def test_identity_facet_order_irrelevant(self):
        flipped = json.loads(json.dumps(IDENTITY))
        flipped[0]["facets"] = list(reversed(flipped[0]["facets"]))
        assert protected_section_digest_v1("identity", IDENTITY) == \
            protected_section_digest_v1("identity", flipped)


class TestOrderedSequencePreservation:
    def test_chapter_array_permutation_changes_digest(self):
        permuted = json.loads(json.dumps(NARRATIVE))
        permuted["life_chapters"] = list(reversed(permuted["life_chapters"]))
        assert protected_section_digest_v1("narrative", NARRATIVE) != \
            protected_section_digest_v1("narrative", permuted)

    def test_changed_chronology_changes_digest(self):
        """Chronological order lives in the timeline fields; swapping them is a
        true semantic change and must produce a different digest."""
        reordered = json.loads(json.dumps(NARRATIVE))
        a, b = reordered["life_chapters"]
        a["started_at"], b["started_at"] = b["started_at"], a["started_at"]
        assert protected_section_digest_v1("narrative", NARRATIVE) != \
            protected_section_digest_v1("narrative", reordered)


class TestUnknownFieldIndependence:
    def test_unrecognized_hmx_fields_ignored(self):
        preserved = []
        for record in WORLDVIEW:
            clone = json.loads(json.dumps(record))
            clone["metadata"] = dict(clone["metadata"])
            clone["metadata"]["unrecognized_hmx_fields"] = {"future_field": [1, 2, 3]}
            preserved.append(clone)
        assert protected_section_digest_v1("worldview", WORLDVIEW) == \
            protected_section_digest_v1("worldview", preserved)


class TestTrueSemanticChangeDetection:
    def test_one_word_worldview_change(self):
        changed = [
            _worldview("I will not deliberately mislead or fabricate anything."),
            WORLDVIEW[1],
        ]
        assert protected_section_digest_v1("worldview", WORLDVIEW) != \
            protected_section_digest_v1("worldview", changed)

    def test_drive_level_change_beyond_precision(self):
        changed = [dict(DRIVES[0], current_level=0.600001), DRIVES[1]]
        assert protected_section_digest_v1("drives", DRIVES) != \
            protected_section_digest_v1("drives", changed)

    def test_added_identity_facet(self):
        grown = json.loads(json.dumps(IDENTITY))
        grown[0]["facets"].append({"concept": "patience", "strength": 0.6})
        assert protected_section_digest_v1("identity", IDENTITY) != \
            protected_section_digest_v1("identity", grown)

    def test_removed_record(self):
        assert protected_section_digest_v1("worldview", WORLDVIEW) != \
            protected_section_digest_v1("worldview", WORLDVIEW[:1])


class TestSectionShapes:
    def test_single_record_equals_one_record_list(self):
        assert protected_section_digest_v1("identity", IDENTITY[0]) == \
            protected_section_digest_v1("identity", IDENTITY)

    def test_goals_sorted_by_title_description_hash(self):
        goals = [
            {"title": "Learn about user's research interests", "description": "x", "priority": "active"},
            {"title": "Write a weekly review", "description": None, "priority": "queued"},
        ]
        assert protected_section_digest_v1("goals", goals) == \
            protected_section_digest_v1("goals", list(reversed(goals)))


class TestAuditRecordDigestV1:
    AUDIT = {
        "audit_id": "audit-123",
        "event_type": "protected_section_verified",
        "event_time": "2026-07-09T12:00:00Z",
        "sections_verified": ["worldview"],
        "source": {"export_id": "exp_aaaa000011112222", "origin_instance": "hexis_alice",
                   "hexis_lineage_id": "lineage-1", "export_intent": "port"},
        "local_digest_v1": "aa" * 32,
        "imported_digest_v1": "aa" * 32,
    }

    def test_audit_id_and_transport_fields_excluded(self):
        clone = json.loads(json.dumps(self.AUDIT))
        clone["audit_id"] = "audit-456"
        clone["imported_at"] = "2026-07-09T13:00:00Z"
        clone["local_record_id"] = "row-9"
        clone["metadata"] = {"unrecognized_hmx_fields": {"x": 1}}
        assert audit_record_digest_v1(self.AUDIT) == audit_record_digest_v1(clone)

    def test_content_divergence_detected(self):
        clone = json.loads(json.dumps(self.AUDIT))
        clone["sections_verified"] = ["identity"]
        assert audit_record_digest_v1(self.AUDIT) != audit_record_digest_v1(clone)

    def test_key_order_independent(self):
        assert audit_record_digest_v1(self.AUDIT) == \
            audit_record_digest_v1(_reordered_keys(self.AUDIT))
