"""Unit tests for the ingested-document approval tool handlers (core/tools/documents.py)."""
from __future__ import annotations

import json

import pytest

from core.tools.base import ToolCategory, ToolExecutionContext, ToolContext
from core.tools.documents import (
    ListDocumentFadeRequestsHandler,
    ResolveDocumentFadeHandler,
    create_document_tools,
)


def test_document_toolset():
    names = {t.spec.name for t in create_document_tools()}
    assert names == {"list_document_fade_requests", "resolve_document_fade"}


def test_resolve_is_a_write_list_is_read_only():
    resolve = ResolveDocumentFadeHandler().spec
    assert resolve.name == "resolve_document_fade"
    assert resolve.is_read_only is False              # it deletes/retains the user's data
    assert set(resolve.parameters["required"]) == {"document", "decision"}
    assert resolve.parameters["properties"]["decision"]["enum"] == ["approve", "keep"]

    lst = ListDocumentFadeRequestsHandler().spec
    assert lst.is_read_only is True
    assert lst.category == ToolCategory.MEMORY


def test_registered_in_default_registry():
    import inspect
    from core.tools import registry as reg_mod
    src = inspect.getsource(reg_mod.create_default_registry)
    assert "create_document_tools()" in src


# ---- dispatch wiring (mock pool/conn) ----
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
    def __init__(self, result):
        self.result = result
        self.calls = []

    async def fetchval(self, query, *args):
        self.calls.append((query, args))
        return self.result


class _Registry:
    def __init__(self, pool):
        self.pool = pool


@pytest.mark.asyncio
async def test_resolve_handler_dispatches_to_db():
    conn = _Conn(json.dumps({"success": True, "output": {"decision": "approve", "label": "Doc", "faded": 3},
                             "display_output": 'Approve "Doc"'}))
    ctx = ToolExecutionContext(tool_context=ToolContext.CHAT, call_id="c1")
    ctx.registry = _Registry(_Pool(conn))
    result = await ResolveDocumentFadeHandler().execute({"document": "Doc", "decision": "approve"}, ctx)
    assert result.success
    # dispatched through execute_document_tool with the tool name + args
    assert "execute_document_tool" in conn.calls[0][0]
    assert conn.calls[0][1][0] == "resolve_document_fade"
    assert json.loads(conn.calls[0][1][1]) == {"document": "Doc", "decision": "approve"}


@pytest.mark.asyncio
async def test_list_handler_dispatches_to_db():
    conn = _Conn(json.dumps({"success": True, "output": [], "display_output": "Documents awaiting your approval to fade: 0"}))
    ctx = ToolExecutionContext(tool_context=ToolContext.CHAT, call_id="c2")
    ctx.registry = _Registry(_Pool(conn))
    result = await ListDocumentFadeRequestsHandler().execute({}, ctx)
    assert result.success
    assert conn.calls[0][1][0] == "list_document_fade_requests"
