from __future__ import annotations

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_human_scale_memory_prompt_modules(db_pool):
    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT key, content
            FROM prompt_modules
            WHERE key IN (
                'conversation',
                'conscious_extraction',
                'recmem_episode_create',
                'recmem_semantic_refine'
            )
            """
        )

    modules = {row["key"]: row["content"] for row in rows}

    conversation = modules["conversation"]
    assert "**Human-scale memory:**" in conversation
    assert "Single-turn calibration" in conversation
    assert "Do not `remember` it as a strategic memory" in conversation
    assert "explicitly artificial test facts compartmentalized" in conversation
    assert "When the user asks for both emotional presence and a next move" in conversation

    extraction = modules["conscious_extraction"]
    assert "Human-scale retention" in extraction
    assert "artificial test details" in extraction
    assert "working context or episode texture" in extraction

    episode_create = modules["recmem_episode_create"]
    assert "summarize at human scale" in episode_create
    assert "test context rather than personal lore" in episode_create

    semantic_refine = modules["recmem_semantic_refine"]
    assert "single-turn calibration" in semantic_refine
    assert "artificial test facts" in semantic_refine
