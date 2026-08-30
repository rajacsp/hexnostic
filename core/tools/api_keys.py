"""Helpers for resolving tool API keys from resolver, tool config, and env."""

from __future__ import annotations

import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .base import ToolExecutionContext


async def resolve_api_key(
    context: "ToolExecutionContext",
    *,
    explicit_resolver=None,
    config_key: str | None = None,
    env_names: tuple[str, ...] = (),
) -> str | None:
    """Resolve an API key in priority order:

    1) Explicit resolver passed to the tool handler
    2) Tools config API key map (`tools.api_keys`)
    3) Environment variables
    """
    if explicit_resolver is not None:
        try:
            value = explicit_resolver()
            if value:
                return str(value)
        except Exception:
            pass

    if config_key and context.registry is not None:
        try:
            config = await context.registry.get_config()
            value = config.get_api_key(config_key)
            if value:
                return str(value)
        except Exception:
            pass

    for name in env_names:
        value = os.getenv(name)
        if value:
            return value

    return None

