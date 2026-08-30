"""OpenAI Codex (ChatGPT subscription) OAuth flow.

Moved from ``core/openai_codex_oauth.py``; now uses shared auth utils.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any

from core.auth.utils import _b64url_decode, create_state, generate_pkce  # noqa: F401 – re-exported
from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

# ---------------------------------------------------------------------------
# Constants (mirrored from OpenClaw/pi-ai)
# ---------------------------------------------------------------------------

OPENAI_CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
OPENAI_CODEX_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
OPENAI_CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
OPENAI_CODEX_REDIRECT_URI = "http://localhost:1455/auth/callback"
OPENAI_CODEX_MODELS_URL = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
OPENAI_CODEX_SCOPE = "openid profile email offline_access"
OPENAI_CODEX_ORIGINATOR = "pi"

OPENAI_AUTH_JWT_CLAIM_PATH = "https://api.openai.com/auth"

OPENAI_CODEX_OAUTH_CONFIG_KEY = "oauth.openai_codex"

_OPENAI_CODEX_OAUTH_LOCK_KEY = __import__("zlib").crc32(
    OPENAI_CODEX_OAUTH_CONFIG_KEY.encode("utf-8")
)


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class OpenAICodexCredentials:
    access: str
    refresh: str
    expires_ms: int
    account_id: str


# ---------------------------------------------------------------------------
# URL / JWT helpers
# ---------------------------------------------------------------------------

def build_authorize_url(
    *,
    challenge: str,
    state: str,
    redirect_uri: str = OPENAI_CODEX_REDIRECT_URI,
    originator: str = OPENAI_CODEX_ORIGINATOR,
) -> str:
    from urllib.parse import urlencode

    params = {
        "response_type": "code",
        "client_id": OPENAI_CODEX_CLIENT_ID,
        "redirect_uri": redirect_uri,
        "scope": OPENAI_CODEX_SCOPE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "originator": originator,
    }
    return f"{OPENAI_CODEX_AUTHORIZE_URL}?{urlencode(params)}"


def parse_authorization_input(value: str) -> tuple[str | None, str | None]:
    """Accept full redirect URL, ``code#state``, querystring, or raw code."""
    v = (value or "").strip()
    if not v:
        return None, None

    try:
        from urllib.parse import parse_qs, urlparse

        parsed = urlparse(v)
        if parsed.scheme and parsed.netloc:
            qs = parse_qs(parsed.query)
            code = (qs.get("code") or [None])[0]
            state = (qs.get("state") or [None])[0]
            return code, state
    except Exception:
        pass

    if "#" in v:
        code, st = v.split("#", 1)
        return code or None, st or None

    if "code=" in v:
        try:
            from urllib.parse import parse_qs

            qs = parse_qs(v)
            code = (qs.get("code") or [None])[0]
            state = (qs.get("state") or [None])[0]
            return code, state
        except Exception:
            pass

    return v, None


def decode_jwt_payload(token: str) -> dict[str, Any] | None:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        payload = _b64url_decode(parts[1])
        return json.loads(payload.decode("utf-8"))
    except Exception:
        return None


def extract_account_id(access_token: str) -> str | None:
    payload = decode_jwt_payload(access_token)
    auth = payload.get(OPENAI_AUTH_JWT_CLAIM_PATH) if isinstance(payload, dict) else None
    account_id = auth.get("chatgpt_account_id") if isinstance(auth, dict) else None
    return account_id if isinstance(account_id, str) and account_id else None


# ---------------------------------------------------------------------------
# Token exchange / refresh
# ---------------------------------------------------------------------------

async def exchange_authorization_code(
    *,
    code: str,
    verifier: str,
    redirect_uri: str = OPENAI_CODEX_REDIRECT_URI,
) -> OpenAICodexCredentials:
    try:
        data = await request_json(
            "openai_codex_oauth",
            "POST",
            OPENAI_CODEX_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "grant_type": "authorization_code",
                "client_id": OPENAI_CODEX_CLIENT_ID,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect_uri,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("OpenAI Codex token exchange", exc)) from exc
    access = data.get("access_token")
    refresh = data.get("refresh_token")
    expires_in = data.get("expires_in")
    if not isinstance(access, str) or not isinstance(refresh, str) or not isinstance(expires_in, (int, float)):
        raise RuntimeError("OpenAI Codex token exchange failed: missing fields in response.")

    account_id = extract_account_id(access)
    if not account_id:
        raise RuntimeError("OpenAI Codex token exchange failed: could not extract account id from token.")

    now_ms = int(time.time() * 1000)
    return OpenAICodexCredentials(
        access=access,
        refresh=refresh,
        expires_ms=now_ms + int(expires_in * 1000),
        account_id=account_id,
    )


async def refresh_openai_codex_token(refresh_token: str) -> OpenAICodexCredentials:
    try:
        data = await request_json(
            "openai_codex_oauth",
            "POST",
            OPENAI_CODEX_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": OPENAI_CODEX_CLIENT_ID,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("OpenAI Codex token refresh", exc)) from exc
    access = data.get("access_token")
    refresh = data.get("refresh_token")
    expires_in = data.get("expires_in")
    if not isinstance(access, str) or not isinstance(refresh, str) or not isinstance(expires_in, (int, float)):
        raise RuntimeError("OpenAI Codex token refresh failed: missing fields in response.")

    account_id = extract_account_id(access)
    if not account_id:
        raise RuntimeError("OpenAI Codex token refresh failed: could not extract account id from token.")

    now_ms = int(time.time() * 1000)
    return OpenAICodexCredentials(
        access=access,
        refresh=refresh,
        expires_ms=now_ms + int(expires_in * 1000),
        account_id=account_id,
    )


async def list_openai_codex_models(
    creds: OpenAICodexCredentials | None = None,
) -> list[str]:
    """List picker-visible models from the authenticated Codex workspace."""
    if creds is None:
        creds = await ensure_fresh_openai_codex_credentials(skew_seconds=0)
    try:
        data = await request_json(
            "openai_codex",
            "GET",
            OPENAI_CODEX_MODELS_URL,
            headers={
                "Authorization": f"Bearer {creds.access}",
                "ChatGPT-Account-ID": creds.account_id,
                "Accept": "application/json",
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("OpenAI Codex model discovery", exc)) from exc
    rows = data.get("models") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        raise RuntimeError("OpenAI Codex model discovery response was missing models.")

    models: list[str] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        if str(row.get("visibility") or "list").lower() != "list":
            continue
        if row.get("show_in_picker") is False or row.get("supported_in_api") is False:
            continue
        model = row.get("slug") or row.get("id")
        if isinstance(model, str) and model and model not in seen:
            seen.add(model)
            models.append(model)
    if not models:
        raise RuntimeError("OpenAI Codex model discovery returned no usable models.")
    return models


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: OpenAICodexCredentials) -> dict[str, Any]:
    return {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": int(creds.expires_ms),
        "account_id": creds.account_id,
    }


def credentials_from_value(value: Any) -> OpenAICodexCredentials | None:
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
    expires_ms = value.get("expires_ms") or value.get("expires")
    account_id = value.get("account_id") or value.get("accountId")

    if not isinstance(access, str) or not isinstance(refresh, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    if not isinstance(account_id, str) or not account_id:
        account_id = extract_account_id(access) or ""
    if not account_id:
        return None

    return OpenAICodexCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        account_id=account_id,
    )


def load_openai_codex_credentials() -> OpenAICodexCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(OPENAI_CODEX_OAUTH_CONFIG_KEY))


def save_openai_codex_credentials(creds: OpenAICodexCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(OPENAI_CODEX_OAUTH_CONFIG_KEY, credentials_to_dict(creds))


def delete_openai_codex_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(OPENAI_CODEX_OAUTH_CONFIG_KEY)


async def ensure_fresh_openai_codex_credentials(
    *,
    skew_seconds: int = 300,
) -> OpenAICodexCredentials:
    """Return valid credentials, refreshing under file lock if needed."""
    from core.auth.store import auth_lock

    with auth_lock(OPENAI_CODEX_OAUTH_CONFIG_KEY):
        creds = load_openai_codex_credentials()
        if not creds:
            raise RuntimeError(
                "OpenAI Codex OAuth is not configured. Run: `hexis auth openai-codex login`"
            )

        now_ms = int(time.time() * 1000)
        if creds.expires_ms > now_ms + skew_seconds * 1000:
            return creds

        refreshed = await refresh_openai_codex_token(creds.refresh)
        save_openai_codex_credentials(refreshed)
        return refreshed
