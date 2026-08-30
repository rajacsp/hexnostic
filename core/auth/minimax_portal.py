"""MiniMax Portal OAuth (user-code + PKCE) auth module."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from core.auth.utils import advisory_lock_key, create_state, generate_pkce, now_ms
from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

# Constants (from OpenClaw extensions/minimax-portal-auth/oauth.ts)
MINIMAX_CLIENT_ID = "78257093-7e40-4613-99e0-527b14b39113"
MINIMAX_SCOPE = "group_id profile model.completion"
MINIMAX_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:user_code"

MINIMAX_REGIONS: dict[str, str] = {
    "global": "https://api.minimax.io",
    "cn": "https://api.minimaxi.com",
}
MINIMAX_DEFAULT_REGION = "global"

MINIMAX_PORTAL_CONFIG_KEY = "oauth.minimax_portal"
_MINIMAX_PORTAL_LOCK_KEY = advisory_lock_key(MINIMAX_PORTAL_CONFIG_KEY)


def _base_url(region: str) -> str:
    return MINIMAX_REGIONS.get(region, MINIMAX_REGIONS["global"])


def default_endpoint(region: str) -> str:
    """Return the Anthropic-compatible API endpoint for the given region."""
    return f"{_base_url(region)}/anthropic"


@dataclass(frozen=True)
class MiniMaxPortalCredentials:
    access: str
    refresh: str
    expires_ms: int
    region: str = MINIMAX_DEFAULT_REGION
    resource_url: str | None = None


@dataclass
class UserCodeResponse:
    user_code: str
    verification_uri: str
    expires_in: int
    interval: int
    state: str


async def start_user_code_flow(region: str = MINIMAX_DEFAULT_REGION) -> tuple[UserCodeResponse, str]:
    """Start user-code flow. Returns (response, verifier)."""
    verifier, challenge = generate_pkce()
    state = create_state()
    base = _base_url(region)

    try:
        data = await request_json(
            "minimax_oauth",
            "POST",
            f"{base}/oauth/code",
            headers={"Content-Type": "application/json"},
            json_body={
                "client_id": MINIMAX_CLIENT_ID,
                "scope": MINIMAX_SCOPE,
                "response_type": "code",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": state,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("MiniMax code request", exc)) from exc
    resp_state = data.get("state", "")
    if resp_state != state:
        raise RuntimeError("MiniMax state mismatch (CSRF check failed).")

    return UserCodeResponse(
        user_code=data["user_code"],
        verification_uri=data["verification_uri"],
        expires_in=int(data.get("expired_in", data.get("expires_in", 300))),
        interval=int(data.get("interval", 2)),
        state=state,
    ), verifier


async def poll_for_token(
    user_code: str,
    verifier: str,
    interval_seconds: int,
    expires_in: int,
    region: str = MINIMAX_DEFAULT_REGION,
) -> MiniMaxPortalCredentials:
    """Poll until user authorizes or flow expires."""
    import asyncio

    base = _base_url(region)
    deadline = now_ms() + expires_in * 1000
    interval_ms = max(1000, interval_seconds * 1000)

    while now_ms() < deadline:
        try:
            data = await request_json(
                "minimax_oauth",
                "POST",
                f"{base}/oauth/token",
                headers={"Content-Type": "application/json"},
                json_body={
                    "client_id": MINIMAX_CLIENT_ID,
                    "grant_type": MINIMAX_GRANT_TYPE,
                    "user_code": user_code,
                    "code_verifier": verifier,
                },
                timeout=30.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=True,
            )
        except IntegrationHttpError as exc:
            raise RuntimeError(format_provider_error("MiniMax auth flow", exc)) from exc

        status = data.get("status", "")
        if status == "success" or isinstance(data.get("access_token"), str):
            access = data.get("access_token") or data.get("access")
            refresh = data.get("refresh_token") or data.get("refresh", "")
            # MiniMax uses expired_in (Unix seconds), not ms
            expires_raw = data.get("expired_in") or data.get("expires_in") or data.get("expires_at")
            if isinstance(expires_raw, (int, float)):
                # If value is small enough it's seconds-from-now, else Unix timestamp
                if expires_raw < 1e10:
                    expires_ms = now_ms() + int(expires_raw) * 1000
                else:
                    expires_ms = int(expires_raw) * 1000
            else:
                expires_ms = now_ms() + 3600 * 1000

            return MiniMaxPortalCredentials(
                access=access,
                refresh=refresh,
                expires_ms=expires_ms,
                region=region,
                resource_url=data.get("resource_url"),
            )

        if status == "pending" or data.get("error") == "authorization_pending":
            await asyncio.sleep(interval_ms / 1000)
            continue
        if data.get("error") == "slow_down":
            interval_ms = int(interval_ms * 1.5)
            await asyncio.sleep(interval_ms / 1000)
            continue

        error = data.get("error") or status or "unknown"
        raise RuntimeError(f"MiniMax auth flow failed: {error}")

    raise RuntimeError("MiniMax auth flow timed out.")


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: MiniMaxPortalCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": creds.expires_ms,
        "region": creds.region,
    }
    if creds.resource_url:
        d["resource_url"] = creds.resource_url
    return d


def credentials_from_value(value: Any) -> MiniMaxPortalCredentials | None:
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
    if not isinstance(access, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    return MiniMaxPortalCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        region=value.get("region", MINIMAX_DEFAULT_REGION),
        resource_url=value.get("resource_url"),
    )


def load_credentials() -> MiniMaxPortalCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(MINIMAX_PORTAL_CONFIG_KEY))


def save_credentials(creds: MiniMaxPortalCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(MINIMAX_PORTAL_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(MINIMAX_PORTAL_CONFIG_KEY)


async def ensure_fresh_credentials(*, skew_seconds: int = 300) -> MiniMaxPortalCredentials:
    """MiniMax refresh is not implemented in OpenClaw; re-auth if expired."""
    from core.auth.store import auth_lock
    from core.auth.utils import needs_refresh as _needs_refresh

    with auth_lock(MINIMAX_PORTAL_CONFIG_KEY):
        creds = load_credentials()
        if not creds:
            raise RuntimeError("MiniMax Portal is not configured. Run: `hexis auth minimax-portal login`")
        if not _needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        raise RuntimeError(
            "MiniMax Portal credentials have expired. Run: `hexis auth minimax-portal login`"
        )
