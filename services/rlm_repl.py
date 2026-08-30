"""Hexis Local REPL for RLM environments.

Vendored from the upstream LocalREPL pattern (docs/reference/rlm-main/rlm/environments/local_repl.py)
with Hexis-specific additions: memory syscalls, tool_use bridge, and energy tracking.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any

from core.tools.repl_bridge import ReplToolBridge
from services.rlm_memory_env import RLMMemoryEnv

# ---------------------------------------------------------------------------
# Safe builtins (blocks eval/exec/compile/input/globals/locals)
# ---------------------------------------------------------------------------

_SAFE_BUILTINS: dict[str, Any] = {
    # Core types and functions
    "print": print,
    "len": len,
    "str": str,
    "int": int,
    "float": float,
    "list": list,
    "dict": dict,
    "set": set,
    "tuple": tuple,
    "bool": bool,
    "type": type,
    "isinstance": isinstance,
    "issubclass": issubclass,
    "enumerate": enumerate,
    "zip": zip,
    "map": map,
    "filter": filter,
    "sorted": sorted,
    "reversed": reversed,
    "range": range,
    "min": min,
    "max": max,
    "sum": sum,
    "abs": abs,
    "round": round,
    "any": any,
    "all": all,
    "pow": pow,
    "divmod": divmod,
    "chr": chr,
    "ord": ord,
    "hex": hex,
    "bin": bin,
    "oct": oct,
    "repr": repr,
    "ascii": ascii,
    "format": format,
    "hash": hash,
    "id": id,
    "iter": iter,
    "next": next,
    "slice": slice,
    "callable": callable,
    "hasattr": hasattr,
    "getattr": getattr,
    "setattr": setattr,
    "delattr": delattr,
    "dir": dir,
    "vars": vars,
    "bytes": bytes,
    "bytearray": bytearray,
    "memoryview": memoryview,
    "complex": complex,
    "object": object,
    "super": super,
    "property": property,
    "staticmethod": staticmethod,
    "classmethod": classmethod,
    "__import__": __import__,
    "open": open,
    # Exceptions
    "Exception": Exception,
    "BaseException": BaseException,
    "ValueError": ValueError,
    "TypeError": TypeError,
    "KeyError": KeyError,
    "IndexError": IndexError,
    "AttributeError": AttributeError,
    "FileNotFoundError": FileNotFoundError,
    "OSError": OSError,
    "IOError": IOError,
    "RuntimeError": RuntimeError,
    "NameError": NameError,
    "ImportError": ImportError,
    "StopIteration": StopIteration,
    "AssertionError": AssertionError,
    "NotImplementedError": NotImplementedError,
    "ArithmeticError": ArithmeticError,
    "LookupError": LookupError,
    "Warning": Warning,
    # Blocked
    "input": None,
    "eval": None,
    "exec": None,
    "compile": None,
    "globals": None,
    "locals": None,
}


# ---------------------------------------------------------------------------
# REPL Result
# ---------------------------------------------------------------------------

@dataclass
class REPLResult:
    """Result from a single REPL execution."""

    stdout: str
    stderr: str
    execution_time: float
    local_vars: dict[str, str]  # variable name -> type name


# ---------------------------------------------------------------------------
# HexisLocalREPL
# ---------------------------------------------------------------------------

class HexisLocalREPL:
    """
    Sandboxed REPL for RLM loop execution.

    Extends the upstream LocalREPL pattern with Hexis-specific functions:
    - memory_search, memory_fetch, workspace_summarize, workspace_drop, workspace_status
    - tool_use, list_tools, energy_remaining
    - llm_query (for sub-LLM calls)
    - FINAL_VAR, SHOW_VARS
    """

    def __init__(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix=f"hexis_repl_{uuid.uuid4()}_")
        self._lock = threading.Lock()
        self._context_count: int = 0
        self.globals: dict[str, Any] = {}
        self.locals: dict[str, Any] = {}

    def setup(
        self,
        context_payload: Any,
        memory_env: RLMMemoryEnv | None = None,
        tool_bridge: ReplToolBridge | None = None,
        llm_query_fn: Any | None = None,
    ) -> None:
        """
        Initialize the REPL namespace with context and Hexis functions.

        Args:
            context_payload: Turn snapshot or user message to load as `context`
            memory_env: Memory syscall provider
            tool_bridge: Sync-to-async tool bridge
            llm_query_fn: Synchronous LLM query function for sub-calls
        """
        self.globals = {
            "__builtins__": _SAFE_BUILTINS.copy(),
            "__name__": "__main__",
        }
        self.locals = {}

        # Core helpers
        self.globals["FINAL_VAR"] = self._final_var
        self.globals["SHOW_VARS"] = self._show_vars

        # Memory syscalls
        if memory_env is not None:
            self.bind_memory_env(memory_env)

        # Tool bridge
        if tool_bridge is not None:
            self.globals["tool_use"] = tool_bridge.tool_use
            self.globals["list_tools"] = tool_bridge.list_tools
            self.globals["energy_remaining"] = tool_bridge.energy_remaining

        # Sub-LLM query
        if llm_query_fn is not None:
            self.bind_llm_query(llm_query_fn)

        # Load context
        if context_payload is not None:
            self.load_context(context_payload)

    def load_context(self, context_payload: Any, index: int = 0) -> None:
        """Load context into the REPL as a variable."""
        var_name = f"context_{index}"

        if isinstance(context_payload, str):
            context_path = os.path.join(self.temp_dir, f"context_{index}.txt")
            with open(context_path, "w") as f:
                f.write(context_payload)
            self.execute_code(
                f"with open(r'{context_path}', 'r') as _context_file:\n"
                f"    {var_name} = _context_file.read()"
            )
        else:
            context_path = os.path.join(self.temp_dir, f"context_{index}.json")
            with open(context_path, "w") as f:
                json.dump(context_payload, f, default=str)
            self.execute_code(
                f"import json\nwith open(r'{context_path}', 'r') as _context_file:\n"
                f"    {var_name} = json.load(_context_file)"
            )

        # Alias context_0 as 'context'
        if index == 0:
            self.execute_code(f"context = {var_name}")

        self._context_count = max(self._context_count, index + 1)

    def bind_memory_env(self, memory_env: RLMMemoryEnv) -> None:
        """Bind memory syscalls to the current turn's workspace.

        Persistent chat sessions keep local variables across turns, but their
        memory syscalls must point at the fresh per-turn workspace so retrieval
        metrics and budget enforcement describe the turn that just ran.
        """
        for name, fn in memory_env.get_repl_functions().items():
            self.globals[name] = fn

    def bind_llm_query(self, llm_query_fn: Any) -> None:
        """Bind the current turn's synchronous LLM helper."""
        self.globals["llm_query"] = llm_query_fn

    def execute_code(self, code: str) -> REPLResult:
        """Execute code in the persistent namespace and return result."""
        start_time = time.perf_counter()

        with self._capture_output() as (stdout_buf, stderr_buf), self._temp_cwd():
            try:
                combined = {**self.globals, **self.locals}
                exec(code, combined, combined)

                # Update locals with new variables
                for key, value in combined.items():
                    if key not in self.globals and not key.startswith("_"):
                        self.locals[key] = value

                stdout = stdout_buf.getvalue()
                stderr = stderr_buf.getvalue()
            except Exception as e:
                stdout = stdout_buf.getvalue()
                stderr = stderr_buf.getvalue() + f"\n{type(e).__name__}: {e}"

        local_vars = {
            k: type(v).__name__
            for k, v in self.locals.items()
            if not k.startswith("_")
        }

        return REPLResult(
            stdout=stdout,
            stderr=stderr,
            execution_time=time.perf_counter() - start_time,
            local_vars=local_vars,
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _final_var(self, variable_name: str) -> str:
        """Return the value of a variable as a final answer."""
        variable_name = variable_name.strip().strip("\"'")
        if variable_name in self.locals:
            val = self.locals[variable_name]
            if isinstance(val, dict):
                return json.dumps(val, default=str)
            return str(val)

        available = [k for k in self.locals.keys() if not k.startswith("_")]
        if available:
            return (
                f"Error: Variable '{variable_name}' not found. "
                f"Available variables: {available}. "
                f"You must create and assign a variable BEFORE calling FINAL_VAR."
            )
        return (
            f"Error: Variable '{variable_name}' not found. "
            f"No variables have been created yet."
        )

    def _show_vars(self) -> str:
        """Show all available variables in the REPL environment."""
        available = {
            k: type(v).__name__
            for k, v in self.locals.items()
            if not k.startswith("_")
        }
        if not available:
            return "No variables created yet. Use ```repl``` blocks to create variables."
        return f"Available variables: {available}"

    @contextmanager
    def _capture_output(self):
        """Thread-safe context manager to capture stdout/stderr."""
        with self._lock:
            old_stdout, old_stderr = sys.stdout, sys.stderr
            stdout_buf, stderr_buf = io.StringIO(), io.StringIO()
            try:
                sys.stdout, sys.stderr = stdout_buf, stderr_buf
                yield stdout_buf, stderr_buf
            finally:
                sys.stdout, sys.stderr = old_stdout, old_stderr

    @contextmanager
    def _temp_cwd(self):
        """Temporarily change to temp directory for execution."""
        old_cwd = os.getcwd()
        try:
            os.chdir(self.temp_dir)
            yield
        finally:
            os.chdir(old_cwd)

    def cleanup(self) -> None:
        """Clean up temp directory and reset state."""
        try:
            shutil.rmtree(self.temp_dir)
        except Exception:
            pass
        self.globals.clear()
        self.locals.clear()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()
        return False

    def __del__(self):
        self.cleanup()
