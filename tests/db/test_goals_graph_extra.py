import json

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _insert_goal(conn, title: str, priority: str = "queued"):
    metadata = {
        "title": title,
        "description": "",
        "priority": priority,
        "source": "curiosity",
        "progress": [],
        "last_touched": None,
        "emotional_valence": 0.0,
    }
    return await conn.fetchval(
        """
        INSERT INTO memories (type, content, embedding, status, metadata)
        VALUES (
            'goal',
            $1,
            array_fill(0.1, ARRAY[embedding_dimension()])::vector,
            'active',
            $2::jsonb
        )
        RETURNING id
        """,
        title,
        json.dumps(metadata),
    )


async def _insert_memory(conn, content: str):
    return await conn.fetchval(
        """
        INSERT INTO memories (type, content, embedding, status, metadata)
        VALUES (
            'semantic',
            $1,
            array_fill(0.2, ARRAY[embedding_dimension()])::vector,
            'active',
            '{}'::jsonb
        )
        RETURNING id
        """,
        content,
    )


async def test_ensure_goals_root_creates_graph_node(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("LOAD 'age';")
            await conn.execute("SELECT ensure_goals_root()")
            count = await conn.fetchval(
                """
                SELECT COUNT(*)
                FROM ag_catalog.cypher('memory_graph', $$
                    MATCH (g:GoalsRoot {key: 'goals'})
                    RETURN g
                $$) as (g ag_catalog.agtype)
                """
            )
            assert int(count) >= 1
        finally:
            await tr.rollback()


async def test_sync_goal_node_and_link_subgoal(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("LOAD 'age';")
            parent_id = await _insert_goal(conn, f"Parent {get_test_identifier('goal')}")
            child_id = await _insert_goal(conn, f"Child {get_test_identifier('goal')}")

            assert await conn.fetchval("SELECT sync_goal_node($1::uuid)", parent_id)
            assert await conn.fetchval("SELECT sync_goal_node($1::uuid)", child_id)
            assert await conn.fetchval(
                "SELECT link_goal_subgoal($1::uuid, $2::uuid)",
                parent_id,
                child_id,
            )

            count = await conn.fetchval(
                """
                SELECT COUNT(*)
                FROM ag_catalog.cypher('memory_graph', $$
                    MATCH (c:GoalNode {goal_id: '%s'})-[:SUBGOAL_OF]->(p:GoalNode {goal_id: '%s'})
                    RETURN c
                $$) as (c ag_catalog.agtype)
                """
                % (child_id, parent_id)
            )
            assert int(count) == 1
        finally:
            await tr.rollback()


async def test_link_goal_to_memory_and_find_goal_memories(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("LOAD 'age';")
            goal_id = await _insert_goal(conn, f"Goal {get_test_identifier('goal_link')}")
            memory_id = await _insert_memory(conn, f"Evidence {get_test_identifier('goal_link')}")

            assert await conn.fetchval("SELECT sync_memory_node($1::uuid)", memory_id)
            assert await conn.fetchval("SELECT sync_goal_node($1::uuid)", goal_id)

            linked = await conn.fetchval(
                "SELECT link_goal_to_memory($1::uuid, $2::uuid, 'origin')",
                goal_id,
                memory_id,
            )
            assert linked is True

            edge_count = await conn.fetchval(
                """
                SELECT COUNT(*)
                FROM ag_catalog.cypher('memory_graph', $$
                    MATCH (g:GoalNode {goal_id: '%s'})-[:ORIGINATED_FROM]->(m:MemoryNode {memory_id: '%s'})
                    RETURN g
                $$) as (g ag_catalog.agtype)
                """
                % (goal_id, memory_id)
            )
            assert int(edge_count) == 1

            rows = await conn.fetch(
                "SELECT * FROM find_goal_memories($1::uuid, 'origin')",
                goal_id,
            )
            assert rows
            assert rows[0]["memory_id"] == memory_id
            assert rows[0]["link_type"] == "origin"
        finally:
            await tr.rollback()


async def test_sync_cluster_and_episode_nodes(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("LOAD 'age';")
            cluster_id = await conn.fetchval(
                """
                INSERT INTO clusters (cluster_type, name, centroid_embedding)
                VALUES ('theme', $1, array_fill(0.3, ARRAY[embedding_dimension()])::vector)
                RETURNING id
                """,
                f"Cluster {get_test_identifier('cluster')}",
            )
            episode_id = await conn.fetchval(
                """
                INSERT INTO episodes (started_at, summary, summary_embedding)
                VALUES (CURRENT_TIMESTAMP, $1, array_fill(0.4, ARRAY[embedding_dimension()])::vector)
                RETURNING id
                """,
                f"Episode {get_test_identifier('episode')}",
            )

            assert await conn.fetchval("SELECT sync_cluster_node($1::uuid)", cluster_id)
            assert await conn.fetchval("SELECT sync_episode_node($1::uuid)", episode_id)

            cluster_count = await conn.fetchval(
                """
                SELECT COUNT(*)
                FROM ag_catalog.cypher('memory_graph', $$
                    MATCH (c:ClusterNode {cluster_id: '%s'})
                    RETURN c
                $$) as (c ag_catalog.agtype)
                """
                % cluster_id
            )
            episode_count = await conn.fetchval(
                """
                SELECT COUNT(*)
                FROM ag_catalog.cypher('memory_graph', $$
                    MATCH (e:EpisodeNode {episode_id: '%s'})
                    RETURN e
                $$) as (e ag_catalog.agtype)
                """
                % episode_id
            )
            assert int(cluster_count) == 1
            assert int(episode_count) == 1
        finally:
            await tr.rollback()


async def test_find_memories_by_concept_returns_matches(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.execute("LOAD 'age';")
            memory_id = await _insert_memory(conn, f"Concept memory {get_test_identifier('concept')}")
            concept_name = f"Concept-{get_test_identifier('concept')}"

            assert await conn.fetchval("SELECT sync_memory_node($1::uuid)", memory_id)
            assert await conn.fetchval(
                "SELECT link_memory_to_concept($1::uuid, $2, 0.9)",
                memory_id,
                concept_name,
            )

            rows = await conn.fetch(
                "SELECT * FROM find_memories_by_concept($1, 5)",
                concept_name,
            )
            assert rows
            assert rows[0]["memory_id"] == memory_id
        finally:
            await tr.rollback()
