"""
Hexis Tools System - Fathom Meeting Transcript Integration (E.7)

Tools for fetching and ingesting meeting transcripts from Fathom.
Uses the Fathom API v1 with a bearer token.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Callable, TYPE_CHECKING

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

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)

_BASE_URL = "https://api.fathom.video/v1"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class FetchFathomTranscriptsHandler(ToolHandler):
    """Fetch recent meeting recordings from Fathom."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="fathom_transcripts",
            description=(
                "Fetch recent meeting recordings from Fathom. "
                "Returns a list of recordings with id, title, date, duration, "
                "attendees, and transcript URL."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of recordings to return (default 10).",
                        "default": 10,
                    },
                    "since_days": {
                        "type": "integer",
                        "description": "Only return recordings from the last N days (default 7).",
                        "default": 7,
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="fathom",
            env_names=("FATHOM_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Fathom API key not configured. Set FATHOM_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        limit = arguments.get("limit", 10)
        since_days = arguments.get("since_days", 7)

        # Build query params
        from datetime import datetime, timedelta, timezone

        since_dt = datetime.now(timezone.utc) - timedelta(days=since_days)
        params: dict[str, Any] = {
            "limit": limit,
            "after": since_dt.isoformat(),
        }

        try:
            data = await request_json(
                "fathom",
                "GET",
                f"{_BASE_URL}/recordings",
                headers=_headers(token),
                params=params,
                timeout=15.0,
                attempts=3,
                max_delay=10.0,
            )

            recordings = (
                data if isinstance(data, list)
                else data.get("recordings", []) if isinstance(data, dict)
                else []
            )
            formatted = []
            for rec in recordings:
                formatted.append({
                    "id": rec.get("id"),
                    "title": rec.get("title"),
                    "date": rec.get("date") or rec.get("created_at"),
                    "duration": rec.get("duration"),
                    "attendees": rec.get("attendees", []),
                    "transcript_url": rec.get("transcript_url"),
                })

            return ToolResult.success_result(
                {"recordings": formatted, "count": len(formatted)},
                display_output=f"Found {len(formatted)} Fathom recording(s)",
            )
        except IntegrationHttpError as e:
            return integration_error_result("Fathom", e)
        except Exception as e:
            return ToolResult.error_result(f"Fathom API error: {e}")


class IngestFathomTranscriptHandler(ToolHandler):
    """Ingest a specific Fathom transcript as an episodic memory."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="fathom_ingest",
            description=(
                "Fetch and ingest a specific Fathom meeting transcript. "
                "Stores the transcript as an episodic memory with source attribution "
                "and extracts attendees into the contacts CRM."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "recording_id": {
                        "type": "string",
                        "description": "Fathom recording ID to ingest.",
                    },
                },
                "required": ["recording_id"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=4,
            is_read_only=False,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="fathom",
            env_names=("FATHOM_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Fathom API key not configured. Set FATHOM_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        recording_id = arguments["recording_id"]

        try:
            # Fetch transcript
            transcript_data = await request_json(
                "fathom",
                "GET",
                f"{_BASE_URL}/recordings/{recording_id}/transcript",
                headers=_headers(token),
                timeout=30.0,
                attempts=3,
                max_delay=10.0,
            )
            if not isinstance(transcript_data, dict):
                transcript_data = {}

            # Extract transcript text and metadata
            transcript_text = transcript_data.get("transcript") or transcript_data.get("text", "")
            title = transcript_data.get("title", f"Meeting {recording_id}")
            attendees = transcript_data.get("attendees", [])
            date = transcript_data.get("date") or transcript_data.get("created_at")
            duration = transcript_data.get("duration")

            if not transcript_text:
                return ToolResult.error_result(
                    f"No transcript content found for recording {recording_id}"
                )

            # Store as episodic memory
            pool: asyncpg.Pool = context.registry.pool
            source_attribution = json.dumps({
                "kind": "fathom",
                "recording_id": recording_id,
                "title": title,
                "date": date,
                "duration": duration,
                "attendees": attendees,
            })

            memory_content = f"Meeting: {title}\n\n{transcript_text}"

            memory_id = await pool.fetchval(
                """SELECT create_episodic_memory(
                       p_content := $1,
                       p_importance := 0.7,
                       p_source_attribution := $2::jsonb,
                       p_trust_level := 0.8
                   )""",
                memory_content,
                source_attribution,
            )

            # Upsert attendees as contacts
            contacts_created = 0
            contacts_updated = 0
            for att in attendees:
                name = att.get("name", "") if isinstance(att, dict) else str(att)
                email = att.get("email", "") if isinstance(att, dict) else ""

                if not name and not email:
                    continue

                # The DB owns the upsert (db/65): by email when we have one,
                # approximate-by-name otherwise.
                if email:
                    upsert_raw = await pool.fetchval(
                        "SELECT upsert_contact($1, $2, 'fathom')", name, email
                    )
                else:
                    upsert_raw = await pool.fetchval(
                        "SELECT upsert_contact_by_name($1, 'fathom')", name
                    )
                upsert = json.loads(upsert_raw) if isinstance(upsert_raw, str) else (upsert_raw or {})
                if upsert.get("created"):
                    contacts_created += 1
                elif "id" in upsert:
                    contacts_updated += 1

            return ToolResult.success_result(
                {
                    "memory_id": memory_id,
                    "recording_id": recording_id,
                    "title": title,
                    "transcript_length": len(transcript_text),
                    "contacts_created": contacts_created,
                    "contacts_updated": contacts_updated,
                },
                display_output=(
                    f"Ingested transcript '{title}' as memory #{memory_id}. "
                    f"Contacts: {contacts_created} new, {contacts_updated} updated."
                ),
            )
        except IntegrationHttpError as e:
            return integration_error_result("Fathom", e)
        except Exception as e:
            return ToolResult.error_result(f"Fathom API error: {e}")


def create_fathom_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Fathom meeting transcript integration tools."""
    return [
        FetchFathomTranscriptsHandler(api_key_resolver),
        IngestFathomTranscriptHandler(api_key_resolver),
    ]
