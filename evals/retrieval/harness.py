"""Eval harness: run tool handlers while recording calls, output size, and
latency; collect per-task metrics into a JSON report."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

from core.tools.base import ToolContext, ToolExecutionContext

REPORT_DIR = Path(__file__).resolve().parents[1] / "out"


@dataclass
class TaskRecord:
    task: str
    passed: bool = False
    tool_calls: int = 0
    output_chars: int = 0
    latency_ms: float = 0.0
    detail: dict[str, Any] = field(default_factory=dict)


class EvalHarness:
    """Wraps handler execution with counters; one instance per task."""

    def __init__(self, pool, task: str, *, is_group: bool = False):
        self._pool = pool
        self.record = TaskRecord(task=task)
        self._is_group = is_group

    def context(self) -> ToolExecutionContext:
        registry = MagicMock()
        registry.pool = self._pool
        return ToolExecutionContext(
            tool_context=ToolContext.CHAT,
            call_id=f"eval-{self.record.task}",
            registry=registry,
            is_group=self._is_group,
        )

    async def call(self, handler, arguments: dict[str, Any]):
        start = time.perf_counter()
        result = await handler.execute(arguments, self.context())
        elapsed = (time.perf_counter() - start) * 1000
        self.record.tool_calls += 1
        self.record.latency_ms += elapsed
        if result.output is not None:
            try:
                self.record.output_chars += len(json.dumps(result.output, default=str))
            except (TypeError, ValueError):
                self.record.output_chars += len(str(result.output))
        return result


class ReportCollector:
    """Accumulates task records; the conftest fixture writes the report."""

    def __init__(self) -> None:
        self.records: list[TaskRecord] = []

    def add(self, harness: EvalHarness, *, passed: bool, **detail: Any) -> None:
        harness.record.passed = passed
        harness.record.detail.update(detail)
        self.records.append(harness.record)

    def write(self, path: Path | None = None) -> Path:
        target = path or (REPORT_DIR / "retrieval_report.json")
        target.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "suite": "retrieval",
            "tasks": [
                {
                    "task": r.task,
                    "passed": r.passed,
                    "tool_calls": r.tool_calls,
                    "output_chars": r.output_chars,
                    "approx_tokens": r.output_chars // 4,
                    "latency_ms": round(r.latency_ms, 1),
                    **({"detail": r.detail} if r.detail else {}),
                }
                for r in self.records
            ],
            "aggregates": {
                "tasks": len(self.records),
                "passed": sum(1 for r in self.records if r.passed),
                "total_tool_calls": sum(r.tool_calls for r in self.records),
                "total_output_chars": sum(r.output_chars for r in self.records),
                "total_latency_ms": round(sum(r.latency_ms for r in self.records), 1),
            },
        }
        target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return target
