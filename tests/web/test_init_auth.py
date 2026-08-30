from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest

from apps.hexis_api import app
from core.auth.ui_flow import AuthFlowError

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def client():
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://testserver",
    ) as test_client:
        yield test_client


async def test_auth_status_returns_only_coordinator_payload(client):
    payload = {
        "provider": "openai-codex",
        "configured": True,
        "account_id": "acct-visible",
    }
    with patch(
        "apps.hexis_api.auth_flow_coordinator.status", return_value=payload
    ) as status:
        response = await client.get(
            "/api/init/auth/status", params={"provider": "openai-codex"}
        )

    assert response.status_code == 200
    assert response.json() == payload
    status.assert_called_once_with("openai-codex")


async def test_auth_status_can_explicitly_refresh_validate(client):
    payload = {"provider": "anthropic", "configured": True}
    validate = AsyncMock(return_value=payload)
    with patch("apps.hexis_api.auth_flow_coordinator.validate", validate):
        response = await client.get(
            "/api/init/auth/status",
            params={"provider": "anthropic", "validate": "true"},
        )

    assert response.status_code == 200
    assert response.json() == payload
    validate.assert_awaited_once_with("anthropic")


async def test_auth_start_forwards_provider_options(client):
    payload = {
        "session_id": "session-1",
        "provider": "minimax-portal",
        "flow": "device_code",
        "status": "waiting_for_user",
    }
    start = AsyncMock(return_value=payload)
    with patch("apps.hexis_api.auth_flow_coordinator.start", start):
        response = await client.post(
            "/api/init/auth/start",
            json={"provider": "minimax-portal", "options": {"region": "cn"}},
        )

    assert response.status_code == 200
    assert response.json() == payload
    start.assert_awaited_once_with("minimax-portal", {"region": "cn"})


async def test_auth_errors_are_actionable_client_responses(client):
    with patch(
        "apps.hexis_api.auth_flow_coordinator.start",
        new=AsyncMock(side_effect=AuthFlowError("Enter a client ID.")),
    ):
        response = await client.post(
            "/api/init/auth/start",
            json={"provider": "chutes", "options": {}},
        )

    assert response.status_code == 400
    assert response.json() == {"detail": "Enter a client ID."}
