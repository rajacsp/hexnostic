from __future__ import annotations

import json
from datetime import datetime, timezone
from uuid import uuid4

import pytest

from core.cognitive_memory_api import CognitiveMemory, MemoryType

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.core]


class _Acquire:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        return self.conn

    async def __aexit__(self, *_exc):
        return False


class _Pool:
    def __init__(self, conn):
        self.conn = conn

    def acquire(self):
        return _Acquire(self.conn)


class _Conn:
    def __init__(self):
        self.fetchval_calls = []
        self.fetch_calls = []
        self.fetchval_result = None
        self.fetch_rows = []

    async def fetchval(self, query, *args):
        self.fetchval_calls.append((query, args))
        return self.fetchval_result

    async def fetchrow(self, query, *args):
        # The recmem per-tier budget config read (#76) — serve the defaults.
        if "recmem_sub_limit" in query:
            return {"sub": 10, "epi": 5, "sem": 10, "know": 5}
        return None

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.fetch_rows


async def _stub_get_embedding(conn):
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(
                array_agg((
                    array_fill(0.0::float, ARRAY[0]) ||
                    ARRAY[1.0::float] ||
                    array_fill(0.0::float, ARRAY[embedding_dimension() - 1])
                )::vector),
                ARRAY[]::vector[]
            )
            FROM unnest(text_contents)
        $$ LANGUAGE sql;
        """
    )


async def test_remember_turn_raw_passes_sql_args():
    unit_id = uuid4()
    conn = _Conn()
    conn.fetchval_result = json.dumps({"unit_id": str(unit_id), "status": "stored"})
    mem = CognitiveMemory(_Pool(conn))

    result = await mem.remember_turn_raw(
        "remember apples",
        "noted",
        session_id="not-a-uuid",
        source_identity="chat:1",
        importance=0.7,
        metadata={"channel": "test"},
    )

    assert result == {"unit_id": str(unit_id), "status": "stored"}
    _query, args = conn.fetchval_calls[0]
    assert args[0] == "remember apples"
    assert args[1] == "noted"
    assert args[2] is None
    assert args[3] == "chat:1"
    assert args[5] == 0.7
    assert json.loads(args[7]) == {"channel": "test"}


async def test_hydrate_recmem_maps_tiers_and_dedupes_raw_sources():
    raw_id = uuid4()
    derived_id = uuid4()
    standalone_raw_id = uuid4()
    conn = _Conn()
    conn.fetch_rows = [
        {
            "tier": "subconscious",
            "item_id": raw_id,
            "memory_type": "episodic",
            "content": "raw source should be hidden",
            "score": 0.9,
            "trust_level": 0.95,
            "source_attribution": {},
            "created_at": datetime.now(timezone.utc),
            "source_unit_ids": [],
            "strength": 1.0,
            "fidelity": 1.0,
            "emotional_intensity": 0.0,
            "confidence": None,
        },
        {
            "tier": "episodic",
            "item_id": derived_id,
            "memory_type": "episodic",
            "content": "derived episode",
            "score": 0.8,
            "trust_level": 0.9,
            "source_attribution": {},
            "created_at": datetime.now(timezone.utc),
            "source_unit_ids": [raw_id],
            "strength": 0.8,
            "fidelity": 1.0,
            "emotional_intensity": 0.0,
            "confidence": None,
        },
        {
            "tier": "subconscious",
            "item_id": standalone_raw_id,
            "memory_type": "episodic",
            "content": "standalone raw",
            "score": 0.7,
            "trust_level": 0.95,
            "source_attribution": {},
            "created_at": datetime.now(timezone.utc),
            "source_unit_ids": [],
            "strength": 1.0,
            "fidelity": 1.0,
            "emotional_intensity": 0.0,
            "confidence": None,
        },
    ]
    mem = CognitiveMemory(_Pool(conn))

    memories = await mem.hydrate_recmem("apples", sub_limit=5, epi_limit=5, sem_limit=5)

    assert [m.id for m in memories] == [derived_id, standalone_raw_id]
    assert memories[0].tier == "episodic"
    assert memories[0].source_unit_ids == [raw_id]
    assert memories[0].type == MemoryType.EPISODIC
    assert conn.fetch_calls[0][1][0] == "apples"


async def test_search_history_maps_typed_results_and_sql_filters():
    item_id = uuid4()
    session_id = uuid4()
    source_id = uuid4()
    occurred_at = datetime.now(timezone.utc)
    conn = _Conn()
    conn.fetch_rows = [
        {
            "source_kind": "turn",
            "item_id": item_id,
            "session_id": session_id,
            "content": "User: exact phrase\n\nAssistant: found",
            "user_text": "exact phrase",
            "assistant_text": "found",
            "memory_type": None,
            "occurred_at": occurred_at,
            "rank": 0.5,
            "source_unit_ids": [source_id],
            "source_attribution": {"kind": "conversation"},
            "metadata": {"channel": "api"},
        }
    ]
    mem = CognitiveMemory(_Pool(conn))

    results = await mem.search_history(
        "exact phrase",
        limit=500,
        sources=["turn"],
        exclude_session_id=session_id,
    )

    assert len(results) == 1
    assert results[0].item_id == item_id
    assert results[0].session_id == session_id
    assert results[0].memory_type is None
    assert results[0].source_unit_ids == [source_id]
    _query, args = conn.fetch_calls[0]
    assert args[0] == "exact phrase"
    assert args[1] == 100
    assert args[2] == ["turn"]
    assert args[5] == str(session_id)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"query": ""}, "query keywords, or a created_after"),
        ({"query": "detail", "sources": ["other"]}, "invalid: other"),
        ({"query": "detail", "sources": []}, "at least one source"),
        (
            {
                "query": "detail",
                "created_after": datetime(2026, 8, 1),
                "created_before": datetime(2026, 7, 1),
            },
            "must be earlier",
        ),
        (
            {"query": "detail", "exclude_session_id": "not-a-uuid"},
            "must be a UUID",
        ),
    ],
)
async def test_search_history_rejects_invalid_api_filters(kwargs, message):
    mem = CognitiveMemory(_Pool(_Conn()))

    with pytest.raises(ValueError, match=message):
        await mem.search_history(**kwargs)


async def test_link_and_redact_unit_call_recmem_sql():
    conn = _Conn()
    mem = CognitiveMemory(_Pool(conn))
    memory_id = uuid4()
    unit_id = uuid4()

    conn.fetchval_result = True
    assert await mem.link_to_source_unit(memory_id, unit_id, role="source") is True

    conn.fetchval_result = json.dumps({"redacted_unit_id": str(unit_id), "invalidated_memory_ids": [str(memory_id)]})
    result = await mem.redact_unit(unit_id, reason="test", cascade=True)

    assert result["redacted_unit_id"] == str(unit_id)
    assert "link_memory_to_source_unit" in conn.fetchval_calls[0][0]
    assert "recmem_redact_unit" in conn.fetchval_calls[1][0]


async def test_recmem_api_redaction_excludes_invalidated_memory_from_hydration(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mem = CognitiveMemory(_Pool(conn))
            raw = await mem.remember_turn_raw(
                "hidden preference",
                "noted",
                source_identity="api-redaction-source",
            )
            raw_id = raw["unit_id"]
            await conn.execute(
                """
                UPDATE subconscious_units
                SET embedding = (
                        array_fill(0.0::float, ARRAY[0]) ||
                        ARRAY[1.0::float] ||
                        array_fill(0.0::float, ARRAY[embedding_dimension() - 1])
                    )::vector,
                    embedding_status = 'embedded'
                WHERE id = $1::uuid
                """,
                raw_id,
            )
            invalidated_memory_id = await conn.fetchval(
                """
                SELECT create_memory_with_embedding(
                    'episodic'::memory_type,
                    'hidden preference derived episode',
                    (
                        array_fill(0.0::float, ARRAY[0]) ||
                        ARRAY[1.0::float] ||
                        array_fill(0.0::float, ARRAY[embedding_dimension() - 1])
                    )::vector,
                    0.7,
                    NULL,
                    0.95
                )
                """
            )
            visible_memory_id = await conn.fetchval(
                """
                SELECT create_memory_with_embedding(
                    'semantic'::memory_type,
                    'visible preference survives redaction',
                    (
                        array_fill(0.0::float, ARRAY[0]) ||
                        ARRAY[1.0::float] ||
                        array_fill(0.0::float, ARRAY[embedding_dimension() - 1])
                    )::vector,
                    0.7,
                    NULL,
                    0.95
                )
                """
            )
            await mem.link_to_source_unit(invalidated_memory_id, raw_id, role="source")

            redaction = await mem.redact_unit(raw_id, reason="api integration", cascade=True)
            hydrated = await mem.hydrate_recmem("hidden preference", sub_limit=5, epi_limit=5, sem_limit=5)
            hydrated_ids = {memory.id for memory in hydrated}

            assert redaction["redacted_unit_id"] == str(raw_id)
            assert invalidated_memory_id not in hydrated_ids
            assert raw_id not in {str(memory.id) for memory in hydrated}
            assert visible_memory_id in hydrated_ids
        finally:
            await tr.rollback()
