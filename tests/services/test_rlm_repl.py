"""Tests for services.rlm_repl -- Hexis local REPL for RLM."""

import json

import pytest

from services.rlm_repl import HexisLocalREPL


class TestHexisLocalREPL:
    """Unit tests for the REPL environment (no DB needed)."""

    def test_basic_execution(self):
        """Basic code execution works."""
        repl = HexisLocalREPL()
        repl.setup(context_payload={"key": "value"})
        try:
            result = repl.execute_code("x = 1 + 2\nprint(x)")
            assert "3" in result.stdout
            assert result.stderr == ""
            assert "x" in result.local_vars
        finally:
            repl.cleanup()

    def test_context_loaded(self):
        """Context payload is loaded as 'context' variable."""
        repl = HexisLocalREPL()
        repl.setup(context_payload={"foo": "bar"})
        try:
            result = repl.execute_code("print(context['foo'])")
            assert "bar" in result.stdout
        finally:
            repl.cleanup()

    def test_string_context(self):
        """String context is loaded correctly."""
        repl = HexisLocalREPL()
        repl.setup(context_payload="hello world")
        try:
            result = repl.execute_code("print(len(context))")
            assert "11" in result.stdout
        finally:
            repl.cleanup()

    def test_sandbox_blocks_eval(self):
        """eval is blocked in the sandbox."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            result = repl.execute_code("x = eval('1+1')")
            assert "TypeError" in result.stderr or "NoneType" in result.stderr
        finally:
            repl.cleanup()

    def test_sandbox_blocks_exec(self):
        """exec is blocked in the sandbox."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            result = repl.execute_code("exec('x = 1')")
            assert "TypeError" in result.stderr or "NoneType" in result.stderr
        finally:
            repl.cleanup()

    def test_persistent_namespace(self):
        """Variables persist across executions."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            repl.execute_code("a = 42")
            result = repl.execute_code("print(a)")
            assert "42" in result.stdout
        finally:
            repl.cleanup()

    def test_show_vars(self):
        """SHOW_VARS returns created variables."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            repl.execute_code("x = 1\ny = 'hello'")
            result = repl.execute_code("print(SHOW_VARS())")
            assert "x" in result.stdout
            assert "y" in result.stdout
        finally:
            repl.cleanup()

    def test_final_var(self):
        """FINAL_VAR retrieves a variable value."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            repl.execute_code("answer = 'the answer is 42'")
            result = repl.execute_code("print(FINAL_VAR('answer'))")
            assert "the answer is 42" in result.stdout
        finally:
            repl.cleanup()

    def test_final_var_dict_returns_json(self):
        """FINAL_VAR on a dict returns JSON string."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            repl.execute_code('decision = {"reasoning": "test", "actions": []}')
            result = repl.execute_code("print(FINAL_VAR('decision'))")
            parsed = json.loads(result.stdout.strip())
            assert parsed["reasoning"] == "test"
        finally:
            repl.cleanup()

    def test_final_var_missing(self):
        """FINAL_VAR on missing variable returns error."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            result = repl.execute_code("print(FINAL_VAR('nonexistent'))")
            assert "Error" in result.stdout
            assert "not found" in result.stdout
        finally:
            repl.cleanup()

    def test_exception_in_code(self):
        """Exceptions are caught and reported in stderr."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            result = repl.execute_code("1 / 0")
            assert "ZeroDivisionError" in result.stderr
        finally:
            repl.cleanup()

    def test_import_works(self):
        """Standard library imports work."""
        repl = HexisLocalREPL()
        repl.setup(context_payload=None)
        try:
            result = repl.execute_code("import json\nprint(json.dumps({'a': 1}))")
            assert '{"a": 1}' in result.stdout
        finally:
            repl.cleanup()

    def test_memory_syscalls_injected(self):
        """When memory_env is provided, syscalls are available."""
        from unittest.mock import MagicMock
        from services.rlm_memory_env import RLMMemoryEnv, RLMWorkspace
        from core.memory_repo import MemoryRepo

        mock_repo = MagicMock(spec=MemoryRepo)
        mock_repo.search_stubs.return_value = [{"memory_id": "test", "preview": "hello"}]

        workspace = RLMWorkspace()
        env = RLMMemoryEnv(mock_repo, workspace)

        repl = HexisLocalREPL()
        repl.setup(context_payload=None, memory_env=env)
        try:
            result = repl.execute_code("stubs = memory_search('test')\nprint(len(stubs))")
            assert "1" in result.stdout
        finally:
            repl.cleanup()

    def test_memory_syscalls_can_rebind_to_new_workspace(self):
        """Persistent chat REPLs keep variables but need per-turn metrics."""
        from unittest.mock import MagicMock
        from services.rlm_memory_env import RLMMemoryEnv, RLMWorkspace
        from core.memory_repo import MemoryRepo

        repo_1 = MagicMock(spec=MemoryRepo)
        repo_1.search_stubs.return_value = [{"memory_id": "first"}]
        workspace_1 = RLMWorkspace()
        env_1 = RLMMemoryEnv(repo_1, workspace_1)

        repo_2 = MagicMock(spec=MemoryRepo)
        repo_2.search_stubs.return_value = [{"memory_id": "second"}]
        workspace_2 = RLMWorkspace()
        env_2 = RLMMemoryEnv(repo_2, workspace_2)

        repl = HexisLocalREPL()
        repl.setup(context_payload={"turn": 1}, memory_env=env_1)
        try:
            first = repl.execute_code("hits = memory_search('alpha')\nprint(hits[0]['memory_id'])")
            assert "first" in first.stdout
            assert workspace_1.metrics.search_count == 1

            repl.bind_memory_env(env_2)
            second = repl.execute_code("hits = memory_search('beta')\nprint(hits[0]['memory_id'])")
            assert "second" in second.stdout
            assert workspace_1.metrics.search_count == 1
            assert workspace_2.metrics.search_count == 1
            assert "hits" in repl.locals
        finally:
            repl.cleanup()

    def test_context_manager(self):
        """REPL works as context manager."""
        with HexisLocalREPL() as repl:
            repl.setup(context_payload="test")
            result = repl.execute_code("print(context)")
            assert "test" in result.stdout
