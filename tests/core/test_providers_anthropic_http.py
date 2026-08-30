"""Tests for core.providers.anthropic_http — HTTP Anthropic Messages client."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.providers.anthropic_http import (
    _build_headers,
    _convert_tools,
    _parse_response,
    anthropic_http_completion,
    stream_anthropic_http_completion,
)

pytestmark = pytest.mark.core


def test_build_headers_api_key():
    h = _build_headers("sk-test", "api-key")
    assert h["x-api-key"] == "sk-test"
    assert "Authorization" not in h
    assert h["anthropic-version"] == "2023-06-01"


def test_build_headers_setup_token():
    h = _build_headers("sk-ant-oat01-abc", "setup-token")
    assert h["Authorization"] == "Bearer sk-ant-oat01-abc"
    assert "x-api-key" not in h
    assert "anthropic-beta" in h
    assert "x-app" in h


def test_convert_tools_empty():
    assert _convert_tools(None) == []
    assert _convert_tools([]) == []


def test_convert_tools_format():
    tools = [{
        "type": "function",
        "function": {
            "name": "recall",
            "description": "Search memory",
            "parameters": {"type": "object", "properties": {"q": {"type": "string"}}},
        },
    }]
    result = _convert_tools(tools)
    assert len(result) == 1
    assert result[0]["name"] == "recall"
    assert result[0]["description"] == "Search memory"
    assert "input_schema" in result[0]


def test_parse_response_text_only():
    data = {
        "content": [
            {"type": "text", "text": "Hello "},
            {"type": "text", "text": "world"},
        ]
    }
    result = _parse_response(data)
    assert result["content"] == "Hello world"
    assert result["tool_calls"] == []


def test_parse_response_with_tool_use():
    data = {
        "content": [
            {"type": "text", "text": "Let me search."},
            {
                "type": "tool_use",
                "id": "tu_1",
                "name": "recall",
                "input": {"query": "hello"},
            },
        ]
    }
    result = _parse_response(data)
    assert result["content"] == "Let me search."
    assert len(result["tool_calls"]) == 1
    assert result["tool_calls"][0]["id"] == "tu_1"
    assert result["tool_calls"][0]["name"] == "recall"
    assert result["tool_calls"][0]["arguments"] == {"query": "hello"}


@pytest.mark.asyncio
async def test_anthropic_http_completion_non_streaming():
    """Test non-streaming completion with mocked httpx."""
    response_body = {
        "content": [{"type": "text", "text": "Test response"}],
        "model": "claude-sonnet-4-20250514",
        "stop_reason": "end_turn",
    }

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = response_body

    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("core.providers.anthropic_http.httpx.AsyncClient", return_value=mock_client):
        result = await anthropic_http_completion(
            endpoint="https://api.anthropic.com",
            api_key="sk-ant-oat01-test",
            model="claude-sonnet-4-20250514",
            messages=[{"role": "user", "content": "Hello"}],
            tools=None,
            auth_mode="setup-token",
        )

    assert result["content"] == "Test response"
    assert result["tool_calls"] == []
    # Verify the headers
    call_kwargs = mock_client.post.call_args
    headers = call_kwargs.kwargs.get("headers") or call_kwargs[1].get("headers", {})
    assert "Bearer" in headers.get("Authorization", "")


@pytest.mark.asyncio
async def test_anthropic_http_error_raises():
    """Test that non-2xx response raises RuntimeError."""
    mock_response = MagicMock()
    mock_response.status_code = 401
    mock_response.text = "Unauthorized"

    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("core.providers.anthropic_http.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(RuntimeError, match="401"):
            await anthropic_http_completion(
                endpoint="https://api.anthropic.com",
                api_key="bad-key",
                model="claude-sonnet-4-20250514",
                messages=[{"role": "user", "content": "Hello"}],
                tools=None,
            )


# ── OAuth parity with hermes-agent / openclaw ─────────────────────────────────

def test_oauth_identity_is_canonical_claude_code_string():
    from core.providers.anthropic_http import _CLAUDE_CODE_IDENTITY, _build_system_prompt
    # Must match hermes-agent / openclaw verbatim (Anthropic validates it).
    assert _CLAUDE_CODE_IDENTITY == "You are Claude Code, Anthropic's official CLI for Claude."
    sysp = _build_system_prompt("real prompt", "setup-token")
    assert sysp.startswith(_CLAUDE_CODE_IDENTITY)
    assert "real prompt" in sysp
    # api-key path is untouched
    assert _build_system_prompt("real prompt", "api-key") == "real prompt"


def test_oauth_mcp_tool_name_normalized_and_restored():
    from core.providers.anthropic_http import _oauth_tool_name, _tool_name_restore_map
    assert _oauth_tool_name("mcp_github_create_issue") == "mcp__github_create_issue"
    assert _oauth_tool_name("mcp__already") == "mcp__already"
    assert _oauth_tool_name("recall") == "recall"

    tools = [{"function": {"name": "mcp_gh_open", "description": "", "parameters": {}}},
             {"function": {"name": "recall", "description": "", "parameters": {}}}]
    # outbound: renamed only on the OAuth path
    assert [t["name"] for t in _convert_tools(tools, "setup-token")] == ["mcp__gh_open", "recall"]
    assert [t["name"] for t in _convert_tools(tools, "api-key")] == ["mcp_gh_open", "recall"]
    # inbound: response tool name restored to the original
    restore = _tool_name_restore_map(tools, "setup-token")
    parsed = _parse_response(
        {"content": [{"type": "tool_use", "id": "1", "name": "mcp__gh_open", "input": {}}]},
        restore,
    )
    assert parsed["tool_calls"][0]["name"] == "mcp_gh_open"
