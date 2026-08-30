"""Standalone runner: `python -m evals.retrieval.run` executes the retrieval
eval suite (tier 1; add HEXIS_EVAL_FULL=1 for tier 2) and prints the report.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1] / "out" / "retrieval_report.json"


def main() -> int:
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "evals/retrieval", "-q"],
        cwd=str(Path(__file__).resolve().parents[2]),
    )
    if REPORT.exists():
        payload = json.loads(REPORT.read_text())
        agg = payload.get("aggregates", {})
        print(f"\n=== retrieval eval: {agg.get('passed')}/{agg.get('tasks')} tasks passed ===")
        for task in payload.get("tasks", []):
            mark = "PASS" if task["passed"] else "FAIL"
            print(
                f"  [{mark}] {task['task']:<28} calls={task['tool_calls']:<3} "
                f"~tokens={task['approx_tokens']:<6} latency={task['latency_ms']}ms"
            )
        print(f"\nreport: {REPORT}")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
