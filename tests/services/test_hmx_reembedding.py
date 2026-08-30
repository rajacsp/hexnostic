"""Maintenance-worker integration for the bounded HMX embedding step."""

from __future__ import annotations

import pytest

from services import worker_service

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_maintenance_worker_runs_hmx_reembedding(db_pool, monkeypatch):
    seen = []

    async def fake_step(conn):
        seen.append(conn)
        return {"skipped": True, "reason": "test"}

    monkeypatch.setattr(worker_service, "run_hmx_reembed_step", fake_step)
    worker = worker_service.MaintenanceWorker()
    worker.pool = db_pool

    await worker._run_hmx_reembedding()

    assert len(seen) == 1
