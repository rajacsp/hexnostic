#!/usr/bin/env python3
"""Advisory audit for Python logic that should migrate into Postgres.

Slice 0 intentionally reports findings without failing. Later migration slices
can promote subsystem-specific rules to blocking once the relevant logic has
been moved into SQL.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


DEFAULT_ROOTS = ("core", "services", "channels", "apps")
EXCLUDED_PARTS = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "docs",
    "tests",
}


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern[str]
    message: str


RULES = (
    Rule(
        "config_branching",
        re.compile(r"\b(get_config|get_config_bool|get_config_int|get_config_text|config_keys|FROM\s+config|WHERE\s+key\s*=)", re.I),
        "Config-driven domain branching should move into SQL functions.",
    ),
    Rule(
        "direct_domain_sql",
        re.compile(r"\b(INSERT\s+INTO|UPDATE\s+[a-zA-Z_][\w]*|DELETE\s+FROM|SELECT\s+set_config)\b", re.I),
        "Direct domain-state mutation should usually be wrapped by a DB function.",
    ),
    Rule(
        "prompt_assembly",
        re.compile(r"\b(load_[a-z0-9_]*prompt|compose_personhood_prompt|services/prompts|PROMPT_PATH)\b", re.I),
        "Prompt selection and assembly should move to DB prompt modules.",
    ),
    Rule(
        "policy_state_machine",
        re.compile(r"\b(energy_budget|max_iterations|route_status|delivery_mode|tool_context|on_error|continuation_prompt|stop_reason|stopped_reason)\b", re.I),
        "Policy/state-machine decisions should move into SQL-owned runtime state.",
    ),
    Rule(
        "workflow_or_schedule_logic",
        re.compile(r"\b(topological|croniter|next_run|schedule_kind|depends_on|max_retries|retry)\b", re.I),
        "Workflow and scheduling logic should be DB-owned.",
    ),
)


def iter_python_files(repo_root: Path, roots: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for root_name in roots:
        root = repo_root / root_name
        if not root.exists():
            continue
        for path in root.rglob("*.py"):
            if any(part in EXCLUDED_PARTS for part in path.relative_to(repo_root).parts):
                continue
            files.append(path)
    return sorted(files)


def audit_file(repo_root: Path, path: Path) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        return findings
    for line_no, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        for rule in RULES:
            if rule.pattern.search(line):
                findings.append(
                    {
                        "file": str(path.relative_to(repo_root)),
                        "line": line_no,
                        "rule": rule.name,
                        "message": rule.message,
                        "text": stripped[:180],
                    }
                )
    return findings


def run_audit(repo_root: Path, roots: tuple[str, ...]) -> dict[str, object]:
    findings: list[dict[str, object]] = []
    for path in iter_python_files(repo_root, roots):
        findings.extend(audit_file(repo_root, path))

    by_rule: dict[str, int] = {}
    by_file: dict[str, int] = {}
    for finding in findings:
        by_rule[str(finding["rule"])] = by_rule.get(str(finding["rule"]), 0) + 1
        by_file[str(finding["file"])] = by_file.get(str(finding["file"]), 0) + 1

    return {
        "status": "advisory",
        "root": str(repo_root),
        "roots_scanned": list(roots),
        "finding_count": len(findings),
        "by_rule": dict(sorted(by_rule.items())),
        "by_file": dict(sorted(by_file.items(), key=lambda item: (-item[1], item[0]))),
        "findings": findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Advisory audit for Python logic that should migrate into Postgres.")
    parser.add_argument("--root", default=".", help="Repository root to scan.")
    parser.add_argument("--roots", nargs="*", default=list(DEFAULT_ROOTS), help="Top-level Python directories to scan.")
    parser.add_argument("--json", action="store_true", help="Emit full JSON findings.")
    parser.add_argument("--limit", type=int, default=40, help="Text output finding limit.")
    args = parser.parse_args()

    repo_root = Path(args.root).resolve()
    payload = run_audit(repo_root, tuple(args.roots))

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"DB-brain audit status: {payload['status']}")
        print(f"Findings: {payload['finding_count']}")
        print("By rule:")
        for rule, count in payload["by_rule"].items():  # type: ignore[union-attr]
            print(f"  {rule}: {count}")
        print("Top findings:")
        for finding in payload["findings"][: args.limit]:  # type: ignore[index]
            print(f"  {finding['file']}:{finding['line']} [{finding['rule']}] {finding['text']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
