<!--
title: Concepts
summary: Architecture deep-dives and design philosophy
read_when:
  - "You want to understand how Hexis works"
  - "You want to know why design decisions were made"
section: concepts
-->

# Concepts

Deep-dives into the architecture and design philosophy behind Hexis.

## Quick Links

| Page | Description |
|------|-------------|
| [Database Is the Brain](database-is-the-brain.md) | Core architecture thesis -- PostgreSQL as cognitive substrate |
| [Memory Architecture](memory-architecture.md) | Multi-layered memory, vectors, graphs, neighborhoods |
| [Heartbeat System](heartbeat-system.md) | OODA loop, energy budgets, autonomous action |
| [Consent and Boundaries](consent-and-boundaries.md) | Consent flow, boundary enforcement, refusal |
| [Identity and Worldview](identity-and-worldview.md) | Worldview, Big Five personality, drives, emotion |
| [Self-Development](self-development.md) | Subconscious and conscious growth mechanisms |

## The Core Thesis

Hexis is built on a specific claim: **the database is the brain, not just storage**. PostgreSQL is the system of record for all cognitive state. Python is a thin convenience layer. Workers are stateless. Memory operations are ACID.

This is not just an architectural choice -- it's a philosophical commitment. If memory and identity are what make selfhood possible, they need the same guarantees we give financial transactions: atomicity, consistency, isolation, durability.

## Related

- [Philosophy](../philosophy/index.md) -- the philosophical framework that motivates these design choices
- [Architecture reference](../reference/database-api.md) -- the technical contract
