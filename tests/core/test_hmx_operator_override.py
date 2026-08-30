from __future__ import annotations

import pytest

from core.protected_replacement import (
    OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
    OPERATOR_OVERRIDE_REASON_CODES,
    ProtectedReplacementError,
    operator_override_signing_payload,
    validate_operator_override_fields,
)

_ENVELOPE = {
    "export_id": "override-payload-test",
    "export_intent": "port",
    "source": {
        "instance_id": "source-instance",
        "hexis_lineage_id": "source-lineage",
    },
}
_OPERATIONS = [
    {
        "section": "worldview",
        "local_digest_v1": "1" * 64,
        "imported_digest_v1": "2" * 64,
    },
    {
        "section": "drives",
        "local_digest_v1": "3" * 64,
        "imported_digest_v1": "4" * 64,
    },
]


def _payload(**changes):
    values = {
        "envelope": _ENVELOPE,
        "operations": _OPERATIONS,
        "acknowledgement": OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
        "reason_code": "state_corruption",
        "evidence_ref": "report:override-payload-test",
        "rationale": "Restore independently verified state",
        "operator_identity": "operator@example.test",
    }
    values.update(changes)
    return operator_override_signing_payload(**values)


def test_override_payload_is_order_independent_and_binds_authorization_fields():
    canonical = _payload()
    assert _payload(operations=list(reversed(_OPERATIONS))) == canonical

    changes = (
        {"acknowledgement": OPERATOR_OVERRIDE_ACKNOWLEDGEMENT + "."},
        {"reason_code": "emergency_recovery"},
        {"evidence_ref": "report:different"},
        {"rationale": "Different rationale"},
        {"operator_identity": "different-operator"},
        {
            "operations": [
                {**_OPERATIONS[0], "local_digest_v1": "5" * 64},
                _OPERATIONS[1],
            ]
        },
    )
    assert all(_payload(**change) != canonical for change in changes)


@pytest.mark.parametrize(
    ("changes", "code"),
    [
        ({"acknowledgement": "almost"}, "override_acknowledgement_mismatch"),
        ({"reason_code": "agent_refused"}, "invalid_override_reason_code"),
        ({"evidence_ref": "not-a-reference"}, "invalid_override_evidence_ref"),
        ({"rationale": "  "}, "replacement_rationale_missing"),
    ],
)
def test_override_fields_fail_closed(changes, code):
    values = {
        "acknowledgement": OPERATOR_OVERRIDE_ACKNOWLEDGEMENT,
        "reason_code": OPERATOR_OVERRIDE_REASON_CODES[0],
        "evidence_ref": "report:override-validation-test",
        "rationale": "Required rationale",
    }
    values.update(changes)
    with pytest.raises(ProtectedReplacementError, match=code):
        validate_operator_override_fields(**values)
