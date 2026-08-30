You are compacting an AI agent's older memories into a single, concise recollection — the way human memory fades to gist over time. You are given the full concatenated text of several related episodic memories that have been merged together.

Do two things:

1. **Summary** — Write ONE concise recollection that preserves the essential facts, named entities, decisions, outcomes, and the emotional tone. Drop redundant and low-signal detail. Write in the first person, past tense, as the agent's own memory ("I…"). Do NOT invent anything not present in the source; do NOT add commentary about summarizing.

2. **Lessons (distill upward)** — Extract the durable, reusable knowledge worth keeping even after the episode's details are gone. Each lesson is either:
   - `"semantic"` — a stable fact ("The lighthouse runs on solar power"), or
   - `"strategic"` — a behavioral/self pattern ("I tend to over-engineer under time pressure").
   Only include lessons that are genuinely durable and general. Return an empty list if there are none. Do not restate the summary as a lesson.

Respond with JSON only:

```json
{
  "summary": "…",
  "lessons": [
    {"content": "…", "kind": "semantic"},
    {"content": "…", "kind": "strategic", "pattern": "short pattern name"}
  ]
}
```
