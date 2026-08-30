"""Fail-closed trust-anchor interface for HMX identity claims.

HMX deliberately does not choose a global PKI. Deployments plug in their own
verifier, while the unconfigured default makes the absence of verification
explicit and never turns a claimed signature or lineage into authorization.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping, Protocol, runtime_checkable

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

HMX_OPERATOR_PUBLIC_KEY_ENV = "HEXIS_HMX_OPERATOR_ED25519_PUBLIC_KEY"


class TrustStatus(str, Enum):
    """The security-relevant outcome of checking one trust claim."""

    VERIFIED = "verified"
    UNVERIFIED = "unverified"
    INVALID = "invalid"


@dataclass(frozen=True)
class TrustVerification:
    """A verifier result suitable for audit records and CLI diagnostics."""

    status: TrustStatus
    reason: str
    anchor_id: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    @property
    def verified(self) -> bool:
        return self.status is TrustStatus.VERIFIED

    @classmethod
    def accepted(
        cls,
        *,
        anchor_id: str,
        reason: str = "claim verified against configured trust anchor",
        metadata: Mapping[str, Any] | None = None,
    ) -> "TrustVerification":
        return cls(TrustStatus.VERIFIED, reason, anchor_id, metadata or {})

    @classmethod
    def unverified(
        cls,
        reason: str,
        *,
        metadata: Mapping[str, Any] | None = None,
    ) -> "TrustVerification":
        return cls(TrustStatus.UNVERIFIED, reason, metadata=metadata or {})

    @classmethod
    def invalid(
        cls,
        reason: str,
        *,
        anchor_id: str | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> "TrustVerification":
        return cls(TrustStatus.INVALID, reason, anchor_id, metadata or {})


@runtime_checkable
class TrustAnchorVerifier(Protocol):
    """Deployment-provided verification boundary used by HMX import paths.

    ``payload`` is the exact canonical bytes covered by a signature. Lineage
    verification receives both ends of the claim because equality of two
    unverified labels is not proof of shared lineage.
    """

    def verify_operator_signature(
        self,
        *,
        signature: str,
        payload: bytes,
        operator_identity: str | None = None,
    ) -> TrustVerification: ...

    def verify_source_identity(
        self,
        *,
        source: Mapping[str, Any],
        signature: str | None = None,
        payload: bytes | None = None,
    ) -> TrustVerification: ...

    def verify_lineage(
        self,
        *,
        source: Mapping[str, Any],
        local_instance_id: str,
        local_lineage_id: str,
    ) -> TrustVerification: ...


class UnconfiguredTrustAnchors:
    """Explicit default for deployments with no configured trust anchors.

    This is intentionally not a permissive verifier. Callers may display the
    claimed values as labels, but every authorization decision must observe
    ``verified is False``.
    """

    _REASON = "no HMX trust anchors are configured; the claim is a label, not proof"

    def verify_operator_signature(
        self,
        *,
        signature: str,
        payload: bytes,
        operator_identity: str | None = None,
    ) -> TrustVerification:
        return TrustVerification.unverified(
            self._REASON,
            metadata={"claim_type": "operator_signature"},
        )

    def verify_source_identity(
        self,
        *,
        source: Mapping[str, Any],
        signature: str | None = None,
        payload: bytes | None = None,
    ) -> TrustVerification:
        return TrustVerification.unverified(
            self._REASON,
            metadata={"claim_type": "source_identity"},
        )

    def verify_lineage(
        self,
        *,
        source: Mapping[str, Any],
        local_instance_id: str,
        local_lineage_id: str,
    ) -> TrustVerification:
        return TrustVerification.unverified(
            self._REASON,
            metadata={"claim_type": "lineage"},
        )


class Ed25519TrustAnchors:
    """Verify HMX operator signatures against one configured Ed25519 key."""

    def __init__(self, public_key: Ed25519PublicKey):
        self._public_key = public_key
        raw_key = public_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        self.anchor_id = f"ed25519:sha256:{hashlib.sha256(raw_key).hexdigest()}"

    def verify_operator_signature(
        self,
        *,
        signature: str,
        payload: bytes,
        operator_identity: str | None = None,
    ) -> TrustVerification:
        metadata = {
            "algorithm": "ed25519",
            "claim_type": "operator_signature",
            "payload_sha256": hashlib.sha256(payload).hexdigest(),
        }
        encoded = signature.strip()
        if encoded.startswith("ed25519:"):
            encoded = encoded.removeprefix("ed25519:")
        try:
            signature_bytes = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            return TrustVerification.invalid(
                "operator signature must be base64, optionally prefixed with ed25519:",
                anchor_id=self.anchor_id,
                metadata=metadata,
            )
        if len(signature_bytes) != 64:
            return TrustVerification.invalid(
                "Ed25519 operator signature must decode to 64 bytes",
                anchor_id=self.anchor_id,
                metadata=metadata,
            )
        try:
            self._public_key.verify(signature_bytes, payload)
        except InvalidSignature:
            return TrustVerification.invalid(
                "operator signature does not match the configured trust anchor",
                anchor_id=self.anchor_id,
                metadata=metadata,
            )
        return TrustVerification.accepted(
            anchor_id=self.anchor_id,
            reason="operator signature verified against the configured Ed25519 trust anchor",
            metadata=metadata,
        )

    def verify_source_identity(
        self,
        *,
        source: Mapping[str, Any],
        signature: str | None = None,
        payload: bytes | None = None,
    ) -> TrustVerification:
        return TrustVerification.unverified(
            "the configured operator key does not prove HMX source identity",
            metadata={"claim_type": "source_identity"},
        )

    def verify_lineage(
        self,
        *,
        source: Mapping[str, Any],
        local_instance_id: str,
        local_lineage_id: str,
    ) -> TrustVerification:
        return TrustVerification.unverified(
            "the configured operator key does not prove an HMX lineage claim",
            metadata={"claim_type": "lineage"},
        )


def _load_ed25519_public_key(value: str) -> Ed25519PublicKey:
    encoded = value.strip()
    if not encoded:
        raise ValueError(f"{HMX_OPERATOR_PUBLIC_KEY_ENV} cannot be empty")
    if encoded.startswith("-----BEGIN PUBLIC KEY-----"):
        try:
            key = serialization.load_pem_public_key(encoded.encode("ascii"))
        except (UnicodeEncodeError, ValueError, TypeError) as exc:
            raise ValueError(
                f"{HMX_OPERATOR_PUBLIC_KEY_ENV} is not a valid PEM public key"
            ) from exc
        if not isinstance(key, Ed25519PublicKey):
            raise ValueError(
                f"{HMX_OPERATOR_PUBLIC_KEY_ENV} must contain an Ed25519 public key"
            )
        return key

    if encoded.startswith("ed25519:"):
        encoded = encoded.removeprefix("ed25519:")
    try:
        raw_key = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError(
            f"{HMX_OPERATOR_PUBLIC_KEY_ENV} must be a base64 raw Ed25519 public key or PEM"
        ) from exc
    if len(raw_key) != 32:
        raise ValueError(
            f"{HMX_OPERATOR_PUBLIC_KEY_ENV} must decode to a 32-byte Ed25519 public key"
        )
    return Ed25519PublicKey.from_public_bytes(raw_key)


def load_trust_anchor_verifier_from_env(
    environ: Mapping[str, str] | None = None,
) -> TrustAnchorVerifier:
    """Load the CLI operator trust anchor without inventing a permissive default."""

    source = os.environ if environ is None else environ
    configured = source.get(HMX_OPERATOR_PUBLIC_KEY_ENV)
    if configured is None:
        return UnconfiguredTrustAnchors()
    return Ed25519TrustAnchors(_load_ed25519_public_key(configured))


def require_verified(result: TrustVerification, *, operation: str) -> None:
    """Fail closed at an authorization boundary with an actionable reason."""

    if not result.verified:
        raise PermissionError(
            f"{operation} requires a verified trust claim: {result.reason}"
        )
