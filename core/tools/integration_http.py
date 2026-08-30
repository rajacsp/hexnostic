"""Tool-facing helpers for reliable external HTTP integrations."""

from __future__ import annotations

from core.integration_reliability import IntegrationHttpError, format_provider_error

from .base import ToolErrorType, ToolResult


def integration_tool_error_type(exc: IntegrationHttpError) -> ToolErrorType:
    if exc.error_kind == "auth_failed":
        return ToolErrorType.AUTH_FAILED
    if exc.error_kind == "rate_limited":
        return ToolErrorType.RATE_LIMITED
    if exc.error_kind == "timeout":
        return ToolErrorType.FETCH_TIMEOUT
    if exc.error_kind == "network":
        return ToolErrorType.NETWORK_ERROR
    return ToolErrorType.HTTP_ERROR


def integration_error_result(provider_label: str, exc: IntegrationHttpError) -> ToolResult:
    return ToolResult.error_result(
        format_provider_error(provider_label, exc),
        integration_tool_error_type(exc),
    )
