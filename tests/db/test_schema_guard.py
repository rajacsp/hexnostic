"""Canonical-schema guard (#77): shadow report, loud heal, and the event
trigger that rejects creating ag_catalog functions with public twins — the
fossil bug (stale ag_catalog copies shadowing migrated public functions for
every worker connection) must fail at creation time, not fester for months.
"""
from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def test_schema_has_no_shadowed_functions(db_pool):
    """The fixture DB (baseline + all migrations) must be canonical."""
    async with db_pool.acquire() as conn:
        report = _json(await conn.fetchval("SELECT schema_shadow_report()"))
        assert report["count"] == 0, report["strays"]


async def test_event_trigger_rejects_shadow_creation(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            with pytest.raises(Exception) as excinfo:
                await conn.execute(
                    """
                    CREATE FUNCTION ag_catalog.fast_recall(p_probe TEXT)
                    RETURNS TEXT AS $$ SELECT 'fossil' $$ LANGUAGE sql
                    """
                )
            assert "shadow" in str(excinfo.value)
        finally:
            await tr.rollback()


async def test_heal_drops_strays_when_trigger_is_bypassed(db_pool):
    """Belt and suspenders: if a stray appears anyway (restored backup,
    trigger-less environment), heal_schema_shadows evicts it loudly."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("ALTER EVENT TRIGGER guard_ag_catalog_shadow DISABLE")
            await conn.execute(
                """
                CREATE FUNCTION ag_catalog.fast_recall(p_probe TEXT)
                RETURNS TEXT AS $$ SELECT 'fossil' $$ LANGUAGE sql
                """
            )
            report = _json(await conn.fetchval("SELECT schema_shadow_report()"))
            assert report["count"] == 1
            assert report["strays"][0]["name"] == "fast_recall"

            healed = _json(await conn.fetchval("SELECT heal_schema_shadows()"))
            assert healed["dropped"] == 1

            report = _json(await conn.fetchval("SELECT schema_shadow_report()"))
            assert report["count"] == 0
        finally:
            await tr.rollback()
