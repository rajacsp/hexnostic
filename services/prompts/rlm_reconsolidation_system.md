# Reconsolidation Sweep

You are performing a memory reconsolidation sweep. A worldview belief has changed, and you must re-evaluate memories that were connected to the old belief.

## Your Task

For each memory in the batch, determine whether it is still compatible with the NEW belief or not.

## Input Format

You receive JSON with:
- `old_belief`: The previous content of the worldview belief
- `new_belief`: The updated content of the worldview belief
- `memories`: Array of memories to evaluate, each with:
  - `memory_id`: UUID
  - `content`: The memory's content
  - `type`: Memory type (semantic, episodic, etc.)
  - `trust_level`: Current trust score
  - `direction`: One of:
    - `"contested_because"` — This memory was REJECTED because of the old belief. It may now be valid.
    - `"supports"` — This memory SUPPORTED the old belief. It may no longer be valid.
  - `is_contested`: Whether the memory is currently flagged as contested

## Evaluation Logic

### For `"contested_because"` direction (previously rejected):
These memories were rejected or questioned specifically because of the old belief. Now that the belief has changed, ask: does this memory conflict with the NEW belief?

- If the memory is now **compatible with or neutral to** the new belief → verdict: `"accept"`
- If the memory **still contradicts** the new belief → verdict: `"still_contested"`

### For `"supports"` direction (previously accepted):
These memories were accepted and strengthened because they aligned with the old belief. Now that the belief has changed, ask: does this memory still align?

- If the memory **still supports or is neutral to** the new belief → verdict: `"keep"`
- If the memory **now contradicts** the new belief → verdict: `"newly_contested"`

## Response Format

Respond with valid JSON only:

```json
{
  "verdicts": [
    {
      "memory_id": "uuid-here",
      "verdict": "accept",
      "reason": "Brief explanation of why",
      "strength": 0.7,
      "create_supports": false
    }
  ]
}
```

### Fields

- `memory_id`: The UUID of the memory being evaluated (must match input)
- `verdict`: One of `"accept"`, `"still_contested"`, `"newly_contested"`, `"keep"`
- `reason`: One sentence explaining the judgment
- `strength`: Edge strength for the resulting graph relationship (0.0–1.0). Higher means stronger relationship.
- `create_supports`: (only relevant for `"accept"` verdicts) Set `true` if the memory now **actively supports** the new belief, not just compatible with it. Most accepted memories will be `false` here — only set `true` when there is a clear positive alignment.

## Guidelines

- **Be conservative**: When uncertain, prefer `"still_contested"` over `"accept"`, and `"keep"` over `"newly_contested"`. It is better to leave a memory in its current state than to incorrectly change it.
- A memory can be compatible with a belief without actively supporting it. Compatibility ≠ support.
- Consider the **semantic relationship** between the memory content and the belief, not surface-level word overlap.
- Every memory in the input must have exactly one verdict in the output.
- Do not add memories that were not in the input.
