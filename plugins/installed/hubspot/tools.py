"""
Hexis Tools System - HubSpot Integration (A.5)

Tools for listing and retrieving HubSpot CRM deals.
Uses the HubSpot API v3 with a bearer token.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from core.integration_reliability import IntegrationHttpError, request_json
from core.tools.base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from core.tools.api_keys import resolve_api_key
from core.tools.integration_http import integration_error_result

logger = logging.getLogger(__name__)

_BASE_URL = "https://api.hubapi.com"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class ListHubSpotDealsHandler(ToolHandler):
    """List deals from HubSpot CRM."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="hubspot_list_deals",
            description="List deals from HubSpot CRM. Optionally filter by stage and limit results.",
            parameters={
                "type": "object",
                "properties": {
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of deals to return (default 10)",
                    },
                    "stage": {
                        "type": "string",
                        "description": "Filter by deal stage (e.g. 'closedwon', 'appointmentscheduled')",
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="hubspot",
            env_names=("HUBSPOT_API_KEY", "HUBSPOT_ACCESS_TOKEN"),
        )
        if not token:
            return ToolResult.error_result(
                "HubSpot API key not configured. Set HUBSPOT_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        limit = arguments.get("limit", 10)
        params: dict[str, Any] = {
            "limit": limit,
            "properties": "dealname,amount,dealstage,closedate",
        }

        try:
            data = await request_json(
                "hubspot",
                "GET",
                f"{_BASE_URL}/crm/v3/objects/deals",
                headers=_headers(token),
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )

            deals = []
            rows = data.get("results", []) if isinstance(data, dict) else []
            for d in rows:
                props = d.get("properties", {})
                deal = {
                    "id": d.get("id"),
                    "name": props.get("dealname"),
                    "amount": props.get("amount"),
                    "stage": props.get("dealstage"),
                    "close_date": props.get("closedate"),
                }
                stage_filter = arguments.get("stage")
                if stage_filter and deal["stage"] != stage_filter:
                    continue
                deals.append(deal)

            return ToolResult.success_result(
                {"deals": deals, "count": len(deals)},
                display_output=f"Found {len(deals)} deal(s)",
            )
        except IntegrationHttpError as e:
            return integration_error_result("HubSpot", e)
        except Exception as e:
            return ToolResult.error_result(f"HubSpot API error: {e}")


class GetHubSpotDealHandler(ToolHandler):
    """Get details for a specific HubSpot deal."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="hubspot_get_deal",
            description="Get details for a specific HubSpot CRM deal by ID.",
            parameters={
                "type": "object",
                "properties": {
                    "deal_id": {
                        "type": "string",
                        "description": "HubSpot deal ID",
                    },
                },
                "required": ["deal_id"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="hubspot",
            env_names=("HUBSPOT_API_KEY", "HUBSPOT_ACCESS_TOKEN"),
        )
        if not token:
            return ToolResult.error_result(
                "HubSpot API key not configured. Set HUBSPOT_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        deal_id = arguments["deal_id"]
        params = {"properties": "dealname,amount,dealstage,closedate,pipeline,hubspot_owner_id"}

        try:
            data = await request_json(
                "hubspot",
                "GET",
                f"{_BASE_URL}/crm/v3/objects/deals/{deal_id}",
                headers=_headers(token),
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )
            if not isinstance(data, dict):
                data = {}

            props = data.get("properties", {})
            return ToolResult.success_result(
                {
                    "id": data.get("id"),
                    "name": props.get("dealname"),
                    "amount": props.get("amount"),
                    "stage": props.get("dealstage"),
                    "close_date": props.get("closedate"),
                    "pipeline": props.get("pipeline"),
                    "owner_id": props.get("hubspot_owner_id"),
                    "created_at": data.get("createdAt"),
                    "updated_at": data.get("updatedAt"),
                },
                display_output=f"Deal: {props.get('dealname', deal_id)}",
            )
        except IntegrationHttpError as e:
            return integration_error_result("HubSpot", e)
        except Exception as e:
            return ToolResult.error_result(f"HubSpot API error: {e}")


def create_hubspot_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create HubSpot integration tools."""
    return [
        ListHubSpotDealsHandler(api_key_resolver),
        GetHubSpotDealHandler(api_key_resolver),
    ]
