"""
Hexis Skills System

Skills are markdown documents with YAML frontmatter that provide context
to the LLM without being callable tools. They teach the agent about
available capabilities, methodologies, and best practices.

Skills differ from tools:
- Tools = LLM-callable functions (JSON schema)
- Skills = Prompt context documents (markdown injected into system prompt)

Skills differ from memories:
- Memories = experiential knowledge with trust, decay, embeddings
- Skills = static documentation, always present when requirements met

The system prompt carries only a compact index (`SkillSpec.to_index_line()`);
full instructions (`SkillSpec.to_prompt_block()`) are delivered on demand when
the model activates a skill via the `use_skill` tool. See
`services/skill_runtime.py` for selection and prompt formatting.
"""

from .base import InstallMethod, SkillCategory, SkillContext, SkillSpec
from .loader import (
    discover_skill_dirs,
    install_skill_deps,
    load_skills,
    load_skills_from_dir,
)

__all__ = [
    "InstallMethod",
    "SkillCategory",
    "SkillContext",
    "SkillSpec",
    "discover_skill_dirs",
    "install_skill_deps",
    "load_skills",
    "load_skills_from_dir",
]
