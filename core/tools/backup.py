"""
Hexis Tools - Backup & Disaster Recovery (K.1-K.3)

Tool handlers for database backup, retention management, and config export/import.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from typing import Any

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# K.1: Database Backup
# ---------------------------------------------------------------------------


class DatabaseBackupHandler(ToolHandler):
    """Create a compressed database backup (pg_dump + gzip)."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="database_backup",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Create a compressed PostgreSQL database backup. "
                "Runs pg_dump and compresses with gzip. "
                "Stores to the configured backup directory."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "destination": {
                        "type": "string",
                        "description": (
                            "Backup destination directory path. "
                            "Defaults to config key 'backup.directory' or ~/.hexis/backups/"
                        ),
                    },
                    "label": {
                        "type": "string",
                        "description": "Optional label to include in the backup filename",
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=3,
            requires_approval=True,
            is_read_only=False,
            supports_parallel=False,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result("No database pool available")

        # Get backup directory
        dest = arguments.get("destination", "")
        if not dest:
            try:
                async with pool.acquire() as conn:
                    dest = await conn.fetchval(
                        "SELECT get_config_text('backup.directory', $1)",
                        os.path.expanduser("~/.hexis/backups"),
                    )
            except Exception:
                dest = os.path.expanduser("~/.hexis/backups")

        os.makedirs(dest, exist_ok=True)

        # Build filename
        label = arguments.get("label", "")
        ts = time.strftime("%Y%m%d_%H%M%S")
        label_part = f"_{label}" if label else ""
        filename = f"hexis_backup_{ts}{label_part}.sql.gz"
        filepath = os.path.join(dest, filename)

        # Get DB connection info
        db_host = os.environ.get("POSTGRES_HOST", "127.0.0.1")
        db_port = os.environ.get("POSTGRES_PORT", "43815")
        db_name = os.environ.get("POSTGRES_DB", "hexis_memory")
        db_user = os.environ.get("POSTGRES_USER", "hexis_user")
        db_pass = os.environ.get("POSTGRES_PASSWORD", "hexis_password")

        # Run pg_dump | gzip
        env = os.environ.copy()
        env["PGPASSWORD"] = db_pass

        try:
            with open(filepath, "wb") as f:
                pg_dump = subprocess.Popen(
                    [
                        "pg_dump",
                        "-h", db_host,
                        "-p", db_port,
                        "-U", db_user,
                        "-d", db_name,
                        "--no-owner",
                        "--no-acl",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                gzip_proc = subprocess.Popen(
                    ["gzip"],
                    stdin=pg_dump.stdout,
                    stdout=f,
                    stderr=subprocess.PIPE,
                )
                pg_dump.stdout.close()
                _, gzip_err = gzip_proc.communicate(timeout=300)
                _, pg_err = pg_dump.communicate(timeout=10)

                if pg_dump.returncode != 0:
                    err = (pg_err or b"").decode()[:200]
                    return ToolResult.error_result(f"pg_dump failed: {err}")
                if gzip_proc.returncode != 0:
                    err = (gzip_err or b"").decode()[:200]
                    return ToolResult.error_result(f"gzip failed: {err}")

            size_bytes = os.path.getsize(filepath)
            size_mb = round(size_bytes / (1024 * 1024), 2)

            return ToolResult.success_result({
                "status": "backup_created",
                "path": filepath,
                "size_mb": size_mb,
                "timestamp": ts,
            })

        except subprocess.TimeoutExpired:
            return ToolResult.error_result("Backup timed out (5 min limit)")
        except FileNotFoundError as e:
            return ToolResult.error_result(
                f"Required binary not found: {e}",
                ToolErrorType.MISSING_DEPENDENCY,
            )
        except Exception as e:
            return ToolResult.error_result(f"Backup failed: {e}")


# ---------------------------------------------------------------------------
# K.2: Backup Retention
# ---------------------------------------------------------------------------


class BackupRetentionHandler(ToolHandler):
    """Manage backup retention by cleaning up old backups."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="backup_retention",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Clean up old database backups beyond the retention period. "
                "Deletes backups older than the configured retention days."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Backup directory to clean. Defaults to config.",
                    },
                    "retention_days": {
                        "type": "integer",
                        "description": "Keep backups from the last N days. Defaults to config key 'backup.retention_days' or 7.",
                    },
                    "dry_run": {
                        "type": "boolean",
                        "description": "If true, list files that would be deleted without deleting them.",
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            requires_approval=True,
            is_read_only=False,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None

        # Get directory
        directory = arguments.get("directory", "")
        retention_days = arguments.get("retention_days", 0)
        dry_run = arguments.get("dry_run", False)

        if not directory and pool:
            try:
                async with pool.acquire() as conn:
                    directory = await conn.fetchval(
                        "SELECT get_config_text('backup.directory', $1)",
                        os.path.expanduser("~/.hexis/backups"),
                    )
            except Exception:
                directory = os.path.expanduser("~/.hexis/backups")

        if not directory:
            directory = os.path.expanduser("~/.hexis/backups")

        if not retention_days and pool:
            try:
                async with pool.acquire() as conn:
                    retention_days = await conn.fetchval(
                        "SELECT get_config_int('backup.retention_days', 7)"
                    )
            except Exception:
                retention_days = 7

        if not retention_days:
            retention_days = 7

        if not os.path.isdir(directory):
            return ToolResult.success_result({
                "status": "no_backups",
                "detail": f"Directory does not exist: {directory}",
            })

        # Find backup files older than retention_days
        cutoff = time.time() - (retention_days * 86400)
        to_delete = []
        kept = []

        for f in sorted(os.listdir(directory)):
            if not f.startswith("hexis_backup_") or not f.endswith(".sql.gz"):
                continue
            path = os.path.join(directory, f)
            mtime = os.path.getmtime(path)
            if mtime < cutoff:
                to_delete.append({"file": f, "age_days": round((time.time() - mtime) / 86400, 1)})
            else:
                kept.append(f)

        if not dry_run:
            for item in to_delete:
                try:
                    os.remove(os.path.join(directory, item["file"]))
                except Exception as e:
                    item["error"] = str(e)

        return ToolResult.success_result({
            "status": "dry_run" if dry_run else "cleaned",
            "retention_days": retention_days,
            "deleted": len(to_delete),
            "kept": len(kept),
            "deleted_files": to_delete,
        })


# ---------------------------------------------------------------------------
# K.3: Config Export / Import
# ---------------------------------------------------------------------------


class ConfigExportHandler(ToolHandler):
    """Export all config table entries to JSON for disaster recovery."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="config_export",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Export all configuration entries from the config table to a JSON file. "
                "Useful for disaster recovery and migrating to a new instance."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "output_path": {
                        "type": "string",
                        "description": "Path to write the JSON file. Defaults to ~/.hexis/config_export.json",
                    },
                },
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result("No database pool available")

        output_path = arguments.get("output_path", "")
        if not output_path:
            output_path = os.path.expanduser("~/.hexis/config_export.json")

        try:
            async with pool.acquire() as conn:
                rows = await conn.fetch("SELECT key, value FROM config ORDER BY key")

            config_data = {}
            for row in rows:
                key = row["key"]
                raw_value = row["value"]
                # value column is JSONB, asyncpg returns it as Python types
                config_data[key] = raw_value

            os.makedirs(os.path.dirname(output_path), exist_ok=True)
            with open(output_path, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "hexis_config_export": True,
                        "exported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "entry_count": len(config_data),
                        "entries": config_data,
                    },
                    f,
                    indent=2,
                    default=str,
                )

            return ToolResult.success_result({
                "status": "exported",
                "path": output_path,
                "entry_count": len(config_data),
            })

        except Exception as e:
            return ToolResult.error_result(f"Config export failed: {e}")


class ConfigImportHandler(ToolHandler):
    """Import config entries from a JSON export file."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="config_import",
            internal=True,  # operator/system machinery (#99)
            description=(
                "Import configuration entries from a JSON export file into the config table. "
                "Merges with existing config (upsert). Does NOT import secret values."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "input_path": {
                        "type": "string",
                        "description": "Path to the JSON config export file.",
                    },
                    "dry_run": {
                        "type": "boolean",
                        "description": "If true, show what would be imported without writing.",
                    },
                    "skip_keys": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Config keys to skip during import.",
                    },
                },
                "required": ["input_path"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            requires_approval=True,
            is_read_only=False,
            supports_parallel=False,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result("No database pool available")

        input_path = arguments.get("input_path", "")
        dry_run = arguments.get("dry_run", False)
        skip_keys = set(arguments.get("skip_keys", []))

        if not input_path or not os.path.isfile(input_path):
            return ToolResult.error_result(
                f"File not found: {input_path}",
                ToolErrorType.FILE_NOT_FOUND,
            )

        try:
            with open(input_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            if not isinstance(data, dict) or not data.get("hexis_config_export"):
                return ToolResult.error_result("Not a valid Hexis config export file")

            entries = data.get("entries", {})
            if not isinstance(entries, dict):
                return ToolResult.error_result("Invalid entries format")

            # Filter out sensitive keys
            sensitive_patterns = {"password", "secret", "token", "api_key", "credential"}
            imported = []
            skipped = []

            for key, value in entries.items():
                if key in skip_keys:
                    skipped.append({"key": key, "reason": "in skip_keys"})
                    continue
                key_lower = key.lower()
                if any(p in key_lower for p in sensitive_patterns):
                    skipped.append({"key": key, "reason": "sensitive key"})
                    continue
                imported.append(key)

            if not dry_run:
                async with pool.acquire() as conn:
                    for key in imported:
                        value = entries[key]
                        await conn.execute(
                            """
                            INSERT INTO config (key, value)
                            VALUES ($1, $2::jsonb)
                            ON CONFLICT (key) DO UPDATE SET value = $2::jsonb
                            """,
                            key,
                            json.dumps(value),
                        )

            return ToolResult.success_result({
                "status": "dry_run" if dry_run else "imported",
                "imported_count": len(imported),
                "skipped_count": len(skipped),
                "imported_keys": imported,
                "skipped": skipped,
            })

        except json.JSONDecodeError as e:
            return ToolResult.error_result(f"Invalid JSON: {e}")
        except Exception as e:
            return ToolResult.error_result(f"Config import failed: {e}")


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def create_backup_tools() -> list[ToolHandler]:
    """Create all backup & disaster recovery tool handlers."""
    return [
        DatabaseBackupHandler(),
        BackupRetentionHandler(),
        ConfigExportHandler(),
        ConfigImportHandler(),
    ]
