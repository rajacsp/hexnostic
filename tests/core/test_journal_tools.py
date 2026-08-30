"""Unit tests for the journal tool handlers (core/tools/journal.py)."""
from __future__ import annotations

from core.tools.base import ToolCategory
from core.tools.journal import (
    ReadJournalHandler,
    SearchJournalHandler,
    WriteJournalHandler,
    create_journal_tools,
)


def test_journal_toolset():
    names = {t.spec.name for t in create_journal_tools()}
    assert names == {"write_journal", "read_journal", "search_journal"}


def test_write_journal_is_effortful_write():
    spec = WriteJournalHandler().spec
    assert spec.name == "write_journal"
    assert spec.is_read_only is False       # it's a write / authored act
    assert spec.energy_cost == 3            # deliberate, effortful
    assert "content" in spec.parameters["required"]


def test_read_and_search_are_read_only():
    for handler in (ReadJournalHandler(), SearchJournalHandler()):
        assert handler.spec.is_read_only is True
        assert handler.spec.category == ToolCategory.MEMORY


def test_registered_in_default_registry():
    # The journal tools must be wired into the default registry.
    import inspect

    from core.tools import registry as reg_mod

    src = inspect.getsource(reg_mod.create_default_registry)
    assert "create_journal_tools()" in src
