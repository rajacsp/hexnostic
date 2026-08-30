"""The init->doctor consent coherence the audit flagged: a consent recorded in the DB
(what `hexis init` does) must make `hexis doctor` report Consent OK. It used to read a
separate filesystem store and contradict a successful init."""
from __future__ import annotations

import os

import pytest

from core.cli_api import doctor_payload

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _dsn() -> str:
    host = os.getenv("POSTGRES_HOST", "127.0.0.1")
    port = os.getenv("POSTGRES_PORT", "43815")
    user = os.getenv("POSTGRES_USER", "hexis_user")
    pw = os.getenv("POSTGRES_PASSWORD", "hexis_password")
    db = os.getenv("POSTGRES_DB", "hexis_memory")
    return f"postgresql://{user}:{pw}@{host}:{port}/{db}"


async def test_doctor_reports_consent_from_the_database(db_pool):
    async with db_pool.acquire() as conn:
        # simulate a completed init: the config status + a consent_log row
        await conn.execute(
            "INSERT INTO config (key, value) VALUES ('agent.consent_status', to_jsonb('consent'::text)) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value")
        await conn.execute(
            "INSERT INTO consent_log (decision, provider, model, endpoint, response) "
            "VALUES ('consent', 'anthropic', 'claude-x', 'https://api', '{}'::jsonb)")
    try:
        checks = await doctor_payload(_dsn())
        consent = next(c for c in checks if c["label"] == "Consent")
        assert consent["status"] == "OK", consent
        assert "anthropic/claude-x" in consent["detail"]
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM consent_log WHERE provider='anthropic' AND model='claude-x'")
            await conn.execute("DELETE FROM config WHERE key='agent.consent_status'")
