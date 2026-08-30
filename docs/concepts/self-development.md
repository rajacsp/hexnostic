<!--
title: Self-Development
summary: Subconscious and conscious growth mechanisms
read_when:
  - "You want to understand how the agent grows"
  - "You want to understand subconscious maintenance"
section: concepts
-->

# Self-Development

Hexis agents develop over time through both subconscious pattern detection and conscious deliberation.

## In Brief

The subconscious layer (maintenance worker) observes patterns and records observations. The conscious layer (heartbeat) makes deliberate choices in response. Growth happens through the interplay between automatic pattern detection and intentional reflection.

## What Develops Automatically (Subconscious)

The subconscious decider runs on a maintenance schedule and emits **observations**, not actions. These are persisted as strategic memories or graph edges for the conscious layer to see.

### Narrative Moments

- Life chapters are updated via `ensure_current_life_chapter()`
- Turning points are tagged by raising memory importance and writing strategic memories

### Relationships

- Relationship edges stored as `SelfNode` -> `ConceptNode` with `kind='relationship'`
- Strength adjusted based on observed interactions

### Contradictions

- `CONTRADICTS` edges created between memory nodes
- Coherence drive nudged upward to surface the tension for conscious resolution

### Emotional Patterns

- Strategic memories with `supporting_evidence.kind = 'emotional_pattern'` are created
- The agent can notice patterns like "I consistently feel constrained when social energy costs are high"

### Consolidation

- `ASSOCIATED` edges link related memories
- Concepts extracted with `link_memory_to_concept()`

## What Requires Conscious Attention

The conscious layer (heartbeat + chat) handles deliberate choices:

- **Goal selection and reprioritization** -- which goals to pursue
- **External outreach** -- reaching out to users or publicly
- **Contradiction resolution** -- resolving or explicitly accepting contradictions
- **Narrative commitments** -- explicit chapter closure
- **Self-termination decisions** -- the most consequential choice

## Growth Flow

1. A heartbeat records an episodic memory
2. The subconscious notices a pattern (e.g., repeated avoidance, chapter transition)
3. It records a strategic memory and/or updates narrative context
4. The next heartbeat sees the updated context and can respond deliberately

## Structures That Encode Growth

| Structure | Storage | Purpose |
|-----------|---------|---------|
| Worldview memories | `memories` (type='worldview') | Beliefs, self-understanding |
| Self-model edges | `SelfNode` -> `ConceptNode` | Values, capabilities, limitations |
| Narrative context | `LifeChapterNode` | Life chapters and transitions |
| Contradictions | `CONTRADICTS` graph edges | Unresolved tensions |
| Emotional patterns | Strategic memories | Recurring emotional observations |

## Configuration

| Config Key | Description |
|------------|-------------|
| `maintenance.subconscious_enabled` | Toggle subconscious decider |
| `maintenance.subconscious_interval_seconds` | Decider cadence |
| `llm.subconscious` | Model for subconscious pattern detection |

## Related

- [Identity and Worldview](identity-and-worldview.md) -- what identity consists of
- [Heartbeat System](heartbeat-system.md) -- the conscious decision loop
- [Memory Architecture](memory-architecture.md) -- how growth is stored
