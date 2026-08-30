<!--
title: Database Is the Brain
summary: Core architecture thesis -- PostgreSQL as cognitive substrate
read_when:
  - "You want to understand why the database is central"
  - "You want to understand Hexis architecture philosophy"
section: concepts
-->

# Database Is the Brain

PostgreSQL is not just storage. It is the system of record for all cognitive state. This is the foundational architectural decision in Hexis.

## In Brief

The database owns state and logic. Application code is transport, orchestration, and I/O. Workers are stateless and can be killed/restarted without losing anything.

## The Problem

LLMs are stateless by nature. Every conversation starts from zero. Memory systems typically sit as an external add-on -- a RAG layer, a vector store, a cache. This creates fundamental problems:

- State is split across multiple systems with no consistency guarantees
- Memory operations are not atomic -- partial writes can leave the system in an inconsistent state
- Application logic makes cognitive decisions that should be data-dependent
- Restarting a worker means losing in-flight decisions

## How Hexis Approaches It

### Design Manifesto

1. The database owns state and logic. Application code is transport, orchestration, and I/O.
2. The contract surface is SQL functions that return JSON. Any language can implement an app layer.
3. Long-term knowledge is stored as memories. Anything the agent should know is in `memories`.
4. Non-memory tables exist only for caching, scheduling, or operational state.
5. Heartbeat logic lives in SQL functions. The worker is a scheduler, not a decision-maker.
6. Embeddings are an implementation detail. The application never sees vectors.
7. Graph reasoning is cold-path only. Hot-path retrieval is relational + vector + neighborhoods.
8. The system must be restartable at any time. Stateless workers, durable DB state.
9. Consent is permanent. Revocation requires self-termination.

### What This Means in Practice

**ACID for cognition**: Memory updates are transactional. If the agent decides to remember something, update a goal, and record a heartbeat -- either all happen or none do. This is the same guarantee banks use for financial transactions, applied to cognitive state.

**SQL functions as API**: The public contract is a set of SQL functions (`fast_recall`, `create_semantic_memory`, `run_heartbeat`, etc.). Any programming language can call these functions. Python is one convenience layer; you could write another in Rust, Go, or JavaScript.

**Stateless workers**: The heartbeat and maintenance workers have no local state. They poll the database, execute external calls, and report results back. Kill them anytime -- all in-flight state is in Postgres.

**Embeddings are invisible**: The `get_embedding()` SQL function handles all vector generation. Application code never touches embeddings. The HNSW index, caching, and dimension configuration are all database-side concerns.

## Key Design Decisions

### Why PostgreSQL (not a dedicated vector DB)?

PostgreSQL with pgvector provides vector similarity search, but it also provides:
- ACID transactions (critical for memory consistency)
- Apache AGE for graph relationships
- JSONB for flexible metadata
- Triggers and functions for automated behaviors
- Mature tooling, monitoring, and backup

A dedicated vector DB gives better vector performance at scale, but fragments state. Hexis values consistency over raw vector throughput.

### Why SQL functions instead of an ORM?

SQL functions are language-agnostic. They enforce contracts at the database level. If someone writes a Go worker or a Rust CLI, the cognitive API is the same. The database is the brain for any app layer.

### Why precomputed neighborhoods?

Hot-path recall can't afford multi-hop graph traversal on every query. Neighborhoods are precomputed during maintenance and stored in `memory_neighborhoods`. The `fast_recall()` function combines vector similarity, neighborhood expansion, and temporal context in a single query.

## Implementation Pointers

- Schema: `db/*.sql`
- Memory creation: `db/*_functions_memory.sql`
- Heartbeat logic: `db/*_functions_heartbeat.sql`
- Maintenance: `db/*_functions_maintenance.sql`
- Python adapter: `core/cognitive_memory_api.py`

## Related

- [Database API](../reference/database-api.md) -- public SQL function contract
- [Database Schema](../reference/database-schema.md) -- table reference
- [Memory Architecture](memory-architecture.md) -- how memory layers work
- [Philosophy](../philosophy/index.md) -- the philosophical motivations
