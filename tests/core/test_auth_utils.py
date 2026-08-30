"""Tests for core.auth.utils — shared auth plumbing."""

import pytest

from core.auth.utils import (
    advisory_lock_key,
    create_state,
    generate_pkce,
    needs_refresh,
    now_ms,
)

pytestmark = pytest.mark.core


def test_generate_pkce_produces_valid_pair():
    verifier, challenge = generate_pkce()
    assert isinstance(verifier, str)
    assert isinstance(challenge, str)
    assert len(verifier) >= 43
    assert len(challenge) > 0
    # Challenge should be URL-safe base64 without padding
    assert "=" not in challenge
    assert "+" not in challenge
    assert "/" not in challenge


def test_generate_pkce_unique():
    v1, c1 = generate_pkce()
    v2, c2 = generate_pkce()
    assert v1 != v2
    assert c1 != c2


def test_create_state_hex():
    state = create_state()
    assert isinstance(state, str)
    assert len(state) == 32  # 16 bytes -> 32 hex chars
    int(state, 16)  # Should not raise


def test_create_state_unique():
    s1 = create_state()
    s2 = create_state()
    assert s1 != s2


def test_now_ms_returns_positive_int():
    ms = now_ms()
    assert isinstance(ms, int)
    assert ms > 0
    # Should be in the ballpark of current epoch ms
    assert ms > 1_700_000_000_000  # After ~2023


def test_advisory_lock_key_deterministic():
    key1 = advisory_lock_key("oauth.chutes")
    key2 = advisory_lock_key("oauth.chutes")
    assert key1 == key2
    assert isinstance(key1, int)


def test_advisory_lock_key_differs():
    k1 = advisory_lock_key("oauth.chutes")
    k2 = advisory_lock_key("oauth.github_copilot")
    assert k1 != k2


def test_needs_refresh_expired():
    past = now_ms() - 1000
    assert needs_refresh(past) is True


def test_needs_refresh_within_skew():
    # 100 seconds from now — within default 300s skew
    soon = now_ms() + 100_000
    assert needs_refresh(soon) is True


def test_needs_refresh_not_needed():
    # 600 seconds from now — well outside 300s skew
    future = now_ms() + 600_000
    assert needs_refresh(future) is False


def test_needs_refresh_custom_skew():
    future = now_ms() + 50_000  # 50s from now
    assert needs_refresh(future, skew_seconds=100) is True
    assert needs_refresh(future, skew_seconds=10) is False
