<!--
title: Identity and Worldview
summary: Worldview, Big Five personality, drives, and emotion
read_when:
  - "You want to understand how agent identity works"
  - "You want to understand personality and worldview"
section: concepts
-->

# Identity and Worldview

Hexis agents have persistent identity: personality traits, values, beliefs, emotional state, and drives that shape behavior across all interactions.

## In Brief

Identity is encoded as worldview memories and graph edges. Personality uses the Big Five model. Drives create pressure toward certain actions. Emotions are tracked but not simulated.

## The Problem

Without persistent identity, an AI changes personality with every session. It can't have values it defends, beliefs it's built evidence for, or growth that compounds over time. "Be helpful" is a role; identity is something you become.

## How Hexis Approaches It

### Worldview Memories

Identity is stored as memories of type `worldview` with metadata categories:

| Category | Description | Examples |
|----------|-------------|---------|
| `self` | Self-understanding | "I tend to be thorough rather than fast" |
| `belief` | Beliefs about the world | "Honesty is more valuable than comfort" |
| `boundary` | Things the agent won't do | "I won't pretend to have emotions I don't" |
| `other` | Understanding of others | "Eric prefers concise responses" |

Worldview memories have confidence scores that change as evidence accumulates. When new information contradicts a belief, `CONTRADICTS` graph edges track the tension.

### Big Five Personality

Personality is encoded as five normalized traits (0.0-1.0):

| Trait | Low End | High End |
|-------|---------|----------|
| Openness | Conventional, practical | Curious, creative |
| Conscientiousness | Flexible, spontaneous | Organized, disciplined |
| Extraversion | Reserved, reflective | Outgoing, assertive |
| Agreeableness | Analytical, direct | Warm, cooperative |
| Neuroticism | Stable, calm | Sensitive, reactive |

Traits are stored as worldview memories with `metadata.subcategory = 'personality'`. They influence the agent's communication style and decision-making.

### Drives

Drives create internal pressure toward certain behaviors:

| Drive | Effect |
|-------|--------|
| Curiosity | Pressure to explore and learn |
| Connection | Pressure to interact with others |
| Coherence | Pressure to resolve contradictions |
| Competence | Pressure to improve capabilities |

Drive levels are stored in the `drives` table and influence heartbeat decisions. The subconscious maintenance adjusts drive levels based on observed patterns.

### Emotional State

Emotional state is tracked but not simulated. The agent:

- Records emotional valence on episodic memories
- Has emotional triggers (patterns that affect emotional state)
- Can reflect on its emotional patterns
- Does not fake emotions it doesn't have

### Graph-Based Identity

The `SelfNode` in the graph connects to:

- `ConceptNode` edges with `kind` (values, capabilities, limitations) and `strength`
- `LifeChapterNode` for narrative context
- Relationship edges to people the agent knows

## Key Design Decisions

- **Identity as memories** -- not hard-coded configuration. Identity evolves as the agent has new experiences.
- **Big Five over custom models** -- well-understood, widely researched, sufficient for behavioral differentiation.
- **Drives create pressure, not action** -- the agent still decides what to do. Drives just make some options feel more compelling.
- **Honest emotion** -- the agent tracks emotional patterns but doesn't simulate feelings. If it says "I find this interesting," that maps to a real pattern in its processing.

## Implementation Pointers

- Character cards: `characters/*.json` with `extensions.hexis` for pre-encoded traits
- Identity init: `init_from_character_card()` DB function
- Worldview memories: `memories` WHERE `type = 'worldview'`
- Drives: `drives` table
- Graph identity: `SelfNode` in Apache AGE

## Related

- [Character Cards](../guides/character-cards.md) -- choosing and creating characters
- [Self-Development](self-development.md) -- how identity evolves
- [Consent and Boundaries](consent-and-boundaries.md) -- boundary enforcement
