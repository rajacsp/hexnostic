"""Chutes OAuth (PKCE) auth module."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

from core.auth.utils import advisory_lock_key, generate_pkce, needs_refresh, now_ms
from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

# Constants (from OpenClaw src/agents/chutes-oauth.ts)
CHUTES_ISSUER = "https://api.chutes.ai"
CHUTES_AUTHORIZE_URL = "https://api.chutes.ai/idp/authorize"
CHUTES_TOKEN_URL = "https://api.chutes.ai/idp/token"
CHUTES_USERINFO_URL = "https://api.chutes.ai/idp/userinfo"
CHUTES_DEFAULT_ENDPOINT = "https://api.chutes.ai/v1"

CHUTES_CONFIG_KEY = "oauth.chutes"
_CHUTES_LOCK_KEY = advisory_lock_key(CHUTES_CONFIG_KEY)


@dataclass(frozen=True)
class ChutesCredentials:
    access: str
    refresh: str
    expires_ms: int
    email: str | None = None
    account_id: str | None = None
    client_id: str | None = None


def build_authorize_url(
    *,
    challenge: str,
    state: str,
    client_id: str,
    redirect_uri: str,
    scope: str = "openid profile email offline_access",
) -> str:
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    return f"{CHUTES_AUTHORIZE_URL}?{urlencode(params)}"


async def exchange_code(
    *,
    code: str,
    verifier: str,
    client_id: str,
    redirect_uri: str,
    client_secret: str | None = None,
) -> ChutesCredentials:
    data: dict[str, str] = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": redirect_uri,
    }
    if client_secret:
        data["client_secret"] = client_secret

    try:
        body = await request_json(
            "chutes_oauth",
            "POST",
            CHUTES_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=data,
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Chutes token exchange", exc)) from exc
    access = body.get("access_token")
    refresh = body.get("refresh_token")
    expires_in = body.get("expires_in")
    if not isinstance(access, str) or not isinstance(refresh, str) or not isinstance(expires_in, (int, float)):
        raise RuntimeError("Chutes token exchange failed: missing fields.")

    email, account_id = await _fetch_userinfo(access)
    return ChutesCredentials(
        access=access,
        refresh=refresh,
        expires_ms=now_ms() + int(expires_in * 1000),
        email=email,
        account_id=account_id,
        client_id=client_id,
    )


async def refresh_token(creds: ChutesCredentials) -> ChutesCredentials:
    client_id = creds.client_id or os.getenv("CHUTES_CLIENT_ID", "")
    data: dict[str, str] = {
        "grant_type": "refresh_token",
        "refresh_token": creds.refresh,
        "client_id": client_id,
    }
    secret = os.getenv("CHUTES_CLIENT_SECRET")
    if secret:
        data["client_secret"] = secret

    try:
        body = await request_json(
            "chutes_oauth",
            "POST",
            CHUTES_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=data,
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Chutes token refresh", exc)) from exc
    access = body.get("access_token")
    refresh = body.get("refresh_token", creds.refresh)
    expires_in = body.get("expires_in")
    if not isinstance(access, str) or not isinstance(expires_in, (int, float)):
        raise RuntimeError("Chutes token refresh failed: missing fields.")

    return ChutesCredentials(
        access=access,
        refresh=refresh,
        expires_ms=now_ms() + int(expires_in * 1000),
        email=creds.email,
        account_id=creds.account_id,
        client_id=client_id or creds.client_id,
    )


async def _fetch_userinfo(access_token: str) -> tuple[str | None, str | None]:
    try:
        data = await request_json(
            "chutes",
            "GET",
            CHUTES_USERINFO_URL,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=10.0,
            attempts=2,
            max_delay=2.0,
        )
        if isinstance(data, dict):
            return data.get("username") or data.get("email"), data.get("sub")
    except Exception:
        pass
    return None, None


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: ChutesCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": creds.expires_ms,
    }
    if creds.email:
        d["email"] = creds.email
    if creds.account_id:
        d["account_id"] = creds.account_id
    if creds.client_id:
        d["client_id"] = creds.client_id
    return d


def credentials_from_value(value: Any) -> ChutesCredentials | None:
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
    return ChutesCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        email=value.get("email"),
        account_id=value.get("account_id"),
        client_id=value.get("client_id"),
    )


def load_credentials() -> ChutesCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(CHUTES_CONFIG_KEY))


def save_credentials(creds: ChutesCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(CHUTES_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(CHUTES_CONFIG_KEY)


async def ensure_fresh_credentials(*, skew_seconds: int = 300) -> ChutesCredentials:
    from core.auth.store import auth_lock

    with auth_lock(CHUTES_CONFIG_KEY):
        creds = load_credentials()
        if not creds:
            raise RuntimeError("Chutes OAuth is not configured. Run: `hexis auth chutes login`")
        if not needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        refreshed = await refresh_token(creds)
        save_credentials(refreshed)
        return refreshed
