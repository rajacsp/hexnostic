"""Transient-error retry for LLM calls (the 429 that killed a live turn).

The codex branches were the one unretried path; _retry_on_transient now
covers them, recognizes status codes attached by _codex_http_error, honors
Retry-After, and refuses to replay a stream once tokens were delivered.
"""

from __future__ import annotations

import pytest

from core.llm import _codex_http_error, _retry_on_transient

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


class _Resp:
    def __init__(self, status_code: int, headers: dict[str, str] | None = None):
        self.status_code = status_code
        self.headers = headers or {}


async def test_retries_429_and_succeeds(monkeypatch):
    waits: list[float] = []

    async def _no_sleep(seconds):
        waits.append(seconds)

    import asyncio
    monkeypatch.setattr(asyncio, "sleep", _no_sleep)

    calls = {"n": 0}

    async def factory():
        calls["n"] += 1
        if calls["n"] < 3:
            raise _codex_http_error(_Resp(429, {"retry-after": "5"}), b'{"detail":"Rate limit exceeded"}')
        return {"content": "ok"}

    result = await _retry_on_transient(factory)
    assert result == {"content": "ok"}
    assert calls["n"] == 3
    # Retry-After 5s is honored (wait >= 5 on both retries).
    assert len(waits) == 2
    assert all(w >= 5.0 for w in waits)


async def test_error_carries_status_and_retry_after():
    err = _codex_http_error(_Resp(429, {"retry-after": "12"}), b"limited")
    assert err.status_code == 429
    assert err.retry_after == 12.0
    assert "HTTP 429" in str(err)


async def test_non_transient_raises_immediately():
    calls = {"n": 0}

    async def factory():
        calls["n"] += 1
        raise _codex_http_error(_Resp(401), b"unauthorized")

    with pytest.raises(RuntimeError, match="HTTP 401"):
        await _retry_on_transient(factory)
    assert calls["n"] == 1


async def test_should_retry_refuses_stream_replay():
    """Once tokens reached the consumer, a transient error must surface
    instead of replaying the stream (duplicate text)."""
    calls = {"n": 0}

    async def factory():
        calls["n"] += 1
        raise _codex_http_error(_Resp(429), b"limited")

    with pytest.raises(RuntimeError, match="HTTP 429"):
        await _retry_on_transient(factory, should_retry=lambda: False)
    assert calls["n"] == 1
