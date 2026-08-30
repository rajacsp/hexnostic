"""GitHub Copilot OAuth (device code flow) auth module."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from core.auth.utils import advisory_lock_key, needs_refresh, now_ms
from core.integration_reliability import (
    IntegrationHttpError,
    format_provider_error,
    request_json,
)

# Constants (from OpenClaw src/providers/github-copilot-auth.ts + github-copilot.js)
GITHUB_COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98"
GITHUB_DEFAULT_DOMAIN = "github.com"

COPILOT_HEADERS = {
    "User-Agent": "GitHubCopilotChat/0.35.0",
    "Editor-Version": "vscode/1.107.0",
    "Editor-Plugin-Version": "copilot-chat/0.35.0",
    "Copilot-Integration-Id": "vscode-chat",
}

COPILOT_REQUEST_HEADERS = {
    **COPILOT_HEADERS,
    "X-Initiator": "user",
    "Openai-Intent": "conversation-edits",
}

GITHUB_COPILOT_DEFAULT_BASE_URL = "https://api.individual.githubcopilot.com"
GITHUB_COPILOT_CONFIG_KEY = "oauth.github_copilot"
_GITHUB_COPILOT_LOCK_KEY = advisory_lock_key(GITHUB_COPILOT_CONFIG_KEY)


def _urls(domain: str) -> dict[str, str]:
    return {
        "device_code": f"https://{domain}/login/device/code",
        "access_token": f"https://{domain}/login/oauth/access_token",
        "copilot_token": f"https://api.{domain}/copilot_internal/v2/token",
    }


@dataclass(frozen=True)
class GitHubCopilotCredentials:
    github_token: str
    access: str
    expires_ms: int
    base_url: str
    enterprise_domain: str | None = None


def derive_base_url(token: str, enterprise_domain: str | None = None) -> str:
    """Extract proxy-ep from Copilot token, convert proxy.* -> api.*."""
    match = re.search(r"proxy-ep=([^;]+)", token)
    if match:
        proxy_host = match.group(1)
        api_host = re.sub(r"^proxy\.", "api.", proxy_host)
        return f"https://{api_host}"
    if enterprise_domain:
        return f"https://copilot-api.{enterprise_domain}"
    return GITHUB_COPILOT_DEFAULT_BASE_URL


# ---------------------------------------------------------------------------
# Device code flow
# ---------------------------------------------------------------------------

@dataclass
class DeviceCodeResponse:
    device_code: str
    user_code: str
    verification_uri: str
    interval: int
    expires_in: int


async def start_device_flow(domain: str = GITHUB_DEFAULT_DOMAIN) -> DeviceCodeResponse:
    urls = _urls(domain)
    try:
        data = await request_json(
            "github_copilot_oauth",
            "POST",
            urls["device_code"],
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "GitHubCopilotChat/0.35.0",
            },
            json_body={"client_id": GITHUB_COPILOT_CLIENT_ID, "scope": "read:user"},
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
            retry_unsafe_methods=True,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("GitHub device code", exc)) from exc
    return DeviceCodeResponse(
        device_code=data["device_code"],
        user_code=data["user_code"],
        verification_uri=data["verification_uri"],
        interval=int(data.get("interval", 5)),
        expires_in=int(data.get("expires_in", 900)),
    )


async def poll_for_github_token(
    domain: str,
    device_code: str,
    interval_seconds: int,
    expires_in: int,
) -> str:
    """Poll until the user authorizes or the flow expires."""
    import asyncio

    urls = _urls(domain)
    deadline = now_ms() + expires_in * 1000
    interval_ms = max(1000, interval_seconds * 1000)

    while now_ms() < deadline:
        try:
            data = await request_json(
                "github_copilot_oauth",
                "POST",
                urls["access_token"],
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "GitHubCopilotChat/0.35.0",
                },
                json_body={
                    "client_id": GITHUB_COPILOT_CLIENT_ID,
                    "device_code": device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                },
                timeout=30.0,
                attempts=3,
                max_delay=10.0,
                retry_unsafe_methods=True,
            )
        except IntegrationHttpError as exc:
            raise RuntimeError(format_provider_error("GitHub device flow", exc)) from exc
        if isinstance(data.get("access_token"), str):
            return data["access_token"]

        error = data.get("error", "")
        if error == "authorization_pending":
            await asyncio.sleep(interval_ms / 1000)
            continue
        if error == "slow_down":
            interval_ms += 5000
            await asyncio.sleep(interval_ms / 1000)
            continue
        raise RuntimeError(f"GitHub device flow failed: {error}")

    raise RuntimeError("GitHub device flow timed out.")


async def exchange_github_for_copilot(
    github_token: str,
    enterprise_domain: str | None = None,
) -> GitHubCopilotCredentials:
    """Exchange a GitHub token for a Copilot internal token."""
    domain = enterprise_domain or GITHUB_DEFAULT_DOMAIN
    urls = _urls(domain)
    try:
        data = await request_json(
            "github_copilot",
            "GET",
            urls["copilot_token"],
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {github_token}",
                **COPILOT_HEADERS,
            },
            timeout=30.0,
            attempts=3,
            max_delay=10.0,
        )
    except IntegrationHttpError as exc:
        raise RuntimeError(format_provider_error("Copilot token exchange", exc)) from exc
    token = data.get("token")
    expires_at = data.get("expires_at")
    if not isinstance(token, str) or not isinstance(expires_at, (int, float)):
        raise RuntimeError("Invalid Copilot token response fields.")

    # expires_at is Unix seconds; convert to ms with 5-min buffer
    expires_ms = int(expires_at) * 1000 - 5 * 60 * 1000
    base_url = derive_base_url(token, enterprise_domain)

    return GitHubCopilotCredentials(
        github_token=github_token,
        access=token,
        expires_ms=expires_ms,
        base_url=base_url,
        enterprise_domain=enterprise_domain,
    )


# ---------------------------------------------------------------------------
# Persistence (filesystem – survives DB resets)
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: GitHubCopilotCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "github_token": creds.github_token,
        "access": creds.access,
        "expires_ms": creds.expires_ms,
        "base_url": creds.base_url,
    }
    if creds.enterprise_domain:
        d["enterprise_domain"] = creds.enterprise_domain
    return d


def credentials_from_value(value: Any) -> GitHubCopilotCredentials | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            return None
    if not isinstance(value, dict):
        return None
    github_token = value.get("github_token")
    access = value.get("access")
    expires_ms = value.get("expires_ms")
    base_url = value.get("base_url", GITHUB_COPILOT_DEFAULT_BASE_URL)
    if not isinstance(github_token, str) or not isinstance(access, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    return GitHubCopilotCredentials(
        github_token=github_token,
        access=access,
        expires_ms=int(expires_ms),
        base_url=base_url,
        enterprise_domain=value.get("enterprise_domain"),
    )


def load_credentials() -> GitHubCopilotCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(GITHUB_COPILOT_CONFIG_KEY))


def save_credentials(creds: GitHubCopilotCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(GITHUB_COPILOT_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(GITHUB_COPILOT_CONFIG_KEY)


async def ensure_fresh_credentials(*, skew_seconds: int = 300) -> GitHubCopilotCredentials:
    """Refresh the Copilot token using the stored GitHub token if expired."""
    from core.auth.store import auth_lock

    with auth_lock(GITHUB_COPILOT_CONFIG_KEY):
        creds = load_credentials()
        if not creds:
            raise RuntimeError("GitHub Copilot is not configured. Run: `hexis auth github-copilot login`")
        if not needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        refreshed = await exchange_github_for_copilot(creds.github_token, creds.enterprise_domain)
        save_credentials(refreshed)
        return refreshed
