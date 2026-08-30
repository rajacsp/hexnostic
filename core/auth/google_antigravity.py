"""Google Antigravity OAuth (Cloud Code Assist sandbox) auth module."""

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

# Constants (from OpenClaw extensions/google-antigravity-auth/index.ts)
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_USERINFO_URL = "https://www.googleapis.com/oauth2/v1/userinfo?alt=json"

ANTIGRAVITY_REDIRECT_URI = "http://localhost:51121/oauth-callback"
ANTIGRAVITY_DEFAULT_PROJECT_ID = "rising-fact-p41fc"

# Extra scopes beyond Gemini CLI
ANTIGRAVITY_SCOPES = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs",
]

CODE_ASSIST_ENDPOINTS = [
    "https://cloudcode-pa.googleapis.com",
    "https://daily-cloudcode-pa.sandbox.googleapis.com",
]

ANTIGRAVITY_CONFIG_KEY = "oauth.google_antigravity"
_ANTIGRAVITY_LOCK_KEY = advisory_lock_key(ANTIGRAVITY_CONFIG_KEY)


def _get_client_credentials(
    client_id: str | None = None,
    client_secret: str | None = None,
) -> tuple[str, str]:
    """Resolve explicitly supplied client credentials, then environment defaults."""
    client_id = client_id or os.getenv("ANTIGRAVITY_OAUTH_CLIENT_ID")
    client_secret = client_secret or os.getenv("ANTIGRAVITY_OAUTH_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise RuntimeError(
            "Google Antigravity OAuth requires ANTIGRAVITY_OAUTH_CLIENT_ID and "
            "ANTIGRAVITY_OAUTH_CLIENT_SECRET environment variables."
        )
    return client_id, client_secret


@dataclass(frozen=True)
class AntigravityCredentials:
    access: str
    refresh: str
    expires_ms: int
    project_id: str
    email: str | None = None
    client_id: str | None = None
    client_secret: str | None = None


def build_authorize_url(
    *,
    challenge: str,
    state: str,
    client_id: str | None = None,
    client_secret: str | None = None,
) -> str:
    client_id, _ = _get_client_credentials(client_id, client_secret)
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": ANTIGRAVITY_REDIRECT_URI,
        "scope": " ".join(ANTIGRAVITY_SCOPES),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "access_type": "offline",
        "prompt": "consent",
    }
    return f"{GOOGLE_AUTH_URL}?{urlencode(params)}"


async def exchange_code(
    *,
    code: str,
    verifier: str,
    client_id: str | None = None,
    client_secret: str | None = None,
) -> dict[str, Any]:
    client_id, client_secret = _get_client_credentials(client_id, client_secret)
    try:
        data = await request_json(
            "google_oauth",
            "POST",
            GOOGLE_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": ANTIGRAVITY_REDIRECT_URI,
                "code_verifier": verifier,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Google Antigravity token exchange", exc)) from exc
    return data


async def refresh_access_token(
    refresh_token: str,
    *,
    client_id: str | None = None,
    client_secret: str | None = None,
) -> tuple[str, int]:
    client_id, client_secret = _get_client_credentials(client_id, client_secret)
    try:
        data = await request_json(
            "google_oauth",
            "POST",
            GOOGLE_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Google Antigravity token refresh", exc)) from exc
    access = data.get("access_token")
    expires_in = data.get("expires_in", 3600)
    if not isinstance(access, str):
        raise RuntimeError("Google Antigravity token refresh: missing access_token.")
    return access, now_ms() + int(expires_in) * 1000


async def fetch_user_email(access_token: str) -> str | None:
    try:
        data = await request_json(
            "google_userinfo",
            "GET",
            GOOGLE_USERINFO_URL,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=10.0,
            attempts=2,
            max_delay=2.0,
        )
        if isinstance(data, dict):
            return data.get("email")
    except Exception:
        pass
    return None


async def discover_project(access_token: str) -> str:
    """Try Cloud Code Assist endpoints, fall back to default project."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
        "Client-Metadata": json.dumps(
            {
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            }
        ),
    }
    body = json.dumps(
        {
            "metadata": {
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            },
        }
    )

    for endpoint in CODE_ASSIST_ENDPOINTS:
        try:
            data = await request_json(
                "google_code_assist",
                "POST",
                f"{endpoint}/v1internal:loadCodeAssist",
                headers=headers,
                json_body=json.loads(body),
                timeout=30.0,
                attempts=2,
                max_delay=5.0,
                retry_unsafe_methods=True,
            )
            project = data.get("cloudaicompanionProject") if isinstance(data, dict) else None
            if isinstance(project, str):
                return project
            if isinstance(project, dict) and project.get("id"):
                return project["id"]
        except Exception:
            continue

    return ANTIGRAVITY_DEFAULT_PROJECT_ID


async def complete_login(
    code: str,
    verifier: str,
    *,
    client_id: str | None = None,
    client_secret: str | None = None,
) -> AntigravityCredentials:
    resolved_client_id, resolved_client_secret = _get_client_credentials(
        client_id, client_secret
    )
    token_data = await exchange_code(
        code=code,
        verifier=verifier,
        client_id=resolved_client_id,
        client_secret=resolved_client_secret,
    )
    access = token_data["access_token"]
    refresh = token_data.get("refresh_token", "")
    expires_in = token_data.get("expires_in", 3600)
    expires_ms = now_ms() + int(expires_in) * 1000

    email = await fetch_user_email(access)
    project_id = await discover_project(access)

    return AntigravityCredentials(
        access=access,
        refresh=refresh,
        expires_ms=expires_ms,
        project_id=project_id,
        email=email,
        client_id=resolved_client_id,
        client_secret=resolved_client_secret,
    )


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------


def credentials_to_dict(creds: AntigravityCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": creds.expires_ms,
        "project_id": creds.project_id,
    }
    if creds.email:
        d["email"] = creds.email
    if creds.client_id:
        d["client_id"] = creds.client_id
    if creds.client_secret:
        d["client_secret"] = creds.client_secret
    return d


def credentials_from_value(value: Any) -> AntigravityCredentials | None:
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
    refresh = value.get("refresh", "")
    expires_ms = value.get("expires_ms")
    project_id = value.get("project_id")
    if not isinstance(access, str) or not isinstance(project_id, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    return AntigravityCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        project_id=project_id,
        email=value.get("email"),
        client_id=value.get("client_id"),
        client_secret=value.get("client_secret"),
    )


def load_credentials() -> AntigravityCredentials | None:
    from core.auth.store import load_auth

    return credentials_from_value(load_auth(ANTIGRAVITY_CONFIG_KEY))


def save_credentials(creds: AntigravityCredentials) -> None:
    from core.auth.store import save_auth

    save_auth(ANTIGRAVITY_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth

    delete_auth(ANTIGRAVITY_CONFIG_KEY)


async def ensure_fresh_credentials(
    *, skew_seconds: int = 300
) -> AntigravityCredentials:
    from core.auth.store import auth_lock

    with auth_lock(ANTIGRAVITY_CONFIG_KEY):
        creds = load_credentials()
        if not creds:
            raise RuntimeError(
                "Google Antigravity is not configured. Run: `hexis auth google-antigravity login`"
            )
        if not needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        if not creds.refresh:
            raise RuntimeError(
                "Google Antigravity credentials expired and no refresh token. Re-login required."
            )
        access, expires_ms = await refresh_access_token(
            creds.refresh,
            client_id=creds.client_id,
            client_secret=creds.client_secret,
        )
        refreshed = AntigravityCredentials(
            access=access,
            refresh=creds.refresh,
            expires_ms=expires_ms,
            project_id=creds.project_id,
            email=creds.email,
            client_id=creds.client_id,
            client_secret=creds.client_secret,
        )
        save_credentials(refreshed)
        return refreshed
