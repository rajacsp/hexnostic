from __future__ import annotations

import json

import pytest

from core.capability_maturity import capability_maturity_scorecard, run_alive_demo

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def _state_snapshot(conn) -> tuple[dict, dict[str, int]]:
    heartbeat = await conn.fetchrow("""
        SELECT heartbeat_count, last_heartbeat_at, current_energy,
               active_heartbeat_id, is_paused
        FROM heartbeat_state WHERE id = 1
        """)
    counts = await conn.fetchrow("""
        SELECT
            (SELECT count(*) FROM memories)::int AS memories,
            (SELECT count(*) FROM subconscious_units)::int AS units,
            (SELECT count(*) FROM agent_turns)::int AS turns
        """)
    return dict(heartbeat), dict(counts)


async def test_alive_demo_proves_real_paths_and_rolls_everything_back(db_pool):
    async with db_pool.acquire() as conn:
        before = await _state_snapshot(conn)
        result = await run_alive_demo(conn)
        after = await _state_snapshot(conn)

    assert result["ok"] is True
    assert result["mode"] == "rollback_only"
    assert result["llm_executed"] is False
    assert result["token_cost"] == 0
    assert result["passed"] == result["total"] == 6
    assert before == after
    proofs = {proof["id"]: proof for proof in result["proofs"]}
    assert proofs["cross_session_recall"]["evidence"]["session_count"] == 2
    assert proofs["boundary_refusal"]["evidence"]["error_type"] == "boundary_violation"
    assert proofs["energy_governance"]["evidence"]["decision"] == "energy"
    assert proofs["heartbeat"]["evidence"]["heartbeat_id"]
    assert proofs["self_initiated_intent"]["evidence"]["call_type"] == "think"
    assert proofs["rollback_cleanup"]["evidence"] == {
        "residue_count": 0,
        "heartbeat_state_restored": True,
    }


async def test_alive_demo_reports_initialization_blocker_without_residue(db_pool):
    async with db_pool.acquire() as conn:
        parent = conn.transaction()
        await parent.start()
        try:
            await conn.execute(
                "UPDATE heartbeat_state SET init_stage = 'not_started' WHERE id = 1"
            )
            before = await _state_snapshot(conn)
            result = await run_alive_demo(conn)
            after = await _state_snapshot(conn)
        finally:
            await parent.rollback()

    proofs = {proof["id"]: proof for proof in result["proofs"]}
    assert result["ok"] is False
    assert proofs["heartbeat"]["status"] == "FAIL"
    assert "initialization" in proofs["heartbeat"]["detail"]
    assert "hexis init" in proofs["heartbeat"]["next_step"]
    assert proofs["rollback_cleanup"]["status"] == "PASS"
    assert before == after


async def test_maturity_scorecard_uses_live_runtime_evidence(db_pool):
    async with db_pool.acquire() as conn:
        scorecard = await capability_maturity_scorecard(conn)

    assert scorecard["max_points"] == 20
    assert 0 <= scorecard["score"] <= 100
    scenarios = {item["id"]: item for item in scorecard["scenarios"]}
    assert set(scenarios) == {
        "memory_continuity",
        "autonomous_heartbeat",
        "boundary_enforcement",
        "energy_governance",
        "self_improvement",
    }
    assert all(
        0 <= item["level"] <= item["max_level"] == 4 for item in scenarios.values()
    )
    assert scenarios["autonomous_heartbeat"]["level"] >= 2
    assert scenarios["energy_governance"]["level"] >= 3
    assert scenarios["self_improvement"]["level"] >= 2
    assert scenarios["self_improvement"]["next_step"]


async def test_maturity_scorecard_is_json_serializable(db_pool):
    async with db_pool.acquire() as conn:
        scorecard = await capability_maturity_scorecard(conn)
    assert json.loads(json.dumps(scorecard))["points"] == scorecard["points"]
