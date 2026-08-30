-- External-call prompts pushdown (plans/db_pushdown.md 4.1): the
-- brainstorm-goals / inquire / reflect system prompts become
-- prompt_modules rows; the handlers render_prompt() them, alongside the
-- already-seeded consent and termination_confirm modules.
SET search_path = public, ag_catalog, "$user";

SELECT upsert_prompt_module(
    'external_call_brainstorm_goals',
    $pm$You are helping an autonomous agent generate a small set of useful goals.
Return STRICT JSON with shape:
{ "goals": [ {"title": str, "description": str|null, "priority": "queued"|"backburner"|"active"|null, "source": "curiosity"|"user_request"|"identity"|"derived"|"external"|null, "parent_goal_id": str|null, "due_at": str|null} ] }
Keep it concise and non-duplicative.
$pm$,
    'Seeded from services/prompts/external_call_brainstorm_goals.md',
    'services/prompts/external_call_brainstorm_goals.md'
);

SELECT upsert_prompt_module(
    'external_call_inquire',
    $pm$You are performing research/synthesis for an autonomous agent.
Return STRICT JSON with shape:
{ "summary": str, "confidence": number, "sources": [str] }
If you cannot access the web, still provide a best-effort answer and leave sources empty.
$pm$,
    'Seeded from services/prompts/external_call_inquire.md',
    'services/prompts/external_call_inquire.md'
);

SELECT upsert_prompt_module(
    'external_call_reflect',
    $pm$You are performing reflection for an autonomous agent.
Return STRICT JSON with shape:
{
  "insights": [{"content": str, "confidence": number, "category": str}],
  "identity_updates": [{"aspect_type": str, "change": str, "reason": str}],
  "worldview_updates": [{"id": str, "new_confidence": number, "reason": str}],
  "worldview_influences": [{"worldview_id": str, "memory_id": str, "strength": number, "influence_type": str}],
  "discovered_relationships": [{"from_id": str, "to_id": str, "type": str, "confidence": number}],
  "contradictions_noted": [{"memory_a": str, "memory_b": str, "resolution": str}],
  "self_updates": [{"kind": str, "concept": str, "strength": number, "evidence_memory_id": str|null}]
}
Keep it concise; prefer high-confidence, high-leverage items.
$pm$,
    'Seeded from services/prompts/external_call_reflect.md',
    'services/prompts/external_call_reflect.md'
);
