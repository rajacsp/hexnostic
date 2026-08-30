"""Tool-skill coverage (#99): every registered non-internal tool must be
reachable — bound by at least one installed skill (bundled or
agent-authored) or explicitly marked internal. The skill-first surface
means an unbound tool is a hand the agent cannot use; this test converts
that silent failure class into a build failure.

The grandfather set below covers the speculative integrations awaiting
extraction into plugins (#99 stage 4). It must only ever SHRINK — any new
tool landing unbound fails immediately.
"""
from __future__ import annotations

from pathlib import Path

# Shrinks to empty as #99 stage 4 extracts these into plugins/installed/.
GRANDFATHERED_UNBOUND: set[str] = set()  # emptied by #99 stage 4 — the
# seven speculative integrations now live in plugins/installed/


def _bound_tool_names() -> set[str]:
    """Use the project's own skill loader — same parsing the runtime uses."""
    from services.skill_runtime import skill_bound_tools
    from skills.loader import load_skills_from_dir

    bound: set[str] = set()
    roots = [Path(__file__).resolve().parents[2] / "skills" / "installed"]
    agent_dir = Path.home() / ".hexis" / "skills" / "agent-authored"
    if agent_dir.exists():
        roots.append(agent_dir)
    for root in roots:
        for skill in load_skills_from_dir(root):
            bound.update(skill_bound_tools(skill))
    return bound


def test_every_tool_is_bound_or_internal():
    from core.tools.registry import create_default_registry

    registry = create_default_registry(pool=None)
    bound = _bound_tool_names()

    unbound = []
    for name in registry.list_names():
        spec = registry.get_spec(name)
        if spec is None or getattr(spec, "internal", False):
            continue
        if name in bound:
            continue
        if name in GRANDFATHERED_UNBOUND:
            continue
        unbound.append(name)

    assert not unbound, (
        "Unreachable tools (registered but bound by no skill and not marked "
        f"internal): {sorted(unbound)}. Bind them in a SKILL.md, mark the "
        "spec internal=True, or (only for plugin-extraction candidates) add "
        "to GRANDFATHERED_UNBOUND with a shrink plan."
    )


def test_grandfather_list_only_shrinks():
    """Grandfathered names must still exist in the registry — a stale entry
    means the extraction landed and the list must shrink."""
    from core.tools.registry import create_default_registry

    registry = create_default_registry(pool=None)
    names = set(registry.list_names())
    stale = GRANDFATHERED_UNBOUND - names
    assert not stale, (
        f"Grandfather entries no longer registered (extracted?): {sorted(stale)} "
        "— remove them from GRANDFATHERED_UNBOUND."
    )
