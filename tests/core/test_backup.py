"""Tests for backup & disaster recovery tools (K.1-K.3)."""

import json
import os
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.backup import (
    BackupRetentionHandler,
    ConfigExportHandler,
    ConfigImportHandler,
    DatabaseBackupHandler,
    create_backup_tools,
)
from core.tools.base import ToolContext, ToolExecutionContext

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _make_pool(conn=None):
    """Create a mock pool with properly working async context manager."""
    pool = MagicMock()
    if conn is None:
        conn = AsyncMock()

    @asynccontextmanager
    async def acquire():
        yield conn

    pool.acquire = acquire
    return pool, conn


def _make_context(pool=None):
    registry = MagicMock()
    registry.pool = pool
    return ToolExecutionContext(
        tool_context=ToolContext.HEARTBEAT,
        call_id="test-call",
        registry=registry,
    )


# ============================================================================
# Factory
# ============================================================================


class TestBackupFactory:
    def test_factory_returns_all_handlers(self):
        tools = create_backup_tools()
        assert len(tools) == 4
        names = {t.spec.name for t in tools}
        assert names == {"database_backup", "backup_retention", "config_export", "config_import"}

    def test_all_have_specs(self):
        for tool in create_backup_tools():
            spec = tool.spec
            assert spec.name
            assert spec.description
            assert spec.parameters


# ============================================================================
# K.1: Database Backup
# ============================================================================


class TestDatabaseBackup:
    def test_spec(self):
        h = DatabaseBackupHandler()
        assert h.spec.name == "database_backup"
        assert h.spec.requires_approval is True
        assert h.spec.is_read_only is False
        assert h.spec.energy_cost == 3

    async def test_no_pool(self):
        ctx = _make_context(pool=None)
        result = await DatabaseBackupHandler().execute({}, ctx)
        assert not result.success
        assert "pool" in result.error.lower()

    @patch("core.tools.backup.subprocess.Popen")
    async def test_successful_backup(self, mock_popen):
        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=None)
        pool, _ = _make_pool(conn)

        # Mock pg_dump and gzip processes
        pg_proc = MagicMock()
        pg_proc.stdout = MagicMock()
        pg_proc.stdout.close = MagicMock()
        pg_proc.communicate = MagicMock(return_value=(b"", b""))
        pg_proc.returncode = 0

        gzip_proc = MagicMock()
        gzip_proc.communicate = MagicMock(return_value=(b"", b""))
        gzip_proc.returncode = 0

        mock_popen.side_effect = [pg_proc, gzip_proc]

        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = _make_context(pool=pool)
            result = await DatabaseBackupHandler().execute(
                {"destination": tmpdir}, ctx
            )
            assert result.success
            assert result.output["status"] == "backup_created"
            assert tmpdir in result.output["path"]

    @patch("core.tools.backup.subprocess.Popen")
    async def test_pg_dump_failure(self, mock_popen):
        pool = AsyncMock()
        pg_proc = MagicMock()
        pg_proc.stdout = MagicMock()
        pg_proc.stdout.close = MagicMock()
        pg_proc.communicate = MagicMock(return_value=(b"", b"pg_dump error"))
        pg_proc.returncode = 1

        gzip_proc = MagicMock()
        gzip_proc.communicate = MagicMock(return_value=(b"", b""))
        gzip_proc.returncode = 0

        mock_popen.side_effect = [pg_proc, gzip_proc]

        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = _make_context(pool=pool)
            result = await DatabaseBackupHandler().execute(
                {"destination": tmpdir}, ctx
            )
            assert not result.success
            assert "pg_dump" in result.error

    @patch("core.tools.backup.subprocess.Popen", side_effect=FileNotFoundError("pg_dump"))
    async def test_missing_binary(self, mock_popen):
        pool = AsyncMock()
        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = _make_context(pool=pool)
            result = await DatabaseBackupHandler().execute(
                {"destination": tmpdir}, ctx
            )
            assert not result.success

    async def test_with_label(self):
        h = DatabaseBackupHandler()
        # Just verify the spec accepts label parameter
        assert "label" in h.spec.parameters["properties"]


# ============================================================================
# K.2: Backup Retention
# ============================================================================


class TestBackupRetention:
    def test_spec(self):
        h = BackupRetentionHandler()
        assert h.spec.name == "backup_retention"
        assert h.spec.requires_approval is True

    async def test_empty_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = _make_context()
            result = await BackupRetentionHandler().execute(
                {"directory": tmpdir, "retention_days": 7}, ctx
            )
            assert result.success
            assert result.output["deleted"] == 0
            assert result.output["kept"] == 0

    async def test_nonexistent_directory(self):
        ctx = _make_context()
        result = await BackupRetentionHandler().execute(
            {"directory": "/nonexistent/path", "retention_days": 7}, ctx
        )
        assert result.success
        assert result.output["status"] == "no_backups"

    async def test_deletes_old_backups(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create an old backup
            old_file = os.path.join(tmpdir, "hexis_backup_20200101_000000.sql.gz")
            with open(old_file, "w") as f:
                f.write("old")
            # Set mtime to 30 days ago
            old_time = time.time() - (30 * 86400)
            os.utime(old_file, (old_time, old_time))

            # Create a recent backup
            new_file = os.path.join(tmpdir, "hexis_backup_20260213_000000.sql.gz")
            with open(new_file, "w") as f:
                f.write("new")

            ctx = _make_context()
            result = await BackupRetentionHandler().execute(
                {"directory": tmpdir, "retention_days": 7}, ctx
            )
            assert result.success
            assert result.output["deleted"] == 1
            assert result.output["kept"] == 1
            assert not os.path.exists(old_file)
            assert os.path.exists(new_file)

    async def test_dry_run(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            old_file = os.path.join(tmpdir, "hexis_backup_20200101_000000.sql.gz")
            with open(old_file, "w") as f:
                f.write("old")
            old_time = time.time() - (30 * 86400)
            os.utime(old_file, (old_time, old_time))

            ctx = _make_context()
            result = await BackupRetentionHandler().execute(
                {"directory": tmpdir, "retention_days": 7, "dry_run": True}, ctx
            )
            assert result.success
            assert result.output["status"] == "dry_run"
            assert result.output["deleted"] == 1
            # File should still exist
            assert os.path.exists(old_file)

    async def test_ignores_non_backup_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create non-backup file
            other_file = os.path.join(tmpdir, "notes.txt")
            with open(other_file, "w") as f:
                f.write("keep me")
            old_time = time.time() - (30 * 86400)
            os.utime(other_file, (old_time, old_time))

            ctx = _make_context()
            result = await BackupRetentionHandler().execute(
                {"directory": tmpdir, "retention_days": 7}, ctx
            )
            assert result.success
            assert result.output["deleted"] == 0
            assert os.path.exists(other_file)


# ============================================================================
# K.3: Config Export
# ============================================================================


class TestConfigExport:
    def test_spec(self):
        h = ConfigExportHandler()
        assert h.spec.name == "config_export"
        assert h.spec.is_read_only is True

    async def test_no_pool(self):
        ctx = _make_context(pool=None)
        result = await ConfigExportHandler().execute({}, ctx)
        assert not result.success

    async def test_exports_config(self):
        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[
            {"key": "agent.name", "value": "Hexis"},
            {"key": "heartbeat.interval", "value": 300},
        ])
        pool, _ = _make_pool(conn)

        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = os.path.join(tmpdir, "config.json")
            ctx = _make_context(pool=pool)
            result = await ConfigExportHandler().execute(
                {"output_path": output_path}, ctx
            )
            assert result.success
            assert result.output["entry_count"] == 2

            # Verify file contents
            with open(output_path) as f:
                data = json.load(f)
            assert data["hexis_config_export"] is True
            assert data["entry_count"] == 2
            assert "agent.name" in data["entries"]


# ============================================================================
# K.3: Config Import
# ============================================================================


class TestConfigImport:
    def test_spec(self):
        h = ConfigImportHandler()
        assert h.spec.name == "config_import"
        assert h.spec.requires_approval is True
        assert h.spec.is_read_only is False

    async def test_file_not_found(self):
        ctx = _make_context(pool=AsyncMock())
        result = await ConfigImportHandler().execute(
            {"input_path": "/nonexistent/file.json"}, ctx
        )
        assert not result.success
        assert "not found" in result.error.lower()

    async def test_invalid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("not json{")
            path = f.name

        try:
            ctx = _make_context(pool=AsyncMock())
            result = await ConfigImportHandler().execute(
                {"input_path": path}, ctx
            )
            assert not result.success
            assert "json" in result.error.lower()
        finally:
            os.unlink(path)

    async def test_not_valid_export(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"random": "data"}, f)
            path = f.name

        try:
            ctx = _make_context(pool=AsyncMock())
            result = await ConfigImportHandler().execute(
                {"input_path": path}, ctx
            )
            assert not result.success
            assert "valid" in result.error.lower()
        finally:
            os.unlink(path)

    async def test_imports_config(self):
        conn = AsyncMock()
        conn.execute = AsyncMock()
        pool, _ = _make_pool(conn)

        export_data = {
            "hexis_config_export": True,
            "exported_at": "2026-01-01T00:00:00Z",
            "entry_count": 2,
            "entries": {
                "agent.name": "Hexis",
                "heartbeat.interval": 300,
            },
        }

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(export_data, f)
            path = f.name

        try:
            ctx = _make_context(pool=pool)
            result = await ConfigImportHandler().execute(
                {"input_path": path}, ctx
            )
            assert result.success
            assert result.output["imported_count"] == 2
            assert conn.execute.call_count == 2
        finally:
            os.unlink(path)

    async def test_skips_sensitive_keys(self):
        conn = AsyncMock()
        conn.execute = AsyncMock()
        pool, _ = _make_pool(conn)

        export_data = {
            "hexis_config_export": True,
            "exported_at": "2026-01-01T00:00:00Z",
            "entry_count": 3,
            "entries": {
                "agent.name": "Hexis",
                "api_key.openai": "sk-secret",
                "db.password": "secret123",
            },
        }

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(export_data, f)
            path = f.name

        try:
            ctx = _make_context(pool=pool)
            result = await ConfigImportHandler().execute(
                {"input_path": path}, ctx
            )
            assert result.success
            assert result.output["imported_count"] == 1  # Only agent.name
            assert result.output["skipped_count"] == 2
        finally:
            os.unlink(path)

    async def test_dry_run(self):
        conn = AsyncMock()
        pool, _ = _make_pool(conn)

        export_data = {
            "hexis_config_export": True,
            "exported_at": "2026-01-01T00:00:00Z",
            "entry_count": 1,
            "entries": {"agent.name": "Hexis"},
        }

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(export_data, f)
            path = f.name

        try:
            ctx = _make_context(pool=pool)
            result = await ConfigImportHandler().execute(
                {"input_path": path, "dry_run": True}, ctx
            )
            assert result.success
            assert result.output["status"] == "dry_run"
            conn.execute.assert_not_called()
        finally:
            os.unlink(path)

    async def test_skip_keys(self):
        conn = AsyncMock()
        conn.execute = AsyncMock()
        pool, _ = _make_pool(conn)

        export_data = {
            "hexis_config_export": True,
            "exported_at": "2026-01-01T00:00:00Z",
            "entry_count": 2,
            "entries": {
                "agent.name": "Hexis",
                "heartbeat.interval": 300,
            },
        }

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(export_data, f)
            path = f.name

        try:
            ctx = _make_context(pool=pool)
            result = await ConfigImportHandler().execute(
                {"input_path": path, "skip_keys": ["heartbeat.interval"]}, ctx
            )
            assert result.success
            assert result.output["imported_count"] == 1
            assert result.output["skipped_count"] == 1
        finally:
            os.unlink(path)
