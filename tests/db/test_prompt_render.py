"""The SQL prompt renderers are the single source of prompt text.

The DB-owned render_* functions (db/39_functions_prompt_render.sql) are pinned
by golden fixtures in tests/fixtures/prompt_render/ — the byte-exact output
the deleted Python formatters used to produce. A failing golden means the
rendered prompt changed; regenerate deliberately and review the diff.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session")]

_GOLDEN_DIR = Path(__file__).resolve().parents[1] / "fixtures" / "prompt_render"


def _golden(name: str) -> str:
    return (_GOLDEN_DIR / f"{name}.txt").read_text(encoding="utf-8")


# A context exercising every formatter + edge cases (avoids the two known,
# LLM-irrelevant divergences: multi-key embedded-JSON ordering and
# banker's-rounding halves — floats here format identically both ways).
_RICH = {
    "heartbeat_number": 42,
    "agent": {
        "objectives": ["Stay curious", {"title": "Help the user", "description": "always"}],
        "guardrails": ["No harm", {"name": "privacy", "description": "protect data"}],
        "tools": ["recall", {"name": "reflect", "description": "introspect"}],
        "budget": {"max_daily_tokens": 100000},
    },
    "environment": {
        "timestamp": "2026-07-07T12:00:00Z", "day_of_week": "Tuesday", "hour_of_day": 12,
        "time_since_user_hours": 3, "pending_events": 2,
    },
    "goals": {
        "counts": {"active": 2, "queued": 1},
        "active": [{"title": "Learn SQL"}, {"title": "Write tests"}],
        "queued": [{"title": "Refactor"}],
        "issues": [{"title": "Goal X", "issue": "blocked"}],
    },
    "narrative": {"current_chapter": {"name": "The Migration"}},
    "recent_memories": [{"content": "A" * 150}, {"content": "short one"}],
    "identity": [{"type": "core", "content": {"role": "assistant"}}],
    "self_model": [{"kind": "is", "concept": "helpful", "strength": 0.9}],
    "relationships": [{"entity": "Eric", "strength": 0.75}],
    "worldview": [{"category": "ethics", "belief": "B" * 100, "confidence": 0.8}],
    "contradictions": [{"content_a": "a" * 70, "content_b": "b" * 70}],
    "emotional_patterns": [{"pattern": "calm focus", "frequency": 3}],
    "active_transformations": [{
        "content": "I value clarity", "subcategory": "value",
        "progress": {
            "progress": {"reflections": {"current": 2, "required": 5},
                         "evidence": {"memory_count": 4, "current_strength": 0.5}},
            "requirements": {"min_heartbeats": 10, "evidence_threshold": 3, "max_change_per_attempt": 0.1},
            "evidence_samples": [{"content": "sample one"}, {"content": "sample two"}],
        },
    }],
    "transformations_ready": [],
    "emotional_state": {"primary_emotion": "content", "valence": 0.5, "arousal": 0.25},
    "urgent_drives": [{"name": "connection", "urgency_ratio": 1.5}, {"name": "rest", "level": "high"}],
    "energy": {"current": 14, "max": 20},
    "backlog": {"counts": {"todo": 5, "in_progress": 2},
                "actionable": [{"title": "Task A", "priority": "high", "owner": "agent",
                                "status": "todo", "has_checkpoint": True}]},
    "allowed_actions": ["observe", "recall", "reflect"],
    "action_costs": {"observe": 0, "recall": 1, "reflect": 2, "reach_out": 5},
    "memories_at_threshold": {
        "budget_remaining": 3,
        "reviews": [
            {"review_id": "11111111-1111-1111-1111-111111111111",
             "preview": "a walk in the rain / apples at the market",
             "reason": "near_protection_threshold",
             "memory_ids": ["22222222-2222-2222-2222-222222222222"],
             "expires_at": "2026-07-14T00:00:00Z"},
        ],
    },
}

_EDGE_CASES = {
    "empty": {},
    "nulls": {
        "agent": {"objectives": None, "guardrails": None, "tools": None, "budget": None},
        "goals": {"active": [], "queued": [], "issues": []},
        "allowed_actions": None, "action_costs": {}, "emotional_state": None,
        "narrative": None, "recent_memories": [], "urgent_drives": [],
    },
    "allowed_empty": {"allowed_actions": []},
    "drive_level_only": {"urgent_drives": [{"name": "rest", "level": "high"}, {"name": "solo"}]},
    "transform_minimal": {"active_transformations": [{"content": "", "category": "belief"}]},
    "backlog_empty_counts": {"backlog": {"counts": {}, "actionable": []}},
}


async def _render_sql(conn, ctx: dict) -> str:
    return await conn.fetchval(
        "SELECT render_heartbeat_decision_prompt($1::jsonb)", json.dumps(ctx)
    )


async def test_heartbeat_prompt_rich_context_golden(db_pool):
    """SQL renderer matches the pinned golden on a fully-populated context."""
    async with db_pool.acquire() as conn:
        assert await _render_sql(conn, _RICH) == _golden("heartbeat_rich")


@pytest.mark.parametrize("name", list(_EDGE_CASES))
async def test_heartbeat_prompt_edge_case_golden(db_pool, name):
    """Empty/null/absent-key defaults render exactly the pinned goldens."""
    ctx = _EDGE_CASES[name]
    async with db_pool.acquire() as conn:
        assert await _render_sql(conn, ctx) == _golden(f"heartbeat_{name}"), name


# ---------------------------------------------------------------------------
# Chat memory context: render_chat_memory_context golden output
# ---------------------------------------------------------------------------


_CTX_CASES = {
    "tiered": {"memories": [
        {"content": "raw turn", "tier": "subconscious", "similarity": 0.91, "trust_level": 0.8},
        {"content": "an event", "tier": "episodic", "similarity": 0.7},
        {"content": "a fact", "tier": "semantic", "trust_level": 0.95}],
        "identity": [{"type": "core", "concept": "helpful", "strength": 0.9}],
        "worldview": [{"belief": "honesty matters", "confidence": 0.8}],
        "emotional_state": {"primary_emotion": "calm", "valence": 0.5, "arousal": 0.25},
        "goals": {"active": [{"title": "ship it", "source": "user"}], "queued": [{"title": "rest"}]},
        "urgent_drives": [{"name": "connection", "urgency_ratio": 1.5}, {"name": "rest", "level": "high"}]},
    "flat": {"memories": [{"content": "m1", "similarity": 0.88, "trust_level": 0.9,
                           "source_attribution": {"kind": "doc", "ref": "file.md"}},
                          {"content": "m2", "source_attribution": {"kind": "chat"}}],
             "partial_activations": [{"cluster_name": "themes", "keywords": ["a", "b", "c"]},
                                     {"cluster_name": "empty", "keywords": []}]},
    "empty": {},
    "drives_only": {"urgent_drives": [{"name": "x", "urgency_ratio": 0.05}]},
    # Recall hedges (vividness = min(strength, fidelity) vs config threshold)
    # and felt-emotion cues (signed intensity at/above the cue threshold).
    "hedged_and_felt": {"memories": [
        {"content": "faint one", "strength": 0.1, "similarity": 0.8},
        {"content": "vague one", "strength": 0.3, "fidelity": 0.9},
        {"content": "warm one", "emotional_intensity": 0.5, "trust_level": 0.9},
        {"content": "painful one", "emotional_intensity": -0.41},
        {"content": "exactly at cue", "emotional_intensity": 0.4},
    ]},
    "subgraph": {
        "memories": [{"content": "m1", "similarity": 0.9}],
        "subgraph": {
            "nodes": [
                {"type": "memory", "id": "n1", "label": "First memory label"},
                {"type": "memory", "id": "n2", "label": "  padded label  "},
                {"type": "concept", "id": "c1", "label": ""},
            ],
            "edges": [
                {"src_type": "memory", "src_id": "n2", "rel": "SUPPORTS", "dst_type": "concept", "dst_id": "c1"},
                {"src_type": "memory", "src_id": "n1", "rel": "ASSOCIATED", "dst_type": "memory", "dst_id": "n2"},
                {"src_type": "memory", "src_id": "n1", "dst_type": "memory", "dst_id": "missing"},
            ],
        },
    },
}


@pytest.mark.parametrize("name", list(_CTX_CASES))
async def test_chat_memory_context_golden(db_pool, name):
    j = _CTX_CASES[name]
    async with db_pool.acquire() as conn:
        sql = await conn.fetchval("SELECT render_chat_memory_context($1::jsonb)", json.dumps(j))
    assert sql == _golden(f"chatctx_{name}"), name


# ---------------------------------------------------------------------------
# Subconscious signals: render_subconscious_signals golden output
# ---------------------------------------------------------------------------


_SUB_CASES = {
    "full": {"instincts": [{"impulse": "reach out", "intensity": 0.8, "reason": "lonely"}],
             "emotional_state": {"primary_emotion": "warm", "valence": 0.6, "arousal": 0.3},
             "memory_expansions": [{"query": "past chats"}, {"query": ""}, {"query": "goals"}],
             "salient_memories": [{"memory_id": "abc", "reason": "relevant"}],
             "subconscious_response": "I feel curious " + "x" * 300},
    "empty": {},
    "only_emotion": {"emotional_state": {"primary_emotion": "neutral"}},
}


@pytest.mark.parametrize("name", list(_SUB_CASES))
async def test_subconscious_signals_golden(db_pool, name):
    j = _SUB_CASES[name]
    async with db_pool.acquire() as conn:
        sql = await conn.fetchval("SELECT render_subconscious_signals($1::jsonb)", json.dumps(j))
    assert sql == _golden(f"subconscious_{name}"), name


# ---------------------------------------------------------------------------
# Personhood composition: compose_personhood golden output
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("kind", ["heartbeat", "reflect", "conversation", "ingest", "group"])
async def test_compose_personhood_golden(db_pool, kind):
    """compose_personhood (db/39) selects + joins the seeded personhood
    sub-modules per kind (seeded from personhood.md by
    scripts/gen_prompt_seed.py). The Python composer was deleted."""
    async with db_pool.acquire() as conn:
        sql = await conn.fetchval("SELECT compose_personhood($1)", kind)
    assert sql == _golden(f"personhood_{kind}"), kind
