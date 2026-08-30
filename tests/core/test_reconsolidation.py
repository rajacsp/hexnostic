"""Tests for the reconsolidation sweep system.

Covers:
  - DB functions: queue, claim, get_candidates, apply_verdict, complete, fail
  - Python service helpers: _normalize_verdicts
  - Prompt loading
  - Schema: CONTESTED_BECAUSE enum, reconsolidation_tasks table
"""

import json

import pytest

from tests.utils import get_test_identifier, _coerce_json

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _create_worldview_belief(conn, content: str) -> str:
    """Create a worldview memory and return its id."""
    return str(
        await conn.fetchval(
            """
            SELECT create_worldview_memory(
                $1, 'belief', 0.9, 0.95, 0.8, 'user_initialized'
            )
            """,
            content,
        )
    )


async def _create_semantic_mem(conn, content: str, *, contested: bool = False) -> str:
    """Create a semantic memory, optionally flagged as contested."""
    mem_id = str(
        await conn.fetchval(
            """
            SELECT create_semantic_memory(
                $1, 0.8, ARRAY['test'], NULL, NULL, 0.6, NULL, 0.8
            )
            """,
            content,
        )
    )
    if contested:
        await conn.execute(
            """
            UPDATE memories
            SET source_attribution = source_attribution || '{"contested": true}'::jsonb,
                trust_level = trust_level * 0.4
            WHERE id = $1::uuid
            """,
            mem_id,
        )
    return mem_id


async def _create_edge(conn, from_id: str, to_id: str, edge_type: str) -> None:
    """Create a graph edge between two memories."""
    await conn.execute(
        "SELECT create_memory_relationship($1::uuid, $2::uuid, $3::graph_edge_type, '{}'::jsonb)",
        from_id,
        to_id,
        edge_type,
    )


async def _insert_task(conn, belief_id: str) -> str:
    """Directly insert a reconsolidation task row and return its id."""
    return str(
        await conn.fetchval(
            """
            INSERT INTO reconsolidation_tasks
                (belief_id, old_content, new_content, total_candidates)
            VALUES ($1::uuid, 'old belief', 'new belief', 5)
            RETURNING id
            """,
            belief_id,
        )
    )


# ---------------------------------------------------------------------------
# Schema tests
# ---------------------------------------------------------------------------

class TestSchema:

    async def test_contested_because_enum_exists(self, db_pool):
        async with db_pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT 'CONTESTED_BECAUSE'::graph_edge_type::text"
            )
            assert result == "CONTESTED_BECAUSE"

    async def test_reconsolidation_tasks_table_exists(self, db_pool):
        async with db_pool.acquire() as conn:
            exists = await conn.fetchval(
                """
                SELECT EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_name = 'reconsolidation_tasks'
                )
                """
            )
            assert exists is True


# ---------------------------------------------------------------------------
# queue_reconsolidation
# ---------------------------------------------------------------------------

class TestQueueReconsolidation:

    async def test_creates_task(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('queue')}"
                )
                task_id = await conn.fetchval(
                    "SELECT queue_reconsolidation($1::uuid, 'old', 'new', 'shift')",
                    belief_id,
                )
                assert task_id is not None
                row = await conn.fetchrow(
                    "SELECT * FROM reconsolidation_tasks WHERE id = $1",
                    task_id,
                )
                assert row["status"] == "pending"
                assert row["old_content"] == "old"
                assert row["new_content"] == "new"
            finally:
                await tr.rollback()

    async def test_counts_candidates(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('count')}"
                )
                mem_id = await _create_semantic_mem(
                    conn, f"Memory {get_test_identifier('count')}"
                )
                await _create_edge(conn, mem_id, belief_id, "SUPPORTS")

                task_id = await conn.fetchval(
                    "SELECT queue_reconsolidation($1::uuid, 'old', 'new')",
                    belief_id,
                )
                row = await conn.fetchrow(
                    "SELECT total_candidates FROM reconsolidation_tasks WHERE id = $1",
                    task_id,
                )
                assert row["total_candidates"] >= 1
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# claim_reconsolidation_task
# ---------------------------------------------------------------------------

class TestClaimTask:

    async def test_returns_pending_task(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('claim')}"
                )
                await _insert_task(conn, belief_id)

                raw = await conn.fetchval("SELECT claim_reconsolidation_task()")
                task = _coerce_json(raw)
                assert task is not None
                assert "task_id" in task
                assert task["old_content"] == "old belief"
            finally:
                await tr.rollback()

    async def test_returns_null_when_empty(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                # Remove any pending tasks
                await conn.execute(
                    "DELETE FROM reconsolidation_tasks WHERE status = 'pending'"
                )
                raw = await conn.fetchval("SELECT claim_reconsolidation_task()")
                assert raw is None
            finally:
                await tr.rollback()

    async def test_sets_status_in_progress(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('claim_status')}"
                )
                task_id = await _insert_task(conn, belief_id)

                await conn.fetchval("SELECT claim_reconsolidation_task()")
                status = await conn.fetchval(
                    "SELECT status FROM reconsolidation_tasks WHERE id = $1::uuid",
                    task_id,
                )
                assert status == "in_progress"
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# get_reconsolidation_candidates
# ---------------------------------------------------------------------------

class TestGetCandidates:

    async def test_contested_direction(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('cand_contested')}"
                )
                mem_id = await _create_semantic_mem(
                    conn,
                    f"Contested mem {get_test_identifier('cand_contested')}",
                    contested=True,
                )
                await _create_edge(conn, mem_id, belief_id, "CONTESTED_BECAUSE")

                raw = await conn.fetchval(
                    "SELECT get_reconsolidation_candidates($1::uuid, 10, 0)",
                    belief_id,
                )
                result = _coerce_json(raw)
                contested = result.get("contested_candidates", [])
                assert len(contested) >= 1
                ids = [str(c["id"]) for c in contested]
                assert mem_id in ids
            finally:
                await tr.rollback()

    async def test_supports_direction(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('cand_support')}"
                )
                mem_id = await _create_semantic_mem(
                    conn, f"Support mem {get_test_identifier('cand_support')}"
                )
                await _create_edge(conn, mem_id, belief_id, "SUPPORTS")

                raw = await conn.fetchval(
                    "SELECT get_reconsolidation_candidates($1::uuid, 10, 0)",
                    belief_id,
                )
                result = _coerce_json(raw)
                supporting = result.get("supporting_candidates", [])
                assert len(supporting) >= 1
                ids = [str(c["id"]) for c in supporting]
                assert mem_id in ids
            finally:
                await tr.rollback()

    async def test_empty_when_no_edges(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('cand_empty')}"
                )
                raw = await conn.fetchval(
                    "SELECT get_reconsolidation_candidates($1::uuid, 10, 0)",
                    belief_id,
                )
                result = _coerce_json(raw)
                assert result.get("contested_candidates", []) == []
                assert result.get("supporting_candidates", []) == []
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# apply_reconsolidation_verdict
# ---------------------------------------------------------------------------

class TestApplyVerdict:

    async def test_accept_restores_trust(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('accept')}"
                )
                mem_id = await _create_semantic_mem(
                    conn,
                    f"Contested {get_test_identifier('accept')}",
                    contested=True,
                )
                await _create_edge(conn, mem_id, belief_id, "CONTESTED_BECAUSE")
                task_id = await _insert_task(conn, belief_id)

                trust_before = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )

                verdicts = json.dumps([{
                    "memory_id": mem_id,
                    "verdict": "accept",
                    "reason": "Now compatible",
                    "strength": 0.7,
                    "create_supports": False,
                }])
                raw = await conn.fetchval(
                    "SELECT apply_reconsolidation_verdict($1::uuid, $2::jsonb)",
                    task_id, verdicts,
                )
                result = _coerce_json(raw)
                assert result["accepted"] == 1

                # Trust should be restored (higher than before)
                trust_after = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )
                assert trust_after > trust_before

                # Contested flag should be gone
                sa = await conn.fetchval(
                    "SELECT source_attribution FROM memories WHERE id = $1::uuid", mem_id
                )
                sa = _coerce_json(sa)
                assert sa.get("contested") is None or sa.get("contested") == "false"
            finally:
                await tr.rollback()

    async def test_newly_contested_reduces_trust(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('newly')}"
                )
                mem_id = await _create_semantic_mem(
                    conn, f"Support {get_test_identifier('newly')}"
                )
                await _create_edge(conn, mem_id, belief_id, "SUPPORTS")
                task_id = await _insert_task(conn, belief_id)

                trust_before = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )

                verdicts = json.dumps([{
                    "memory_id": mem_id,
                    "verdict": "newly_contested",
                    "reason": "Now contradicts",
                    "strength": 0.8,
                }])
                raw = await conn.fetchval(
                    "SELECT apply_reconsolidation_verdict($1::uuid, $2::jsonb)",
                    task_id, verdicts,
                )
                result = _coerce_json(raw)
                assert result["newly_contested"] == 1

                # Trust should be reduced
                trust_after = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )
                assert trust_after < trust_before

                # Contested flag should be set
                sa = await conn.fetchval(
                    "SELECT source_attribution FROM memories WHERE id = $1::uuid", mem_id
                )
                sa = _coerce_json(sa)
                assert sa.get("contested") is True
            finally:
                await tr.rollback()

    async def test_keep_does_not_change_trust(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('keep')}"
                )
                mem_id = await _create_semantic_mem(
                    conn, f"Support {get_test_identifier('keep')}"
                )
                await _create_edge(conn, mem_id, belief_id, "SUPPORTS")
                task_id = await _insert_task(conn, belief_id)

                trust_before = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )

                verdicts = json.dumps([{
                    "memory_id": mem_id,
                    "verdict": "keep",
                    "reason": "Still supports",
                    "strength": 0.7,
                }])
                raw = await conn.fetchval(
                    "SELECT apply_reconsolidation_verdict($1::uuid, $2::jsonb)",
                    task_id, verdicts,
                )
                result = _coerce_json(raw)
                assert result["kept"] == 1

                trust_after = await conn.fetchval(
                    "SELECT trust_level FROM memories WHERE id = $1::uuid", mem_id
                )
                assert trust_after == trust_before
            finally:
                await tr.rollback()

    async def test_still_contested_keeps_flag(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('still')}"
                )
                mem_id = await _create_semantic_mem(
                    conn,
                    f"Contested {get_test_identifier('still')}",
                    contested=True,
                )
                await _create_edge(conn, mem_id, belief_id, "CONTESTED_BECAUSE")
                task_id = await _insert_task(conn, belief_id)

                verdicts = json.dumps([{
                    "memory_id": mem_id,
                    "verdict": "still_contested",
                    "reason": "Still conflicts",
                    "strength": 0.6,
                }])
                raw = await conn.fetchval(
                    "SELECT apply_reconsolidation_verdict($1::uuid, $2::jsonb)",
                    task_id, verdicts,
                )
                result = _coerce_json(raw)
                assert result["still_contested"] == 1

                # Still contested
                sa = await conn.fetchval(
                    "SELECT source_attribution FROM memories WHERE id = $1::uuid", mem_id
                )
                sa = _coerce_json(sa)
                assert sa.get("contested") is True
            finally:
                await tr.rollback()

    async def test_updates_task_counters(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('counters')}"
                )
                mem_id = await _create_semantic_mem(
                    conn, f"Mem {get_test_identifier('counters')}"
                )
                await _create_edge(conn, mem_id, belief_id, "SUPPORTS")
                task_id = await _insert_task(conn, belief_id)

                verdicts = json.dumps([{
                    "memory_id": mem_id,
                    "verdict": "keep",
                    "reason": "ok",
                    "strength": 0.7,
                }])
                await conn.fetchval(
                    "SELECT apply_reconsolidation_verdict($1::uuid, $2::jsonb)",
                    task_id, verdicts,
                )
                row = await conn.fetchrow(
                    "SELECT processed_count FROM reconsolidation_tasks WHERE id = $1::uuid",
                    task_id,
                )
                assert row["processed_count"] == 1
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# complete_reconsolidation
# ---------------------------------------------------------------------------

class TestCompleteReconsolidation:

    async def test_creates_episodic_memory(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('complete')}"
                )
                task_id = await _insert_task(conn, belief_id)

                raw = await conn.fetchval(
                    "SELECT complete_reconsolidation($1::uuid)", task_id,
                )
                result = _coerce_json(raw)
                assert result.get("success") is True
                assert result.get("summary_memory_id") is not None

                # Task should be completed
                status = await conn.fetchval(
                    "SELECT status FROM reconsolidation_tasks WHERE id = $1::uuid",
                    task_id,
                )
                assert status == "completed"

                # Episodic memory should exist
                mem_type = await conn.fetchval(
                    "SELECT type::text FROM memories WHERE id = $1::uuid",
                    result["summary_memory_id"],
                )
                assert mem_type == "episodic"
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# fail_reconsolidation
# ---------------------------------------------------------------------------

class TestFailReconsolidation:

    async def test_sets_failed_status(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('fail')}"
                )
                task_id = await _insert_task(conn, belief_id)

                await conn.execute(
                    "SELECT fail_reconsolidation($1::uuid, $2)",
                    task_id, "test error",
                )
                row = await conn.fetchrow(
                    "SELECT status, error_message FROM reconsolidation_tasks WHERE id = $1::uuid",
                    task_id,
                )
                assert row["status"] == "failed"
                assert row["error_message"] == "test error"
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# has_pending_reconsolidation
# ---------------------------------------------------------------------------

class TestHasPending:

    async def test_false_when_empty(self, db_pool):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                await conn.execute("DELETE FROM reconsolidation_tasks")
                result = await conn.fetchval("SELECT has_pending_reconsolidation()")
                assert result is False
            finally:
                await tr.rollback()

    async def test_true_when_pending(self, db_pool, ensure_embedding_service):
        async with db_pool.acquire() as conn:
            tr = conn.transaction()
            await tr.start()
            try:
                belief_id = await _create_worldview_belief(
                    conn, f"Belief {get_test_identifier('pending')}"
                )
                await _insert_task(conn, belief_id)
                result = await conn.fetchval("SELECT has_pending_reconsolidation()")
                assert result is True
            finally:
                await tr.rollback()


# ---------------------------------------------------------------------------
# Python service helpers
# ---------------------------------------------------------------------------

class TestNormalizeVerdicts:

    def test_valid_verdicts(self):
        from services.reconsolidation import _normalize_verdicts

        doc = {"verdicts": [
            {"memory_id": "abc", "verdict": "accept", "reason": "ok"},
            {"memory_id": "def", "verdict": "keep", "reason": "ok"},
        ]}
        result = _normalize_verdicts(doc)
        assert len(result) == 2

    def test_filters_invalid_verdicts(self):
        from services.reconsolidation import _normalize_verdicts

        doc = {"verdicts": [
            {"memory_id": "abc", "verdict": "invalid_type"},
            {"memory_id": "def"},  # missing verdict
            {"verdict": "keep"},  # missing memory_id
            "not_a_dict",
        ]}
        result = _normalize_verdicts(doc)
        assert len(result) == 0

    def test_empty_input(self):
        from services.reconsolidation import _normalize_verdicts

        assert _normalize_verdicts({}) == []
        assert _normalize_verdicts(None) == []
        assert _normalize_verdicts({"verdicts": "not_list"}) == []


# ---------------------------------------------------------------------------
# Prompt loading
# ---------------------------------------------------------------------------

class TestPromptLoading:

    def test_reconsolidation_prompt_loads(self):
        from services.prompt_resources import load_reconsolidation_prompt

        prompt = load_reconsolidation_prompt()
        assert "reconsolidation" in prompt.lower()
        assert "verdict" in prompt.lower()

    def test_prompt_path_exists(self):
        from services.prompt_resources import RLM_RECONSOLIDATION_PROMPT_PATH

        assert RLM_RECONSOLIDATION_PROMPT_PATH.exists()


# ---------------------------------------------------------------------------
# RelationshipType enum
# ---------------------------------------------------------------------------

class TestRelationshipTypeEnum:

    def test_contested_because_exists(self):
        from core.cognitive_memory_api import RelationshipType

        assert hasattr(RelationshipType, "CONTESTED_BECAUSE")
        assert RelationshipType.CONTESTED_BECAUSE.value == "CONTESTED_BECAUSE"
