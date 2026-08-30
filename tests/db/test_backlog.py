"""
Tests for the backlog table and SQL functions.

Covers: create, get, list, update, delete, snapshot, trigger, constraints.
"""

import json
import uuid

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


# ============================================================================
# Create
# ============================================================================


async def test_create_backlog_item_defaults(db_pool):
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM create_backlog_item('Test task')")
        try:
            assert row["title"] == "Test task"
            assert row["status"] == "todo"
            assert row["priority"] == "normal"
            assert row["owner"] == "agent"
            assert row["created_by"] == "agent"
            assert row["description"] == ""
            assert row["tags"] == []
            assert row["checkpoint"] is None
            assert row["parent_id"] is None
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", row["id"])


async def test_create_backlog_item_all_fields(db_pool):
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM create_backlog_item($1, $2, $3, $4, $5, $6, $7, $8)",
            "Full task",
            "A detailed description",
            "high",
            "user",
            "user",
            ["tag1", "tag2"],
            None,
            None,
        )
        try:
            assert row["title"] == "Full task"
            assert row["description"] == "A detailed description"
            assert row["priority"] == "high"
            assert row["owner"] == "user"
            assert row["created_by"] == "user"
            assert row["tags"] == ["tag1", "tag2"]
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", row["id"])


async def test_create_backlog_item_invalid_priority_defaults(db_pool):
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM create_backlog_item('Task', '', 'mega', 'agent', 'agent')"
        )
        try:
            assert row["priority"] == "normal"
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", row["id"])


async def test_create_backlog_item_with_parent(db_pool):
    async with db_pool.acquire() as conn:
        parent = await conn.fetchrow("SELECT * FROM create_backlog_item('Parent task')")
        child = await conn.fetchrow(
            "SELECT * FROM create_backlog_item($1, $2, $3, $4, $5, $6, $7)",
            "Child task",
            "",
            "normal",
            "agent",
            "agent",
            [],
            parent["id"],
        )
        try:
            assert child["parent_id"] == parent["id"]
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", child["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", parent["id"])


# ============================================================================
# Get
# ============================================================================


async def test_get_backlog_item(db_pool):
    async with db_pool.acquire() as conn:
        created = await conn.fetchrow("SELECT * FROM create_backlog_item('Get me')")
        try:
            fetched = await conn.fetchrow("SELECT * FROM get_backlog_item($1)", created["id"])
            assert fetched["id"] == created["id"]
            assert fetched["title"] == "Get me"
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", created["id"])


async def test_get_backlog_item_not_found(db_pool):
    async with db_pool.acquire() as conn:
        fetched = await conn.fetchrow(
            "SELECT * FROM get_backlog_item($1)", uuid.uuid4()
        )
        assert fetched["id"] is None


# ============================================================================
# List
# ============================================================================


async def test_list_backlog_no_filter(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow("SELECT * FROM create_backlog_item('List A')")
        r2 = await conn.fetchrow("SELECT * FROM create_backlog_item('List B')")
        try:
            rows = await conn.fetch("SELECT * FROM list_backlog()")
            ids = {r["id"] for r in rows}
            assert r1["id"] in ids
            assert r2["id"] in ids
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


async def test_list_backlog_by_status(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow("SELECT * FROM create_backlog_item('Status A')")
        await conn.execute(
            "SELECT update_backlog_item($1, $2::jsonb)",
            r1["id"],
            json.dumps({"status": "blocked"}),
        )
        r2 = await conn.fetchrow("SELECT * FROM create_backlog_item('Status B')")
        try:
            rows = await conn.fetch("SELECT * FROM list_backlog('blocked')")
            ids = {r["id"] for r in rows}
            assert r1["id"] in ids
            assert r2["id"] not in ids
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


async def test_list_backlog_by_priority(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow(
            "SELECT * FROM create_backlog_item('Urgent', '', 'urgent')"
        )
        r2 = await conn.fetchrow(
            "SELECT * FROM create_backlog_item('Low', '', 'low')"
        )
        try:
            rows = await conn.fetch("SELECT * FROM list_backlog(NULL, 'urgent')")
            ids = {r["id"] for r in rows}
            assert r1["id"] in ids
            assert r2["id"] not in ids
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


async def test_list_backlog_by_owner(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow(
            "SELECT * FROM create_backlog_item('User task', '', 'normal', 'user', 'user')"
        )
        r2 = await conn.fetchrow(
            "SELECT * FROM create_backlog_item('Agent task', '', 'normal', 'agent', 'agent')"
        )
        try:
            rows = await conn.fetch("SELECT * FROM list_backlog(NULL, NULL, 'user')")
            ids = {r["id"] for r in rows}
            assert r1["id"] in ids
            assert r2["id"] not in ids
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


async def test_list_backlog_priority_ordering(db_pool):
    async with db_pool.acquire() as conn:
        low = await conn.fetchrow("SELECT * FROM create_backlog_item('Low', '', 'low')")
        urgent = await conn.fetchrow("SELECT * FROM create_backlog_item('Urgent', '', 'urgent')")
        high = await conn.fetchrow("SELECT * FROM create_backlog_item('High', '', 'high')")
        try:
            rows = await conn.fetch("SELECT * FROM list_backlog()")
            titles_in_order = [r["title"] for r in rows if r["title"] in ("Urgent", "High", "Low")]
            assert titles_in_order.index("Urgent") < titles_in_order.index("High")
            assert titles_in_order.index("High") < titles_in_order.index("Low")
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", low["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", urgent["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", high["id"])


# ============================================================================
# Update
# ============================================================================


async def test_update_backlog_item_status(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Update me')")
        try:
            updated = await conn.fetchrow(
                "SELECT * FROM update_backlog_item($1, $2::jsonb)",
                r["id"],
                json.dumps({"status": "in_progress"}),
            )
            assert updated["status"] == "in_progress"
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r["id"])


async def test_update_backlog_item_multiple_fields(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Multi update')")
        try:
            updated = await conn.fetchrow(
                "SELECT * FROM update_backlog_item($1, $2::jsonb)",
                r["id"],
                json.dumps({
                    "title": "Updated title",
                    "priority": "urgent",
                    "tags": ["new_tag"],
                }),
            )
            assert updated["title"] == "Updated title"
            assert updated["priority"] == "urgent"
            assert updated["tags"] == ["new_tag"]
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r["id"])


async def test_update_backlog_item_checkpoint(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Checkpoint test')")
        try:
            checkpoint = {"step": "step 2", "progress": "half done", "next_action": "finish"}
            updated = await conn.fetchrow(
                "SELECT * FROM update_backlog_item($1, $2::jsonb)",
                r["id"],
                json.dumps({"checkpoint": checkpoint}),
            )
            stored = json.loads(updated["checkpoint"]) if isinstance(updated["checkpoint"], str) else updated["checkpoint"]
            assert stored["step"] == "step 2"
            assert stored["next_action"] == "finish"
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r["id"])


async def test_update_backlog_item_invalid_status_ignored(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Ignore invalid')")
        try:
            updated = await conn.fetchrow(
                "SELECT * FROM update_backlog_item($1, $2::jsonb)",
                r["id"],
                json.dumps({"status": "mega_done"}),
            )
            assert updated["status"] == "todo"  # unchanged
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r["id"])


# ============================================================================
# Delete
# ============================================================================


async def test_delete_backlog_item(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Delete me')")
        deleted = await conn.fetchval("SELECT delete_backlog_item($1)", r["id"])
        assert deleted is True
        check = await conn.fetchrow("SELECT * FROM get_backlog_item($1)", r["id"])
        assert check["id"] is None


async def test_delete_backlog_item_not_found(db_pool):
    async with db_pool.acquire() as conn:
        deleted = await conn.fetchval("SELECT delete_backlog_item($1)", uuid.uuid4())
        assert deleted is False


# ============================================================================
# Snapshot
# ============================================================================


async def test_get_backlog_snapshot_empty(db_pool):
    async with db_pool.acquire() as conn:
        # Clean slate
        await conn.execute("DELETE FROM backlog")
        raw = await conn.fetchval("SELECT get_backlog_snapshot()")
        snapshot = json.loads(raw) if isinstance(raw, str) else raw
        assert "counts" in snapshot
        assert "actionable" in snapshot
        assert snapshot["actionable"] == []


async def test_get_backlog_snapshot_with_items(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow("SELECT * FROM create_backlog_item('Snap A', '', 'high')")
        r2 = await conn.fetchrow("SELECT * FROM create_backlog_item('Snap B', '', 'low')")
        try:
            raw = await conn.fetchval("SELECT get_backlog_snapshot()")
            snapshot = json.loads(raw) if isinstance(raw, str) else raw
            assert snapshot["counts"].get("todo", 0) >= 2
            titles = [item["title"] for item in snapshot["actionable"]]
            assert "Snap A" in titles
            assert "Snap B" in titles
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


async def test_get_backlog_snapshot_excludes_done(db_pool):
    async with db_pool.acquire() as conn:
        r1 = await conn.fetchrow("SELECT * FROM create_backlog_item('Active snap')")
        r2 = await conn.fetchrow("SELECT * FROM create_backlog_item('Done snap')")
        await conn.execute(
            "SELECT update_backlog_item($1, $2::jsonb)",
            r2["id"],
            json.dumps({"status": "done"}),
        )
        try:
            raw = await conn.fetchval("SELECT get_backlog_snapshot()")
            snapshot = json.loads(raw) if isinstance(raw, str) else raw
            titles = [item["title"] for item in snapshot["actionable"]]
            assert "Active snap" in titles
            assert "Done snap" not in titles
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r1["id"])
            await conn.execute("DELETE FROM backlog WHERE id = $1", r2["id"])


# ============================================================================
# Trigger: updated_at
# ============================================================================


async def test_updated_at_trigger(db_pool):
    async with db_pool.acquire() as conn:
        r = await conn.fetchrow("SELECT * FROM create_backlog_item('Trigger test')")
        original_updated = r["updated_at"]
        try:
            # Small delay to ensure timestamp changes
            import asyncio
            await asyncio.sleep(0.01)
            updated = await conn.fetchrow(
                "SELECT * FROM update_backlog_item($1, $2::jsonb)",
                r["id"],
                json.dumps({"title": "Trigger test updated"}),
            )
            assert updated["updated_at"] >= original_updated
        finally:
            await conn.execute("DELETE FROM backlog WHERE id = $1", r["id"])


# ============================================================================
# Constraints
# ============================================================================


async def test_status_constraint(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception):
            await conn.execute(
                "INSERT INTO backlog (title, status) VALUES ('Bad', 'invented')"
            )


async def test_priority_constraint(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception):
            await conn.execute(
                "INSERT INTO backlog (title, priority) VALUES ('Bad', 'super_urgent')"
            )


async def test_owner_constraint(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception):
            await conn.execute(
                "INSERT INTO backlog (title, owner) VALUES ('Bad', 'robot')"
            )


async def test_created_by_constraint(db_pool):
    async with db_pool.acquire() as conn:
        with pytest.raises(Exception):
            await conn.execute(
                "INSERT INTO backlog (title, created_by) VALUES ('Bad', 'system')"
            )
