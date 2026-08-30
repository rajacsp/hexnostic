"""Qwen Portal OAuth (device code + PKCE) auth module."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from core.auth.utils import advisory_lock_key, generate_pkce, needs_refresh, now_ms
from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

# Constants (from OpenClaw extensions/qwen-portal-auth/oauth.ts)
QWEN_PORTAL_BASE = "https://chat.qwen.ai"
QWEN_PORTAL_DEVICE_CODE_URL = "https://chat.qwen.ai/api/v1/oauth2/device/code"
QWEN_PORTAL_TOKEN_URL = "https://chat.qwen.ai/api/v1/oauth2/token"
QWEN_PORTAL_CLIENT_ID = "f0304373b74a44d2b584a3fb70ca9e56"
QWEN_PORTAL_SCOPE = "openid profile email model.completion"
QWEN_PORTAL_DEFAULT_ENDPOINT = "https://portal.qwen.ai/v1"

QWEN_PORTAL_CONFIG_KEY = "oauth.qwen_portal"
_QWEN_PORTAL_LOCK_KEY = advisory_lock_key(QWEN_PORTAL_CONFIG_KEY)


@dataclass(frozen=True)
class QwenPortalCredentials:
    access: str
    refresh: str
    expires_ms: int
    resource_url: str | None = None


@dataclass
class DeviceCodeResponse:
    device_code: str
    user_code: str
    verification_uri: str
    verification_uri_complete: str | None
    expires_in: int
    interval: int


async def start_device_flow() -> tuple[DeviceCodeResponse, str]:
    """Start the device code flow. Returns (response, verifier) for PKCE."""
    verifier, challenge = generate_pkce()
    try:
        data = await request_json(
            "qwen_portal_oauth",
            "POST",
            QWEN_PORTAL_DEVICE_CODE_URL,
            headers={"Content-Type": "application/json"},
            json_body={
                "client_id": QWEN_PORTAL_CLIENT_ID,
                "scope": QWEN_PORTAL_SCOPE,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Qwen device code", exc)) from exc
    return DeviceCodeResponse(
        device_code=data["device_code"],
        user_code=data["user_code"],
        verification_uri=data["verification_uri"],
        verification_uri_complete=data.get("verification_uri_complete"),
        expires_in=int(data.get("expires_in", 900)),
        interval=int(data.get("interval", 2)),
    ), verifier


async def poll_for_token(
    device_code: str,
    verifier: str,
    interval_seconds: int,
    expires_in: int,
) -> QwenPortalCredentials:
    """Poll until the user authorizes or the flow expires."""
    import asyncio

    deadline = now_ms() + expires_in * 1000
    interval_ms = max(1000, interval_seconds * 1000)

    while now_ms() < deadline:
        try:
            data = await request_json(
                "qwen_portal_oauth",
                "POST",
                QWEN_PORTAL_TOKEN_URL,
                headers={"Content-Type": "application/json"},
                json_body={
                    "client_id": QWEN_PORTAL_CLIENT_ID,
                    "device_code": device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "code_verifier": verifier,
                },
                timeout=30.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=True,
            )
        except IntegrationHttpError as exc:
            raise RuntimeError(format_provider_error("Qwen device flow", exc)) from exc

        if isinstance(data.get("access_token"), str):
            access = data["access_token"]
            refresh = data.get("refresh_token", "")
            expires_in_resp = data.get("expires_in", 3600)
            resource_url = data.get("resource_url")
            return QwenPortalCredentials(
                access=access,
                refresh=refresh,
                expires_ms=now_ms() + int(expires_in_resp) * 1000,
                resource_url=resource_url,
            )

        error = data.get("error", "")
        if error == "authorization_pending":
            await asyncio.sleep(interval_ms / 1000)
            continue
        if error == "slow_down":
            interval_ms = int(interval_ms * 1.5)
            if interval_ms > 10000:
                interval_ms = 10000
            await asyncio.sleep(interval_ms / 1000)
            continue
        if error in {"expired_token", "access_denied"}:
            raise RuntimeError(f"Qwen device flow: {error}")
        raise RuntimeError(f"Qwen device flow failed: {error}")

    raise RuntimeError("Qwen device flow timed out.")


async def refresh_token(creds: QwenPortalCredentials) -> QwenPortalCredentials:
    try:
        data = await request_json(
            "qwen_portal_oauth",
            "POST",
            QWEN_PORTAL_TOKEN_URL,
            headers={"Content-Type": "application/json"},
            json_body={
                "client_id": QWEN_PORTAL_CLIENT_ID,
                "grant_type": "refresh_token",
                "refresh_token": creds.refresh,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Qwen token refresh", exc)) from exc
    access = data.get("access_token")
    refresh = data.get("refresh_token", creds.refresh)
    expires_in = data.get("expires_in", 3600)
    if not isinstance(access, str):
        raise RuntimeError("Qwen token refresh failed: missing access_token.")

    return QwenPortalCredentials(
        access=access,
        refresh=refresh,
        expires_ms=now_ms() + int(expires_in) * 1000,
        resource_url=data.get("resource_url") or creds.resource_url,
    )


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: QwenPortalCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": creds.expires_ms,
    }
    if creds.resource_url:
        d["resource_url"] = creds.resource_url
    return d


def credentials_from_value(value: Any) -> QwenPortalCredentials | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            return None
    if not isinstance(value, dict):
        return None
    access = value.get("access")
    refresh = value.get("refresh")
    expires_ms = value.get("expires_ms")
    if not isinstance(access, str) or not isinstance(refresh, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    return QwenPortalCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        resource_url=value.get("resource_url"),
    )


def load_credentials() -> QwenPortalCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(QWEN_PORTAL_CONFIG_KEY))


def save_credentials(creds: QwenPortalCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(QWEN_PORTAL_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(QWEN_PORTAL_CONFIG_KEY)


async def ensure_fresh_credentials(*, skew_seconds: int = 300) -> QwenPortalCredentials:
    from core.auth.store import auth_lock

    with auth_lock(QWEN_PORTAL_CONFIG_KEY):
        creds = load_credentials()
        if not creds:
            raise RuntimeError("Qwen Portal is not configured. Run: `hexis auth qwen-portal login`")
        if not needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        refreshed = await refresh_token(creds)
        save_credentials(refreshed)
        return refreshed
