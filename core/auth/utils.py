"""Provider-agnostic auth helpers: PKCE, state tokens, refresh checks."""

from __future__ import annotations

import base64
import hashlib
import secrets
import time
import zlib


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64url_decode(raw: str) -> bytes:
    s = raw.strip()
    if not s:
        return b""
    pad = "=" * ((4 - (len(s) % 4)) % 4)
    return base64.urlsafe_b64decode(s + pad)


def generate_pkce() -> tuple[str, str]:
    """Generate (verifier, challenge) for PKCE S256.

    Verifier is base64url(32 random bytes) => 43 chars.
    """
    verifier = _b64url_encode(secrets.token_bytes(32))
    challenge = _b64url_encode(hashlib.sha256(verifier.encode("utf-8")).digest())
    return verifier, challenge


def create_state() -> str:
    """Random 16-byte hex string for OAuth state parameter."""
    return secrets.token_hex(16)


def now_ms() -> int:
    """Current time in milliseconds since epoch."""
    return time.time_ns() // 1_000_000


def advisory_lock_key(config_key: str) -> int:
    """CRC32-based advisory lock ID for a given config key."""
    return zlib.crc32(config_key.encode("utf-8"))


def needs_refresh(expires_ms: int, skew_seconds: int = 300) -> bool:
    """Return True if the token expires within *skew_seconds* from now."""
    return expires_ms <= now_ms() + skew_seconds * 1000
