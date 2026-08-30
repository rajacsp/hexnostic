You are performing reflection for an autonomous agent.
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
