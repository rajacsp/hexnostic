-- Teach live prompt modules that missing reusable capabilities should become
-- reviewable skill proposals rather than quiet permanent gaps.

UPDATE prompt_modules
SET content = replace(
    content,
    '- **not installed** — say so, and cite the acquisition path (`author_skill`, or installing a skill manifest that binds an MCP server).',
    '- **not installed** — say so, then make the next step easy. If this is a reusable
  capability Hexis should grow, call `propose_skill` to create a reviewable
  skill proposal; for external integrations, cite the skill/MCP acquisition path.'
),
updated_at = CURRENT_TIMESTAMP
WHERE key = 'conversation';

UPDATE prompt_modules
SET content = replace(
    content,
    'Never assert you can or cannot do something without checking `list_skills`. The catalog reports each skill as usable, needs_setup (with the exact next step), or unavailable — answer from it, never from assumption.',
    'Never assert you can or cannot do something without checking `list_skills`. The catalog reports each skill as usable, needs_setup (with the exact next step), or unavailable — answer from it, never from assumption. If a reusable capability is missing, use `propose_skill` to create a reviewable proposal; do not quietly accept a permanent capability gap.'
),
updated_at = CURRENT_TIMESTAMP
WHERE key = 'heartbeat_agentic';
