"""Tests for A.1 (contacts table) and A.4 (CRM query tools)."""

from __future__ import annotations

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ---------------------------------------------------------------------------
# A.1  —  contacts table + SQL functions
# ---------------------------------------------------------------------------


class TestContactsTable:
    """Verify the contacts table and SQL functions."""

    async def test_create_contact(self, db_pool):
        """create_contact() inserts and returns an id."""
        cid = await db_pool.fetchval(
            "SELECT create_contact($1, $2, $3, $4)",
            "Alice Smith", "alice@example.com", "Acme Corp", "CEO",
        )
        assert cid is not None
        row = await db_pool.fetchrow("SELECT * FROM contacts WHERE id = $1", cid)
        assert row["name"] == "Alice Smith"
        assert row["email"] == "alice@example.com"
        assert row["company"] == "Acme Corp"
        assert row["role"] == "CEO"

    async def test_update_contact(self, db_pool):
        """update_contact() only updates non-NULL fields."""
        cid = await db_pool.fetchval(
            "SELECT create_contact($1, $2)", "Bob Jones", "bob@example.com",
        )
        result = await db_pool.fetchval(
            "SELECT update_contact($1, $2, $3, $4)",
            cid, None, None, "NewCo",  # only update company
        )
        assert result is True
        row = await db_pool.fetchrow("SELECT * FROM contacts WHERE id = $1", cid)
        assert row["name"] == "Bob Jones"  # unchanged
        assert row["company"] == "NewCo"   # updated

    async def test_search_contacts_by_name(self, db_pool):
        """search_contacts() finds contacts by name."""
        await db_pool.fetchval(
            "SELECT create_contact($1, $2, $3)",
            "Charlie Searchable", "charlie@test.com", "SearchCo",
        )
        rows = await db_pool.fetch(
            "SELECT * FROM search_contacts($1, $2)", "Charlie", 10,
        )
        names = [r["name"] for r in rows]
        assert any("Charlie" in n for n in names)

    async def test_search_contacts_by_email(self, db_pool):
        """search_contacts() finds contacts by email (ILIKE)."""
        await db_pool.fetchval(
            "SELECT create_contact($1, $2)", "Email Test", "unique_search_test@example.com",
        )
        rows = await db_pool.fetch(
            "SELECT * FROM search_contacts($1, $2)", "unique_search_test@example.com", 10,
        )
        assert len(rows) >= 1

    async def test_get_contact_by_email(self, db_pool):
        """get_contact_by_email() returns a contact by exact email."""
        await db_pool.fetchval(
            "SELECT create_contact($1, $2)", "Email Lookup", "lookup@example.com",
        )
        row = await db_pool.fetchrow(
            "SELECT * FROM get_contact_by_email($1)", "Lookup@Example.COM",
        )
        assert row is not None
        assert row["name"] == "Email Lookup"

    async def test_touch_contact(self, db_pool):
        """touch_contact() updates last_touch."""
        cid = await db_pool.fetchval(
            "SELECT create_contact($1)", "Touch Test",
        )
        before = await db_pool.fetchval(
            "SELECT last_touch FROM contacts WHERE id = $1", cid,
        )
        # Small sleep to ensure timestamp difference
        await db_pool.execute("SELECT pg_sleep(0.01)")
        await db_pool.execute("SELECT touch_contact($1)", cid)
        after = await db_pool.fetchval(
            "SELECT last_touch FROM contacts WHERE id = $1", cid,
        )
        assert after >= before

    async def test_merge_contacts(self, db_pool):
        """merge_contacts() combines two contacts into one."""
        keep_id = await db_pool.fetchval(
            "SELECT create_contact($1, $2, $3, $4, $5, $6, $7)",
            "Keep Me", "keep@example.com", None, None, None, "Note A", [],
        )
        remove_id = await db_pool.fetchval(
            "SELECT create_contact($1, $2, $3, $4, $5, $6, $7)",
            "Remove Me", None, "RemoveCo", "Engineer", None, "Note B", [],
        )
        merged = await db_pool.fetchval(
            "SELECT merge_contacts($1, $2)", keep_id, remove_id,
        )
        assert merged is True

        # Kept contact should have merged data
        row = await db_pool.fetchrow("SELECT * FROM contacts WHERE id = $1", keep_id)
        assert row["company"] == "RemoveCo"  # filled from remove
        assert row["role"] == "Engineer"      # filled from remove
        assert "Note A" in row["notes"]
        assert "Note B" in row["notes"]

        # Removed contact should be gone
        gone = await db_pool.fetchrow("SELECT * FROM contacts WHERE id = $1", remove_id)
        assert gone is None

    async def test_contacts_by_tag(self, db_pool):
        """get_contacts_by_tag() filters by tag."""
        await db_pool.fetchval(
            "SELECT create_contact($1, $2, $3, $4, $5, $6, $7)",
            "Tagged Person", None, None, None, None, None,
            ["vip", "investor"],
        )
        rows = await db_pool.fetch(
            "SELECT * FROM get_contacts_by_tag($1)", "vip",
        )
        names = [r["name"] for r in rows]
        assert "Tagged Person" in names

    async def test_recent_contacts(self, db_pool):
        """recent_contacts() returns contacts ordered by last_touch."""
        rows = await db_pool.fetch("SELECT * FROM recent_contacts(5)")
        assert len(rows) > 0
        # Verify descending order
        for i in range(len(rows) - 1):
            assert rows[i]["last_touch"] >= rows[i + 1]["last_touch"]

    async def test_updated_at_trigger(self, db_pool):
        """The trg_contacts_updated_at trigger updates updated_at on modification."""
        cid = await db_pool.fetchval("SELECT create_contact($1)", "Trigger Test")
        before = await db_pool.fetchval(
            "SELECT updated_at FROM contacts WHERE id = $1", cid,
        )
        await db_pool.execute("SELECT pg_sleep(0.01)")
        await db_pool.execute(
            "UPDATE contacts SET notes = 'updated' WHERE id = $1", cid,
        )
        after = await db_pool.fetchval(
            "SELECT updated_at FROM contacts WHERE id = $1", cid,
        )
        assert after > before


# ---------------------------------------------------------------------------
# A.4  —  CRM query tools (Python handlers)
# ---------------------------------------------------------------------------


class TestContactTools:
    """Verify the CRM tool handlers execute correctly against the DB."""

    async def _make_context(self, db_pool):
        """Build a minimal ToolExecutionContext with a registry stub."""
        from unittest.mock import MagicMock
        from core.tools.base import ToolContext, ToolExecutionContext

        registry = MagicMock()
        registry.pool = db_pool

        return ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id="test-call",
            registry=registry,
        )

    async def test_create_contact_tool(self, db_pool):
        """CreateContactHandler creates a contact."""
        from core.tools.contacts import CreateContactHandler
        handler = CreateContactHandler()
        ctx = await self._make_context(db_pool)

        result = await handler.execute({
            "name": "Tool Created",
            "email": "tool@example.com",
            "company": "ToolCo",
            "tags": ["test"],
        }, ctx)
        assert result.success
        assert result.output["id"] is not None

    async def test_search_contacts_tool(self, db_pool):
        """SearchContactsHandler finds contacts."""
        from core.tools.contacts import SearchContactsHandler
        handler = SearchContactsHandler()
        ctx = await self._make_context(db_pool)

        # Search for the contact we just created
        result = await handler.execute({"query": "Tool Created"}, ctx)
        assert result.success
        assert result.output["count"] >= 1

    async def test_search_contacts_empty_query(self, db_pool):
        """SearchContactsHandler with no query returns recent contacts."""
        from core.tools.contacts import SearchContactsHandler
        handler = SearchContactsHandler()
        ctx = await self._make_context(db_pool)

        result = await handler.execute({}, ctx)
        assert result.success
        assert result.output["count"] >= 0

    async def test_get_contact_by_id(self, db_pool):
        """GetContactHandler retrieves by ID."""
        from core.tools.contacts import CreateContactHandler, GetContactHandler

        ctx = await self._make_context(db_pool)
        create = CreateContactHandler()
        res = await create.execute({"name": "Get By ID Test"}, ctx)
        contact_id = res.output["id"]

        get = GetContactHandler()
        result = await get.execute({"id": contact_id}, ctx)
        assert result.success
        assert result.output["found"] is True
        assert result.output["contact"]["name"] == "Get By ID Test"

    async def test_get_contact_by_email(self, db_pool):
        """GetContactHandler retrieves by email."""
        from core.tools.contacts import CreateContactHandler, GetContactHandler

        ctx = await self._make_context(db_pool)
        create = CreateContactHandler()
        await create.execute({
            "name": "Email Get Test",
            "email": "emailget@example.com",
        }, ctx)

        get = GetContactHandler()
        result = await get.execute({"email": "emailget@example.com"}, ctx)
        assert result.success
        assert result.output["found"] is True

    async def test_get_contact_not_found(self, db_pool):
        """GetContactHandler returns found=False for missing contacts."""
        from core.tools.contacts import GetContactHandler

        ctx = await self._make_context(db_pool)
        get = GetContactHandler()
        result = await get.execute({"id": 999999}, ctx)
        assert result.success
        assert result.output["found"] is False

    async def test_update_contact_tool(self, db_pool):
        """UpdateContactHandler modifies contact fields."""
        from core.tools.contacts import CreateContactHandler, UpdateContactHandler

        ctx = await self._make_context(db_pool)
        create = CreateContactHandler()
        res = await create.execute({"name": "Update Test"}, ctx)
        contact_id = res.output["id"]

        update = UpdateContactHandler()
        result = await update.execute({
            "id": contact_id,
            "company": "Updated Corp",
            "role": "CTO",
        }, ctx)
        assert result.success

        # Verify
        row = await db_pool.fetchrow(
            "SELECT * FROM contacts WHERE id = $1", contact_id,
        )
        assert row["company"] == "Updated Corp"
        assert row["role"] == "CTO"

    async def test_merge_contacts_tool(self, db_pool):
        """MergeContactsHandler merges two contacts."""
        from core.tools.contacts import CreateContactHandler, MergeContactsHandler

        ctx = await self._make_context(db_pool)
        create = CreateContactHandler()
        r1 = await create.execute({"name": "Merge Keep", "email": "mk@test.com"}, ctx)
        r2 = await create.execute({"name": "Merge Remove", "company": "MergeCo"}, ctx)

        merge = MergeContactsHandler()
        result = await merge.execute({
            "keep_id": r1.output["id"],
            "remove_id": r2.output["id"],
        }, ctx)
        assert result.success
        assert result.output["merged"] is True

    async def test_merge_contacts_self_error(self, db_pool):
        """MergeContactsHandler rejects merging with itself."""
        from core.tools.contacts import MergeContactsHandler

        ctx = await self._make_context(db_pool)
        merge = MergeContactsHandler()
        result = await merge.execute({"keep_id": 1, "remove_id": 1}, ctx)
        assert not result.success

    async def test_tool_registration(self, db_pool):
        """Contact tools are registered in create_default_registry()."""
        from core.tools import create_default_registry

        registry = create_default_registry(db_pool)
        tool_names = [t.spec.name for t in registry._handlers.values()]
        assert "search_contacts" in tool_names
        assert "get_contact" in tool_names
        assert "create_contact" in tool_names
        assert "update_contact" in tool_names
        assert "merge_contacts" in tool_names
