from __future__ import annotations

import base64

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from core.trust_anchors import (
    HMX_OPERATOR_PUBLIC_KEY_ENV,
    Ed25519TrustAnchors,
    TrustAnchorVerifier,
    TrustStatus,
    TrustVerification,
    UnconfiguredTrustAnchors,
    load_trust_anchor_verifier_from_env,
    require_verified,
)


def test_unconfigured_verifier_satisfies_interface_and_fails_closed():
    verifier = UnconfiguredTrustAnchors()
    assert isinstance(verifier, TrustAnchorVerifier)

    operator = verifier.verify_operator_signature(signature="claim", payload=b"body")
    source = verifier.verify_source_identity(source={"instance_id": "source"})
    lineage = verifier.verify_lineage(
        source={"hexis_lineage_id": "same"},
        local_instance_id="local",
        local_lineage_id="same",
    )

    assert {operator.status, source.status, lineage.status} == {TrustStatus.UNVERIFIED}
    assert all(not result.verified for result in (operator, source, lineage))
    assert lineage.metadata["claim_type"] == "lineage"


def test_unverified_signature_cannot_authorize_an_operation():
    result = UnconfiguredTrustAnchors().verify_operator_signature(
        signature="uncheckable", payload=b"replacement"
    )

    try:
        require_verified(result, operation="operator override")
    except PermissionError as exc:
        assert "no HMX trust anchors" in str(exc)
    else:
        raise AssertionError("unverified claim authorized an override")


def test_verified_and_invalid_results_preserve_audit_context():
    accepted = TrustVerification.accepted(
        anchor_id="operator-key-2026",
        metadata={"algorithm": "ed25519"},
    )
    rejected = TrustVerification.invalid(
        "signature mismatch", anchor_id="operator-key-2026"
    )

    require_verified(accepted, operation="operator override")
    assert accepted.verified
    assert accepted.metadata["algorithm"] == "ed25519"
    assert rejected.status is TrustStatus.INVALID
    assert not rejected.verified


def test_ed25519_verifier_accepts_only_the_exact_signed_payload():
    private_key = Ed25519PrivateKey.generate()
    verifier = Ed25519TrustAnchors(private_key.public_key())
    payload = b"canonical HMX operator override"
    signature = base64.b64encode(private_key.sign(payload)).decode("ascii")

    verified = verifier.verify_operator_signature(
        signature=f"ed25519:{signature}", payload=payload
    )
    changed = verifier.verify_operator_signature(
        signature=signature, payload=payload + b" changed"
    )

    assert verified.status is TrustStatus.VERIFIED
    assert verified.anchor_id == verifier.anchor_id
    assert verified.metadata["payload_sha256"]
    assert changed.status is TrustStatus.INVALID


def test_environment_loader_accepts_raw_key_and_rejects_bad_configuration():
    private_key = Ed25519PrivateKey.generate()
    raw_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    verifier = load_trust_anchor_verifier_from_env(
        {HMX_OPERATOR_PUBLIC_KEY_ENV: base64.b64encode(raw_key).decode("ascii")}
    )

    assert isinstance(verifier, Ed25519TrustAnchors)
    assert isinstance(load_trust_anchor_verifier_from_env({}), UnconfiguredTrustAnchors)
    with pytest.raises(ValueError, match="32-byte Ed25519"):
        load_trust_anchor_verifier_from_env(
            {HMX_OPERATOR_PUBLIC_KEY_ENV: base64.b64encode(b"short").decode("ascii")}
        )
