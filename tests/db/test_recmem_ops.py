from __future__ import annotations

import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _coerce_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


async def test_recmem_output_normalizers_accept_strings_and_objects(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            episodes = await conn.fetchval(
                "SELECT normalize_recmem_episode_output($1::jsonb)",
                json.dumps({"episodes": ["one", {"episode": "two"}, {"content": "three"}, {"noop": True}]}),
            )
            facts = await conn.fetchval(
                "SELECT normalize_recmem_fact_output($1::jsonb)",
                json.dumps({"facts": ["alpha", {"fact": "beta"}, {"content": "gamma"}, 42]}),
            )

            episodes = _coerce_json(episodes)
            facts = _coerce_json(facts)
            assert [item.get("content") or item.get("episode") for item in episodes] == ["one", "two", "three"]
            assert [item.get("content") or item.get("fact") for item in facts] == ["alpha", "beta", "gamma"]
        finally:
            await tr.rollback()


async def test_load_recmem_task_context_is_db_owned(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            unit_id = await conn.fetchval(
                """
                INSERT INTO subconscious_units (
                    content, user_text, assistant_text, embedding_status,
                    route_status, idempotency_key
                )
                VALUES ('User: context\n\nAssistant: ok', 'context', 'ok', 'embedded', 'create_queued', 'ops:context')
                RETURNING id
                """
            )
            task_id = await conn.fetchval(
                """
                INSERT INTO recmem_consolidation_tasks (task_type, trigger_unit_id, source_unit_ids)
                VALUES ('episode_create', $1, ARRAY[$1]::uuid[])
                RETURNING id
                """,
                unit_id,
            )

            context = await conn.fetchval("SELECT load_recmem_task_context($1::uuid)", task_id)
            context = _coerce_json(context)

            assert context["task"]["id"] == str(task_id)
            assert context["sources"][0]["id"] == str(unit_id)
            assert context["sources"][0]["user_text"] == "context"
        finally:
            await tr.rollback()



async def test_subconscious_observation_normalization_and_rpe_in_db(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            normalized = await conn.fetchval(
                "SELECT normalize_subconscious_observations($1::jsonb)",
                json.dumps({
                    "narrative_observations": [{"summary": "n"}],
                    "relationship_observations": "bad",
                    "emotional_patterns": [{"pattern": "steady"}],
                    "consolidation_suggestions": [{"summary": "c"}],
                }),
            )
            normalized = _coerce_json(normalized)
            assert normalized["narrative_observations"] == [{"summary": "n"}]
            assert normalized["relationship_observations"] == []
            assert normalized["emotional_observations"] == [{"pattern": "steady"}]
            assert normalized["consolidation_observations"] == [{"summary": "c"}]

            await conn.execute(
                "SELECT set_current_affective_state($1::jsonb)",
                json.dumps({"valence": 0.0, "arousal": 0.5, "dopamine_tonic": 0.5}),
            )
            dopamine = await conn.fetchval(
                "SELECT compute_dopamine_rpe('{}'::jsonb, $1::jsonb)",
                json.dumps({"emotional_observations": "bad", "relationship_observations": "bad"}),
            )
            dopamine = _coerce_json(dopamine)
            assert dopamine["fired"] is False
            assert dopamine["rpe"] == 0
            assert dopamine["tonic"] == 0.5
        finally:
            await tr.rollback()
