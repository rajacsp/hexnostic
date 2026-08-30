from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from core.tools.base import ToolContext, ToolExecutionContext, ToolErrorType
from core.tools.messaging import SignalSendHandler, SlackSendHandler, TelegramSendHandler
from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


def _ctx(db_pool, marker: str) -> ToolExecutionContext:
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id=f"call-{marker}",
        session_id=marker,
        registry=SimpleNamespace(pool=db_pool),
    )


async def _snapshot_config(db_pool, keys: list[str]) -> dict[str, str]:
    async with db_pool.acquire() as conn:
        rows = await conn.fetch("SELECT key, value FROM config WHERE key = ANY($1::text[])", keys)
    return {row["key"]: json.dumps(_j(row["value"])) for row in rows}


async def _restore_config(db_pool, keys: list[str], snapshot: dict[str, str]) -> None:
    async with db_pool.acquire() as conn:
        for key in keys:
            if key in snapshot:
                await conn.execute("SELECT set_config($1, $2::jsonb)", key, snapshot[key])
            else:
                await conn.execute("DELETE FROM config WHERE key = $1", key)


async def test_slack_send_uses_db_channel_config_and_enforces_allowlist(db_pool, monkeypatch):
    marker = get_test_identifier("slack-send-db")
    token_env = f"HEXIS_TEST_SLACK_SEND_{marker.upper().replace('-', '_')}"
    monkeypatch.setenv(token_env, "xoxb-test-token-that-is-long-enough")
    keys = ["channel.slack.bot_token", "channel.slack.allowed_channels"]
    snapshot = await _snapshot_config(db_pool, keys)

    try:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT set_config('channel.slack.bot_token', $1::jsonb)", json.dumps(token_env))
            await conn.execute(
                "SELECT set_config('channel.slack.allowed_channels', $1::jsonb)",
                json.dumps(["C_ALLOWED"]),
            )

        result = await SlackSendHandler().execute(
            {"channel": "C_BLOCKED", "message": "This should not hit Slack."},
            _ctx(db_pool, marker),
        )
    finally:
        await _restore_config(db_pool, keys, snapshot)

    assert not result.success
    assert result.error_type == ToolErrorType.INVALID_PARAMS
    assert "allowed_channels" in result.error


async def test_telegram_send_uses_db_channel_config_and_enforces_allowlist(db_pool, monkeypatch):
    marker = get_test_identifier("telegram-send-db")
    token_env = f"HEXIS_TEST_TELEGRAM_SEND_{marker.upper().replace('-', '_')}"
    monkeypatch.setenv(token_env, "1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZ123456")
    keys = ["channel.telegram.bot_token", "channel.telegram.allowed_chat_ids"]
    snapshot = await _snapshot_config(db_pool, keys)

    try:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT set_config('channel.telegram.bot_token', $1::jsonb)", json.dumps(token_env))
            await conn.execute(
                "SELECT set_config('channel.telegram.allowed_chat_ids', $1::jsonb)",
                json.dumps(["123"]),
            )

        result = await TelegramSendHandler().execute(
            {"chat_id": "999", "message": "This should not hit Telegram."},
            _ctx(db_pool, marker),
        )
    finally:
        await _restore_config(db_pool, keys, snapshot)

    assert not result.success
    assert result.error_type == ToolErrorType.INVALID_PARAMS
    assert "allowed_chat_ids" in result.error


async def test_signal_send_uses_db_channel_config_and_enforces_allowlist(db_pool):
    marker = get_test_identifier("signal-send-db")
    keys = ["channel.signal.phone_number", "channel.signal.api_url", "channel.signal.allowed_numbers"]
    snapshot = await _snapshot_config(db_pool, keys)

    try:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT set_config('channel.signal.phone_number', $1::jsonb)", json.dumps("+15555550123"))
            await conn.execute("SELECT set_config('channel.signal.api_url', $1::jsonb)", json.dumps("http://localhost:8080"))
            await conn.execute(
                "SELECT set_config('channel.signal.allowed_numbers', $1::jsonb)",
                json.dumps(["+15550009999"]),
            )

        result = await SignalSendHandler().execute(
            {"recipient": "+15550001234", "message": "This should not hit Signal."},
            _ctx(db_pool, marker),
        )
    finally:
        await _restore_config(db_pool, keys, snapshot)

    assert not result.success
    assert result.error_type == ToolErrorType.INVALID_PARAMS
    assert "allowed_numbers" in result.error
