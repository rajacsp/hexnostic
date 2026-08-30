"""Artifact ingestion jobs (migration 0120): uploaded bytes are preserved
first, then a durable job re-reads them through the pipeline."""

from __future__ import annotations

import hashlib
import json
import os

import pytest

from services.ingest import Config
from services.ingest.jobs import run_ingestion_jobs_step
from tests.utils import _db_dsn, get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _j(value):
    return json.loads(value) if isinstance(value, str) else value


async def test_artifact_job_reads_preserved_bytes(db_pool, monkeypatch):
    marker = get_test_identifier("artifactjob")
    raw = f"# Uploaded {marker}\n\nContent that arrived as a file upload.".encode()
    sha = hashlib.sha256(raw).hexdigest()
    seen: dict[str, object] = {}

    async with db_pool.acquire() as conn:
        artifact = _j(await conn.fetchval(
            "SELECT upsert_source_artifact($1, 'database', $2::bytea, NULL, NULL, $3, 'text/markdown')",
            sha, raw, f"{marker}.md",
        ))
        job_id = await conn.fetchval(
            "SELECT enqueue_ingestion_job('artifact', $1::jsonb, NULL, $2)",
            json.dumps({
                "artifact_id": artifact["artifact_id"],
                "filename": f"{marker}.md",
                "mode": "fast",
                "acquisition": "user",
            }),
            f"artifact:{sha}",
        )

    async def fake_ingest_file(self, file_path):
        seen["name"] = file_path.name
        seen["bytes"] = file_path.read_bytes()
        seen["acquisition"] = self.config.acquisition
        return 3

    from services.ingest.pipeline import IngestionPipeline

    monkeypatch.setattr(IngestionPipeline, "ingest_file", fake_ingest_file)

    config = Config(
        dsn=_db_dsn(os.environ.get("POSTGRES_DB")),
        llm_config={"provider": "openai", "model": "stub", "api_key": "stub"},
        verbose=False,
    )
    try:
        handled = await run_ingestion_jobs_step(db_pool, config_override=config)
        assert handled >= 1
        assert seen["name"] == f"{marker}.md"
        assert seen["bytes"] == raw
        assert seen["acquisition"] == "user"

        async with db_pool.acquire() as conn:
            job = await conn.fetchrow(
                "SELECT status, result FROM ingestion_jobs WHERE id = $1::uuid", job_id
            )
        assert job["status"] == "completed"
        result = _j(job["result"])
        assert result["memories_created"] == 3
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM ingestion_jobs WHERE id = $1::uuid", job_id)
            await conn.execute("DELETE FROM source_artifacts WHERE sha256 = $1", sha)


async def test_connector_shaped_job_infers_connector_acquisition(db_pool, monkeypatch):
    marker = get_test_identifier("connectorjob")
    seen: dict[str, object] = {}

    async with db_pool.acquire() as conn:
        job_id = await conn.fetchval(
            "SELECT enqueue_ingestion_job('text', $1::jsonb, $2, $3)",
            json.dumps({
                "title": f"Connector job {marker}",
                "mode": "fast",
                "source_type": "email",
                "connector_id": "gmail",
                "provider_item_id": f"msg-{marker}",
            }),
            f"Connector body {marker}",
            f"connector:{marker}",
        )

    async def fake_ingest_text(self, content, **kwargs):
        seen["acquisition"] = self.config.acquisition
        seen["source_type"] = kwargs.get("source_type")
        self.last_result = {
            "source_document_id": "00000000-0000-0000-0000-000000000001",
            "desk_load": {"skipped": True, "reason": "connector_backfill"},
        }
        return 0

    from services.ingest.pipeline import IngestionPipeline

    monkeypatch.setattr(IngestionPipeline, "ingest_text", fake_ingest_text)

    config = Config(
        dsn=_db_dsn(os.environ.get("POSTGRES_DB")),
        llm_config={"provider": "openai", "model": "stub", "api_key": "stub"},
        verbose=False,
    )
    try:
        handled = await run_ingestion_jobs_step(db_pool, config_override=config)
        assert handled >= 1
        assert seen["acquisition"] == "connector"
        assert seen["source_type"] == "email"
        assert config.acquisition is None

        async with db_pool.acquire() as conn:
            job = await conn.fetchrow(
                "SELECT status, result FROM ingestion_jobs WHERE id = $1::uuid", job_id
            )
        assert job["status"] == "completed"
        result = _j(job["result"])
        assert result["memories_created"] == 0
        assert result["desk_load"] == {"skipped": True, "reason": "connector_backfill"}
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM ingestion_jobs WHERE id = $1::uuid", job_id)


async def test_artifact_job_requires_artifact_id(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception, match="artifact_id"):
            await conn.fetchval(
                "SELECT enqueue_ingestion_job('artifact', '{}'::jsonb)"
            )


async def test_missing_artifact_fails_loud(db_pool):
    marker = get_test_identifier("artifactmissing")
    async with db_pool.acquire() as conn:
        job_id = await conn.fetchval(
            "SELECT enqueue_ingestion_job('artifact', $1::jsonb, NULL, $2)",
            json.dumps({"artifact_id": "0e3777f8-58b8-4a44-9a67-30f30fdb978c"}),
            f"artifact:{marker}",
        )
    config = Config(
        dsn=_db_dsn(os.environ.get("POSTGRES_DB")),
        llm_config={"provider": "openai", "model": "stub", "api_key": "stub"},
        verbose=False,
    )
    try:
        await run_ingestion_jobs_step(db_pool, config_override=config)
        async with db_pool.acquire() as conn:
            job = await conn.fetchrow(
                "SELECT status, error FROM ingestion_jobs WHERE id = $1::uuid", job_id
            )
        assert job["status"] in ("pending", "failed")  # retries then terminal
        assert "not found" in (job["error"] or "")
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM ingestion_jobs WHERE id = $1::uuid", job_id)
