# RecMem Architecture and Implementation Plan - Revision 4

## Changes From Prior Revision

Revision 4 keeps the v3 architecture but tightens operational semantics and adds forward-compatible hooks.

1. `route_status` has terminal success states: `merged` and `episode_created`.
2. Consolidation tasks have stale `in_progress` recovery, like embed and route passes.
3. Tasks use `next_attempt_at` for retry backoff. `created_at` is never mutated for retries.
4. `recmem_unhealthy_items()` exposes failed embeddings, failed routings, failed tasks, and dropped tasks.
5. Idempotency hashing normalizes line endings and strips trailing whitespace per line without collapsing internal whitespace.
6. Phase 2 dual-write has a chat ordering guard so direct promotion and legacy eager memory do not both write the same turn.
7. `memories` gains nullable validity hooks: `valid_from`, `valid_until`, `superseded_by`.
8. `subconscious_units` is the canonical memory log. Episodic and semantic memories are derived artifacts.
9. Raw-unit redaction invalidates derived memories that reference the unit. It does not auto-delete them.
10. Phase 2 logs both legacy and RecMem retrieval candidates for offline comparison.
11. Embedding model replacement is acknowledged as a future re-embedding migration.
12. Deferred epistemic work is tracked separately in `plans/recmem_epistemics.md`.
13. Redaction now requires validity filtering anywhere derived memories can be retrieved. `valid_until` cannot remain dormant once redaction is exposed.
14. Hard-delete semantics distinguish source-link deletion from derived-content removal. Regulatory deletion must invalidate, delete, or rederive derived memories, not only cascade `memory_source_units`.
15. RecMem hydration includes recent same-session unembedded raw units by time so newest turns are visible before the nearline embed loop catches up.
16. Merge routing coalesces pending merge tasks per target episode to avoid one LLM merge call per active-topic turn.
17. Merge rejection immediately falls back to recurrence routing instead of leaving the unit `raw_only` until the periodic sweep.

## Purpose

Hexis pays cognitive overhead on every chat turn that does not need it: embeddings, graph sync, episode assignment, neighborhood invalidation, and later neighborhood recomputation, all triggered by ordinary low-value turns.

RecMem becomes the default memory construction path. The canonical memory of the system is the raw user-assistant turn log; episodic narratives and semantic facts are derived, materialized views over that log. This framing has practical consequences:

- raw units are durable evidence of record.
- derived memories are rebuildable.
- deletion/redaction starts from raw units.
- invalidated derived rows must not be retrieved.
- future re-embedding and rederivation are possible because source lineage is explicit.

The pipeline:

1. The hot path writes a raw user-assistant pair to a persistent subconscious layer and returns. No LLM, no embedding, no graph work.
2. A nearline background pass embeds new raw units in batches and decides whether to queue a merge-first update, recurrence-based episode creation, or nothing.
3. A worker drains the consolidation queue, calling LLMs only when consolidation has been judged worthwhile.
4. Semantic refinement extracts atomic facts grounded in each new episode plus its raw source turns, as its own queued task.
5. Query-time retrieval pulls from all three tiers with tier labels preserved.

The goal is to reduce eager work, preserve rare one-off evidence through raw retrieval, and improve long-horizon recall on recurring topics without making chat slower or more fragile.

## Current Hexis Overhead To Replace

### Eager Turn Storage

`services/chat.py::_remember_conversation()` writes every completed chat turn as an episodic long-term memory.

Every ordinary turn currently becomes a `memories` row and can trigger:

- embedding generation.
- graph node sync.
- episode assignment.
- `memory_neighborhoods` initialization or invalidation.
- later neighborhood recomputation.
- long-term-memory growth from low-value turns.

### Pre-Compaction Flush

`channels/conversation.py::_flush_trimmed_to_memory()` groups trimmed user/assistant pairs and writes selected pairs directly as episodic memories. This duplicates eager consolidation at history trim time.

### Inline Subconscious Appraisal

`services/agent.py` runs an LLM subconscious appraisal on every chat turn. RecMem does not automatically replace it. Disabling it is a separate Phase 6 decision, gated by evaluation.

## Target Architecture

### Memory Tiers

| Tier | Storage | Role | Write Cost |
|---|---|---|---:|
| Subconscious (canonical) | `subconscious_units` | raw user-assistant turn log; durable evidence of record | row write |
| Episodic (derived) | `memories(type='episodic')` | temporal narrative summaries; materialized view over raw | queued LLM |
| Semantic (derived) | `memories(type='semantic')` | atomic user facts and preferences; materialized view over raw | queued LLM |

RecMem episodic memories live in `memories(type='episodic')`, not the existing `episodes` table. Hexis `episodes` are temporal containers and graph scaffolding; RecMem episodes are narrative memory entries.

Derived memories carry `memory_source_units` lineage to their underlying raw turns. If an embedding model changes, if a summary is wrong, or if a user redacts a raw turn, derived memories can be invalidated and rederived from the canonical log.

### Hot Path

```text
chat turn completes
  -> recmem_ingest_turn(user, assistant, session_id, source_identity, turn_at, metadata)
       -> compute idempotency key
          source_identity when provided, otherwise conservative content hash
       -> INSERT subconscious_units
          embedding = NULL
          embedding_status = 'pending'
          route_status = 'unrouted'
          ON CONFLICT (idempotency_key) DO NOTHING
       -> return {unit_id, status: stored|duplicate}
```

The hot path does not embed, run similarity, call an LLM, touch the graph, or check recurrence. It succeeds whenever Postgres is up.

### Nearline Passes

Embedding pass:

```text
claim_recmem_unembedded_batch(N, claim_timeout_s)
  -> claim pending or stale in_progress rows
  -> mark embedding_status = 'in_progress', embedding_claimed_at = now()
  -> commit
embed_batch(contents)
apply_recmem_embeddings(payload)
  -> set embedding, embedded_at, embedding_status = 'embedded'
```

Route pass:

```text
claim_recmem_unrouted_batch(N, claim_timeout_s)
  -> claim embedded units with route_status in ('unrouted', 'routing')
  -> recover stale routing claims
recmem_route_unit(id)
  -> merge-first if nearest episodic similarity >= theta_sim_merge
     route_status = 'merge_queued'
  -> otherwise recurrence if |R union {unit}| >= theta_count
     and no overlap with open create task
     route_status = 'create_queued'
  -> otherwise route_status = 'raw_only'
```

Successful consolidation moves units from `merge_queued` to `merged`, and from `create_queued` to `episode_created`.

### Consolidation Worker

```text
claim_recmem_consolidation_task()
  -> pending tasks where next_attempt_at <= now()
  -> or stale in_progress tasks past claim timeout
dispatch by task_type:
  episode_merge
  episode_create
  semantic_refine
apply_recmem_* or fail_recmem_consolidation_task with next_attempt_at backoff
```

### Periodic Recurrence Sweep

A daily bounded SQL job re-routes `raw_only` units that may have gained neighbors over time. It is gated by `last_routed_at` to avoid re-routing too frequently.

### Query Flow

```text
recmem_recall_context(query, k_sub, k_epi, k_sem)
  -> retrieve raw turns, episodic memories, semantic memories
  -> include recent same-session unembedded raw turns by time
  -> preserve tier labels
  -> include source_unit_ids for derived rows
caller deduplicates raw rows that source retrieved episodic/semantic rows
caller formats tiered context into the prompt
```

## Database Design

### `subconscious_units`

```sql
CREATE TABLE subconscious_units (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    session_id UUID,
    source_identity TEXT,
    turn_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    content TEXT NOT NULL,
    user_text TEXT,
    assistant_text TEXT,

    embedding vector(768),
    embedded_at TIMESTAMPTZ,
    embedding_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (embedding_status IN ('pending','in_progress','embedded','failed')),
    embedding_claimed_at TIMESTAMPTZ,
    embedding_attempts INT NOT NULL DEFAULT 0,

    route_status TEXT NOT NULL DEFAULT 'unrouted'
        CHECK (route_status IN (
            'unrouted','routing',
            'raw_only',
            'merge_queued','merged',
            'create_queued','episode_created',
            'route_failed'
        )),
    last_routed_at TIMESTAMPTZ,
    route_attempts INT NOT NULL DEFAULT 0,
    route_result JSONB NOT NULL DEFAULT '{}'::jsonb,

    importance FLOAT DEFAULT 0.3 CHECK (importance BETWEEN 0 AND 1),
    source_attribution JSONB NOT NULL DEFAULT '{}'::jsonb,
    trust_level FLOAT NOT NULL DEFAULT 0.95 CHECK (trust_level BETWEEN 0 AND 1),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','redacted','archived')),
    recurrence_cluster_id UUID,
    consolidated_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    idempotency_key TEXT NOT NULL UNIQUE
);
```

Lifecycle:

```text
embedding_status:
  pending -> in_progress -> embedded
                         -> failed

route_status:
  unrouted -> routing -> raw_only
                      -> merge_queued -> merged
                      -> create_queued -> episode_created
                      -> route_failed
```

`merged` and `episode_created` are terminal success states written only by apply functions. A unit in `merge_queued` or `create_queued` is in-flight.

`status = 'redacted'` is soft deletion. `archived` is reserved for retention.

### `recmem_consolidation_tasks`

```sql
CREATE TABLE recmem_consolidation_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','in_progress','completed','failed','dropped')),
    task_type TEXT NOT NULL,
    trigger_unit_id UUID REFERENCES subconscious_units(id) ON DELETE SET NULL,
    target_memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
    source_unit_ids UUID[] NOT NULL DEFAULT '{}',
    recurrence_count INT NOT NULL DEFAULT 0,
    max_similarity FLOAT,
    attempts INT NOT NULL DEFAULT 0,
    error TEXT,
    task_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    dropped_reason TEXT
);

ALTER TABLE recmem_consolidation_tasks
ADD CONSTRAINT recmem_task_type_known
CHECK (task_type IN ('episode_merge','episode_create','semantic_refine'));
```

The `task_type` constraint is named and separable so future task types can be added by replacing only the constraint.

Retry semantics:

- failures below max attempts become `pending`.
- `started_at` is cleared.
- `next_attempt_at` is set using exponential backoff.
- `created_at` is never changed.
- tasks over max attempts become `failed`.

### `memories` Validity Hooks

```sql
ALTER TABLE memories
ADD COLUMN valid_from TIMESTAMPTZ,
ADD COLUMN valid_until TIMESTAMPTZ,
ADD COLUMN superseded_by UUID REFERENCES memories(id) ON DELETE SET NULL;
```

These are present in v1 but mostly unused until redaction, amendment, and supersession land. Retrieval should eventually filter invalidated rows:

```sql
AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
```

### `memory_source_units`

```sql
CREATE TABLE memory_source_units (
    memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    subconscious_unit_id UUID NOT NULL REFERENCES subconscious_units(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'source'
        CHECK (role IN ('source','direct_promotion','merge_addition')),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (memory_id, subconscious_unit_id)
);
```

`ON DELETE CASCADE` supports hard delete. Normal user-initiated forgetting uses redaction, not delete.

### Indexes

```sql
CREATE INDEX idx_subconscious_units_embedding
    ON subconscious_units USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL AND status = 'active';

CREATE INDEX idx_subconscious_units_embed_pending
    ON subconscious_units (created_at)
    WHERE embedding_status = 'pending';

CREATE INDEX idx_subconscious_units_embed_claimed
    ON subconscious_units (embedding_claimed_at)
    WHERE embedding_status = 'in_progress';

CREATE INDEX idx_subconscious_units_route_pending
    ON subconscious_units (last_routed_at ASC NULLS FIRST, created_at)
    WHERE embedding_status = 'embedded' AND route_status = 'unrouted';

CREATE INDEX idx_subconscious_units_route_claimed
    ON subconscious_units (last_routed_at)
    WHERE route_status = 'routing';

CREATE INDEX idx_subconscious_units_raw_only
    ON subconscious_units (last_routed_at)
    WHERE route_status = 'raw_only'
      AND consolidated_at IS NULL
      AND status = 'active';

CREATE INDEX idx_subconscious_units_status_created
    ON subconscious_units (status, created_at DESC);

CREATE INDEX idx_subconscious_units_session_created
    ON subconscious_units (session_id, created_at DESC)
    WHERE session_id IS NOT NULL;

CREATE INDEX idx_subconscious_units_metadata
    ON subconscious_units USING GIN (metadata);

CREATE INDEX idx_recmem_tasks_pending
    ON recmem_consolidation_tasks (next_attempt_at)
    WHERE status = 'pending';

CREATE INDEX idx_recmem_tasks_in_progress
    ON recmem_consolidation_tasks (started_at)
    WHERE status = 'in_progress';

CREATE INDEX idx_recmem_tasks_open_create_sources
    ON recmem_consolidation_tasks USING GIN (source_unit_ids)
    WHERE status IN ('pending','in_progress')
      AND task_type = 'episode_create';

CREATE INDEX idx_recmem_tasks_status_type
    ON recmem_consolidation_tasks (status, task_type, next_attempt_at);

CREATE INDEX idx_memory_source_units_source
    ON memory_source_units (subconscious_unit_id);

CREATE INDEX idx_memories_validity
    ON memories (valid_until)
    WHERE valid_until IS NOT NULL;
```

## Configuration

Add config keys to the existing `config` table in `db/00_tables.sql`. Do not introduce a separate `config_keys` table.

```sql
-- Core toggles
('memory.recmem_enabled', 'true'::jsonb, 'Use RecMem raw-turn ingestion for chat memory'),
('chat.eager_memory_enabled', 'false'::jsonb, 'Write ordinary chat turns directly to long-term memory'),
('chat.recmem_salience_direct_promote', 'true'::jsonb, 'Promote high-salience turns directly alongside raw ingest'),
('chat.inline_subconscious_enabled', 'true'::jsonb, 'Run inline subconscious LLM appraisal during chat'),
('memory.recmem_hydrate_enabled', 'false'::jsonb, 'Use RecMem tiered retrieval for chat hydration'),
('memory.recmem_dual_write_compare', 'true'::jsonb, 'Log RecMem-vs-eager retrieval candidates during dual-write'),

-- Consolidation thresholds
('memory.recmem_theta_sim', '0.7'::jsonb, 'Similarity threshold for recurrence'),
('memory.recmem_theta_sim_merge', '0.78'::jsonb, 'Tighter threshold for merge-first'),
('memory.recmem_theta_count', '5'::jsonb, 'Recurrence count threshold'),
('memory.recmem_top_k', '20'::jsonb, 'Top-k subconscious neighbors checked for recurrence'),

-- Retrieval budgets
('memory.recmem_sub_limit', '10'::jsonb, 'Subconscious retrieval budget'),
('memory.recmem_epi_limit', '5'::jsonb, 'Episodic retrieval budget'),
('memory.recmem_sem_limit', '10'::jsonb, 'Semantic retrieval budget'),

-- Nearline embed pass
('memory.recmem_embed_batch_size', '32'::jsonb, 'Units embedded per nearline batch'),
('memory.recmem_embed_interval_ms', '2000'::jsonb, 'Nearline embed pass interval'),
('memory.recmem_embed_claim_timeout_s', '120'::jsonb, 'Stale in_progress embedding claim timeout'),
('memory.recmem_embed_max_attempts', '3'::jsonb, 'Max embedding attempts before failed'),

-- Nearline route pass
('memory.recmem_route_batch_size', '32'::jsonb, 'Units routed per nearline batch'),
('memory.recmem_route_claim_timeout_s', '60'::jsonb, 'Stale routing claim timeout'),
('memory.recmem_route_max_attempts', '3'::jsonb, 'Max routing attempts before failed'),

-- Worker
('memory.recmem_worker_enabled', 'true'::jsonb, 'Process consolidation tasks'),
('memory.recmem_task_batch_size', '3'::jsonb, 'Consolidation tasks per worker tick'),
('memory.recmem_task_claim_timeout_s', '600'::jsonb, 'Stale in_progress task timeout'),
('memory.recmem_task_max_attempts', '3'::jsonb, 'Max attempts before task failure'),
('memory.recmem_task_backoff_base_s', '30'::jsonb, 'Base seconds for exponential backoff'),
('memory.recmem_queue_max', '5000'::jsonb, 'Pending consolidation queue cap'),
('memory.recmem_queue_alert', '1000'::jsonb, 'Alert threshold for pending queue depth'),

-- Sweep
('memory.recmem_sweep_age_days', '14'::jsonb, 'Periodic sweep age for unconsolidated units'),
('memory.recmem_sweep_batch_size', '100'::jsonb, 'Max units re-routed per sweep'),
('memory.recmem_sweep_min_rerouting_age_days', '7'::jsonb, 'Skip units routed within this window')
```

## SQL Functions

Create `db/31_functions_recmem.sql`.

### Text and Idempotency

`format_recmem_turn(p_user_text, p_assistant_text) RETURNS TEXT`

Returns the canonical content string:

```text
User: ...

Assistant: ...
```

`normalize_recmem_text(p_text) RETURNS TEXT`

Used for hashing only:

1. Convert CRLF and CR to LF.
2. Strip trailing whitespace from each line.
3. Strip leading and trailing blank lines.
4. Do not collapse internal whitespace.

`compute_recmem_idempotency_key(p_user_text, p_assistant_text, p_session_id, p_source_identity) RETURNS TEXT`

If `p_source_identity` is present, return `src:<source_identity>`. Otherwise return `hash:<sha256(normalized user + separator + normalized assistant + separator + session id)>`.

Use existing Postgres facilities already available in Hexis for hashing; if `digest()` from `pgcrypto` is unavailable, add the extension explicitly in schema setup.

### Hot Path Ingest

`recmem_ingest_turn(...) RETURNS JSONB`

Inputs:

- `p_user_text`
- `p_assistant_text`
- `p_session_id`
- `p_source_identity`
- `p_turn_at`
- `p_importance`
- `p_source_attribution`
- `p_metadata`

Behavior:

1. Return early for empty turns.
2. Format content.
3. Compute idempotency key.
4. Insert `subconscious_units` with pending embedding and unrouted status.
5. `ON CONFLICT (idempotency_key) DO NOTHING`.
6. Return `{unit_id, status}` where status is `stored` or `duplicate`.

No embedding or LLM work is allowed here.

### Nearline Embedding

Functions:

- `claim_recmem_unembedded_batch(p_batch_size int, p_claim_timeout_s int) RETURNS JSONB`
- `apply_recmem_embeddings(p_payload jsonb) RETURNS JSONB`
- `fail_recmem_embedding(p_unit_id uuid, p_error text) RETURNS JSONB`

Claim eligible rows:

- `embedding_status = 'pending'`
- or `embedding_status = 'in_progress'` and `embedding_claimed_at` is older than timeout.

`fail_recmem_embedding` increments attempts and marks failed after `memory.recmem_embed_max_attempts`.

### Nearline Routing

Functions:

- `claim_recmem_unrouted_batch(p_batch_size int, p_claim_timeout_s int) RETURNS JSONB`
- `recmem_route_unit(p_unit_id uuid) RETURNS JSONB`
- `fail_recmem_routing(p_unit_id uuid, p_error text) RETURNS JSONB`

`recmem_route_unit`:

1. Requires `embedding_status = 'embedded'`.
2. Checks merge-first against nearest active episodic memory with `theta_sim_merge`.
3. If merge qualifies, coalesces into an existing open `episode_merge` task for the same target memory when one exists; otherwise queues a new `episode_merge`.
4. Sets `route_status = 'merge_queued'` and records the target memory/task in `route_result`.
5. Otherwise checks recurrence among active embedded `subconscious_units`.
6. If recurrence qualifies and no open create task overlaps any candidate source unit, queues `episode_create` and sets `route_status = 'create_queued'`.
7. Otherwise sets `route_status = 'raw_only'`.

Merge coalescing is required. Without it, a long active topic can create one `episode_merge` LLM task per turn, reintroducing the eager-consolidation cost RecMem is meant to remove. Coalescing appends the new source unit to the open task's `source_unit_ids` and refreshes `task_payload.pending_units`; the worker later merges the existing episode with the batched new source units.

### Consolidation Claim and Retry

`claim_recmem_consolidation_task() RETURNS JSONB`

Use the existing `config` helpers, not a `config_keys` table:

```sql
WITH candidate AS (
    SELECT id
    FROM recmem_consolidation_tasks
    WHERE (status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP)
       OR (
            status = 'in_progress'
            AND started_at < CURRENT_TIMESTAMP
                - (COALESCE(get_config_int('memory.recmem_task_claim_timeout_s'), 600) * INTERVAL '1 second')
       )
    ORDER BY next_attempt_at, created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
UPDATE recmem_consolidation_tasks t
SET status = 'in_progress',
    started_at = CURRENT_TIMESTAMP,
    attempts = attempts + 1,
    updated_at = CURRENT_TIMESTAMP
FROM candidate c
WHERE t.id = c.id
RETURNING ...;
```

`fail_recmem_consolidation_task(p_task_id uuid, p_error text) RETURNS JSONB`

If attempts are exhausted, set `status = 'failed'` and `completed_at = now()`. Otherwise set:

- `status = 'pending'`
- `started_at = NULL`
- `next_attempt_at = now() + backoff`
- `error = p_error`

### Apply Functions

`apply_recmem_episode_merge(p_task_id, p_should_merge, p_merged_content, p_result) RETURNS JSONB`

If `p_should_merge = false`:

- mark task completed.
- set source unit `route_status = 'routing'` temporarily.
- record `route_result.merge_rejected = true`.
- immediately rerun recurrence routing for the source unit with merge-first disabled.
- set the final state to `create_queued` if recurrence now qualifies, otherwise `raw_only`.

This fallback is required. A vector-nearest episode can be similar without being the same ongoing topic; if the LLM rejects the merge, the unit must still get an immediate chance to trigger recurrence-based episode creation instead of waiting for the periodic sweep.

If `p_should_merge = true`:

- re-embed merged content.
- update target memory content and embedding.
- append limited merge history to `metadata.recmem.merge_history`.
- link source unit with `role = 'merge_addition'`.
- set source unit `route_status = 'merged'`, `consolidated_at = now()`.
- mark task completed.
- queue `semantic_refine`.
- mark target memory's neighborhood stale.

`apply_recmem_episode_create(p_task_id, p_episodes, p_result) RETURNS JSONB`

For each episode:

- create `memories(type='episodic')` with RecMem provenance.
- insert source links with `role = 'source'`.
- set source units `route_status = 'episode_created'`, `consolidated_at = now()`.
- queue `semantic_refine` for the new episode.

`apply_recmem_semantic_facts(p_task_id, p_episode_memory_id, p_source_unit_ids, p_facts) RETURNS JSONB`

For each fact:

- apply a conservative similarity guard against existing active semantic memories, initially threshold `0.92`.
- insert non-duplicate facts as `memories(type='semantic')`.
- link source units.
- create `DERIVED_FROM` graph edge to the episode.
- link concepts via `link_memory_to_concept`.
- mark task completed.

### Source Linking and Retrieval

`link_memory_to_source_unit(p_memory_id, p_unit_id, p_role DEFAULT 'source') RETURNS BOOLEAN`

Used by RecMem apply functions and direct promotion.

`get_recmem_related_semantics(p_text, p_limit DEFAULT 10) RETURNS TABLE (...)`

Used by semantic refinement to provide prior facts.

`recmem_recall_context(p_query_text, p_sub_limit, p_epi_limit, p_sem_limit) RETURNS TABLE (...)`

Returns tier-labeled results:

- `tier`
- `item_id`
- `content`
- `score`
- `created_at`
- `metadata`
- `source_unit_ids`

Retrieval should exclude redacted raw units and invalidated memories once redaction is enabled.

RecMem hydration also includes a small recent-unembedded window for the current session, selected by `turn_at DESC` rather than vector similarity. This closes the eventual-consistency gap between hot-path ingest and nearline embedding. The default should be small, for example the last 3-5 same-session raw units or the last 10 minutes, and these rows should be labeled as `tier = 'subconscious_recent_unembedded'`.

Validity filtering is mandatory for any retrieval function that can surface derived memories once `recmem_redact_unit` ships. This includes RecMem retrieval and legacy retrieval such as `fast_recall()`, chat context helpers, recent-memory context, and any tool-facing memory search path. A retrieved `memories` row must satisfy:

```sql
(valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
```

### Sweep, Health, and Redaction

`recmem_periodic_sweep(...) RETURNS JSONB`

Bounded reroute of `raw_only` units that have aged past the rerouting window.

`recmem_unhealthy_items() RETURNS TABLE (...)`

Union of:

- `subconscious_units.embedding_status = 'failed'`
- `subconscious_units.route_status = 'route_failed'`
- `recmem_consolidation_tasks.status = 'failed'`
- `recmem_consolidation_tasks.status = 'dropped'`

This is the canonical operator query for RecMem items needing attention.

`recmem_redact_unit(p_unit_id, p_reason DEFAULT NULL, p_cascade_invalidate DEFAULT TRUE) RETURNS JSONB`

Steps:

1. Set raw unit `status = 'redacted'`.
2. Append redaction metadata.
3. If cascade is enabled, find linked derived memories and mark them invalid:
   - set `valid_until = now()`.
   - write `metadata.recmem.invalidation`.
4. Return redacted unit and invalidated memory IDs.

This is the default user-facing "forget this" path. Administrative hard delete is separate.

`has_pending_recmem_consolidation() RETURNS BOOLEAN`

Returns whether a pending or stale in-progress consolidation task exists.

## Background Passes and Worker

Add `services/recmem.py`.

Loops:

1. `run_recmem_embed_step(conn)`
2. `run_recmem_route_step(conn)`
3. `run_recmem_consolidation_step(conn)`

Worker task handlers:

- `handle_episode_merge`
- `handle_episode_create`
- `handle_semantic_refine`

Prompt files:

- `services/prompts/recmem_episode_construct.md`
- `services/prompts/recmem_episode_merge.md`
- `services/prompts/recmem_semantic_refine.md`

Use the RecMem Appendix F prompts as the base, adapted to Hexis:

- strict JSON output.
- user-centric.
- explicit date anchoring.
- no generic best-practice facts.
- preserve raw source IDs in worker-side metadata rather than relying on the model to emit them.

## Application Changes

### `core.cognitive_memory_api`

Add methods:

```python
async def remember_turn_raw(
    self,
    user_text: str,
    assistant_text: str,
    *,
    session_id: str | None = None,
    source_identity: str | None = None,
    importance: float = 0.3,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]: ...

async def hydrate_recmem(self, query: str, **kwargs: Any) -> HydratedContext: ...

async def link_to_source_unit(
    self,
    memory_id: UUID,
    unit_id: UUID,
    role: str = "direct_promotion",
) -> bool: ...

async def redact_unit(
    self,
    unit_id: UUID,
    *,
    reason: str | None = None,
    cascade: bool = True,
) -> dict[str, Any]: ...
```

Extend `Memory` with:

- `tier`
- `source_unit_ids`
- `valid_until`

### `services/chat.py`

Ordering guard for dual-write:

```python
raw = None
if get_config_bool("memory.recmem_enabled"):
    raw = await cog_mem.remember_turn_raw(
        user_text,
        assistant_text,
        session_id=session_id,
        source_identity=source_identity,
        metadata=meta,
    )

promoted = False
if get_config_bool("chat.recmem_salience_direct_promote") and is_high_salience(user_text, assistant_text):
    mem_id = await cog_mem.remember(...)
    promoted = True
    if raw and raw.get("unit_id"):
        await cog_mem.link_to_source_unit(mem_id, raw["unit_id"], role="direct_promotion")

if get_config_bool("chat.eager_memory_enabled") and not promoted:
    await cog_mem.remember(...)

if dual_write_compare_enabled:
    asyncio.create_task(log_dual_write_comparison(...))
```

`not promoted` prevents direct-promotion plus legacy eager memory from writing the same turn twice during Phase 2.

### `channels/conversation.py`

`_flush_trimmed_to_memory()` calls `recmem_ingest_turn` for each pair and passes `source_identity` when available. Duplicates collapse by idempotency key.

### `services/agent.py`

Gate inline subconscious appraisal with `chat.inline_subconscious_enabled`. Default remains true until Phase 6 evaluation.

### `services/worker_service.py`

Run RecMem nearline and worker steps:

```python
if await get_config_bool("memory.recmem_enabled"):
    await run_recmem_embed_step(conn)
    await run_recmem_route_step(conn)

if await get_config_bool("memory.recmem_worker_enabled"):
    for _ in range(task_batch_size):
        processed = await run_recmem_consolidation_step(conn)
        if not processed:
            break
```

Daily sweep is scheduled separately.

## Retrieval and Prompt Formatting

Format context in tiered sections:

```text
[SUBCONSCIOUS RAW TURNS]
...

[EPISODIC MEMORIES]
...

[SEMANTIC FACTS]
...
```

Rules:

- semantic facts answer precise factual/preference questions.
- episodic memories explain evolving topics.
- raw turns are fallback evidence and source of unconsolidated details.
- deduplicate raw rows that source retrieved derived memories.
- prefer recent and higher-trust evidence on conflict.

## Redaction Contract

Invariants:

- Raw units are canonical.
- User-facing "forget this" uses redaction, not hard delete.
- Redaction sets raw unit `status = 'redacted'`.
- Redaction invalidates derived memories by writing `valid_until = now()` and `metadata.recmem.invalidation`.
- Invalidated derived memories must not be retrieved once redaction ships. This is not optional; validity filtering must land in all memory retrieval paths before redaction is exposed to users.
- Regulatory hard-delete is administrative and cannot rely only on `ON DELETE CASCADE` from `memory_source_units`. Derived episodic/semantic memories may contain copied sensitive text, so hard-delete must first delete or invalidate every derived memory linked to the raw unit, or rederive affected memories from remaining non-deleted raw sources.
- Rederivation is possible but not automatic in v1.

Operational hard-delete procedure:

1. Find linked memories through `memory_source_units`.
2. If a linked memory has only the deleted source unit, delete or invalidate the memory.
3. If a linked memory has additional source units, either invalidate it for review or queue rederivation from the remaining sources.
4. Delete the raw unit.
5. Verify no retrieval path can surface the deleted raw content or invalidated derived content.

## Compatibility Strategy

`fast_recall()` remains available. `CognitiveMemory.hydrate()` switches to RecMem only behind `memory.recmem_hydrate_enabled`.

| Phase | recmem_enabled | eager_memory_enabled | recmem_hydrate_enabled | inline_subconscious_enabled | dual_write_compare |
|---|---|---|---|---|---|
| Before | false | true | false | true | n/a |
| 2 | true | true | false | true | true |
| 3 | true | false | false | true | n/a |
| 4 | true | false | false | true | n/a |
| 5 | true | false | true | true | n/a |
| 6 | true | false | true | evaluated separately | n/a |

## Data Migration

No bulk migration at rollout.

Optional opportunistic backfill:

- when reading old `source_attribution.kind = 'conversation'` memories, create a `subconscious_units` row if raw text is recoverable.
- link old memory to the raw unit.
- do not delete old memories.

## Future Migrations

### Embedding Model Changes

When the embedding model changes, old and new vectors are incomparable. Migration shape:

1. Add `embedding_v2 vector(N)` and `embedding_model_version`.
2. Background embed existing raw units into `embedding_v2`.
3. Switch retrieval to the new vector column when populated.
4. Optionally rederive episodic clusters from the new vector space.
5. Drop old vectors after validation.

The canonical raw store and source links make this possible.

### Deferred Epistemics Work

Track separately in `plans/recmem_epistemics.md`:

- amend/supersede paths.
- batch-aware routing.
- temporal retrieval modes.
- salience beyond recurrence.
- user correction interface.
- raw trivial-turn filtering.
- rederivation after redaction or model upgrade.

## Rollout Plan

### Phase 0 - Baseline Instrumentation

Capture:

- chat latency.
- rows per turn.
- embedding calls per turn.
- neighborhood recomputation count.
- inline subconscious token usage.
- hydrate latency.
- held-out quality eval set.

Quality set:

- at least 30 multi-session conversations.
- reference answers across single-hop, multi-hop, temporal reasoning, preference recall, and adversarial cases.

### Phase 1 - Schema and SQL

Ship:

- tables.
- indexes.
- config keys.
- validity columns.
- SQL functions.
- `recmem_unhealthy_items`.
- `recmem_redact_unit`.

Tests verify lifecycle transitions, stale recovery, terminal states, and redaction.

### Phase 2 - Raw Ingestion, Dual Write, Comparison

Implement:

- `remember_turn_raw`.
- `link_to_source_unit`.
- `redact_unit`.
- chat and compaction changes.

Enable:

- `memory.recmem_enabled = true`
- `chat.eager_memory_enabled = true`
- `memory.recmem_dual_write_compare = true`

Keep dual-write for at least one week.

Comparison logs:

- query text or hash.
- legacy eager retrieval candidates.
- RecMem retrieval candidates.
- answer/session metadata.

Validation:

- one raw unit per chat turn.
- duplicates collapse.
- embed/route pipelines drain.
- no chat latency regression.
- no direct-promote plus eager double-write.

### Phase 3 - Turn Off Eager Memory and Calibrate

Set `chat.eager_memory_enabled = false`.

Run for two to three weeks. Analyze:

- cluster size distributions.
- time to first recurrence.
- merge acceptance rate.
- fraction of raw units consolidated.
- queue depth.
- retrieval misses.

Tune:

- `theta_sim`
- `theta_sim_merge`
- `theta_count`

### Phase 4 - Worker Consolidation

Ship:

- `services/recmem.py`
- prompt files.
- all three task handlers.

Ramp worker batch size gradually.

Validation:

- merge tasks avoid thread fragmentation.
- create tasks produce compact episodes.
- semantic facts are non-duplicate.
- source links are present.
- terminal route states transition correctly.
- induced worker failure recovers after timeout.

### Phase 5 - RecMem Retrieval

Enable `memory.recmem_hydrate_enabled` only after eval confirms quality.

Pass criteria:

- overall accuracy within 1.5 percentage points of baseline or better.
- no category regresses more than 5 percentage points.

### Phase 6 - Inline Subconscious Evaluation

A/B `chat.inline_subconscious_enabled` on vs off. Measure response quality, memory quality, and cognitive-state outcomes. Decide from data.

## Backpressure and Operational Policy

Invariant: raw ingest is never throttled by RecMem consolidation queue depth.

Queue policy:

- below `memory.recmem_queue_alert`: normal.
- between alert and max: warn and raise task batch size if capacity allows.
- at `memory.recmem_queue_max`:
  1. drop `semantic_refine` tasks first.
  2. drop `episode_merge` tasks second.
  3. never drop `episode_create`; pause route queueing and alert.

Dropped tasks are marked `status = 'dropped'` with `dropped_reason` and appear in `recmem_unhealthy_items`.

## Failure Modes and Mitigations

### Bad Episode Merge

Mitigations:

- use tighter `theta_sim_merge`.
- prompt prefers "no" when uncertain.
- keep last 3 prior contents in merge history.
- source links ground rollback/rederivation.

### Merge Flood On Active Topics

Mitigations:

- coalesce pending merge tasks by `target_memory_id`.
- append source units to the open task instead of creating one LLM merge task per turn.
- add a max coalesced-source count so very large merge batches are split deliberately.

### Merge False Positive Delays Recurrence

Mitigations:

- if `LLM_merge` returns `should_merge = false`, immediately reroute the source unit through recurrence with merge-first disabled.
- do not wait for the daily sweep.

### Rare Critical Facts Never Consolidate

Mitigations:

- raw units remain retrievable.
- explicit high-salience direct promotion.
- periodic sweep.
- future salience-beyond-recurrence task.

### Newest Raw Turns Invisible Before Embedding

Mitigations:

- RecMem hydration includes recent same-session unembedded units by time.
- keep the window small and tier-labeled to preserve prompt clarity.
- do not put embeddings back on the hot path.

### Embedding Service Flapping

Mitigations:

- failed embedding state isolates persistent failures.
- operator visibility through `recmem_unhealthy_items`.
- manual reset by setting `embedding_status = 'pending'`.

### Worker Crash Mid-Task

Mitigations:

- stale embed claims recover.
- stale route claims recover.
- stale consolidation claims recover after `memory.recmem_task_claim_timeout_s`.
- retries use `next_attempt_at`.

### Direct Promotion Duplicates RecMem Extraction

Mitigations:

- `memory_source_units.role = 'direct_promotion'`.
- `get_recmem_related_semantics` context at refinement time.
- 0.92 semantic similarity guard.
- chat ordering guard suppresses legacy eager write when direct promotion fires.

### Redaction Leaves Dangling Derived Memories

Mitigations:

- redaction writes `valid_until`.
- retrieval filters invalidated rows in every path that can surface derived memories.
- hard delete handles derived content before deleting source links.
- operator review via health function.

## Testing Plan

### SQL Tests

1. `normalize_recmem_text` preserves internal whitespace.
2. `recmem_ingest_turn` inserts pending/unrouted raw unit.
3. duplicate idempotency key returns duplicate.
4. embedding claim includes stale recovery.
5. route claim includes stale recovery.
6. consolidation task claim includes stale recovery.
7. `fail_recmem_consolidation_task` sets `next_attempt_at` and does not mutate `created_at`.
8. merge apply transitions `merge_queued` to `merged`.
9. create apply transitions `create_queued` to `episode_created`.
10. `recmem_unhealthy_items` returns all failure surfaces.
11. `recmem_redact_unit` redacts raw unit and invalidates derived memories.
12. retrieval excludes invalidated memories once validity filtering is active.
13. merge routing coalesces a second unit into an existing open merge task for the same target memory.
14. merge rejection immediately reroutes through recurrence and can queue `episode_create`.
15. `recmem_recall_context` returns recent same-session unembedded raw units with a distinct tier label.
16. hard-delete helper or administrative test invalidates/deletes derived memories before removing raw source links.

### Python Tests

1. embed loop processes a batch.
2. route loop queues merge and create tasks.
3. worker handles `episode_merge`.
4. worker handles `episode_create`.
5. worker handles `semantic_refine`.
6. invalid JSON fails task cleanly.
7. chat ordering guard produces exactly one direct/eager `remember(...)` call.
8. dual-write comparison logs both candidate sets without blocking response.
9. redaction API invalidates without deleting.
10. hydration includes recent unembedded same-session raw turns before the embed loop has processed them.
11. merge worker processes a coalesced merge task with multiple source units.

### Chat Integration Tests

1. ordinary turn writes raw unit.
2. ordinary turn does not create long-term memory when eager memory is off.
3. explicit high-salience turn direct-promotes and source-links.
4. streaming chat writes raw unit after final text.
5. compaction flush writes raw units and does not resurrect redacted units.
6. redaction then recall excludes redacted evidence.

### Performance Tests

Compare before and after:

- memory rows per 100 chat turns.
- embedding calls per 100 chat turns.
- LLM calls per chat turn.
- time to first token.
- maintenance duration.
- stale neighborhood count.
- hydrate latency.
- consolidation queue lag.

Stress test:

- kill worker mid-LLM-call.
- verify task is reclaimed after timeout.

## Operational Metrics

- `subconscious_units` by `embedding_status`.
- `subconscious_units` by `route_status`.
- embed throughput and lag.
- route throughput and lag.
- stale-claim recovery counts across embed, route, and task paths.
- pending task depth by type.
- `next_attempt_at` backlog.
- task completion/failure/drop rates.
- merge acceptance rate.
- average recurrence count.
- overlap suppression count.
- sweep outcomes.
- semantic facts per episode.
- raw-only retrieval hit rate.
- direct-promotion count and source-link rate.
- dual-write comparison divergence rate.
- redaction count.
- dependent-memory invalidation count.
- `recmem_unhealthy_items` size.

## Decisions

1. RecMem raw store is persistent, not `UNLOGGED`.
2. Raw units are the canonical memory log.
3. Episodic and semantic memories are derived.
4. RecMem episodic memories live in `memories(type='episodic')`.
5. Ingest never calls an LLM.
6. Ingest never computes embeddings synchronously.
7. Embed, route, and consolidation each have durable lifecycle state.
8. All claim paths have stale recovery.
9. Merge-first and recurrence run in the route step using the same embedding.
10. Idempotency uses source identity when available and conservative hash otherwise.
11. Hash normalization preserves internal whitespace.
12. Open create overlap suppression uses any overlapping candidate source unit.
13. `semantic_refine` is a separate queued task from the start.
14. Eager chat memory is disabled by default after Phase 3.
15. Inline subconscious remains enabled until Phase 6 evaluation.
16. Direct promotion always links to the source raw unit.
17. Legacy eager is suppressed when direct promotion fires.
18. Thresholds are tuned on real Hexis traffic in Phase 3.
19. Phase 5 ships only if quality eval passes.
20. Raw ingest is never backpressured by consolidation queue depth.
21. Periodic sweep is bounded and gated by `last_routed_at`.
22. Route lifecycle terminal success states are `merged` and `episode_created`.
23. Task retry uses `next_attempt_at`; `created_at` is immutable.
24. User-facing forget uses redaction and invalidation, not automatic deletion.
25. Validity hooks are present on `memories` for forward compatibility.
26. Once redaction exists, `valid_until` is no longer dormant: all memory retrieval paths must filter invalid derived rows.
27. RecMem hydration includes recent same-session unembedded raw units by time to avoid an immediate-recall gap.
28. Merge tasks are coalesced by target episodic memory to control LLM cost on active topics.
29. Merge rejection falls back to immediate recurrence routing.
30. Regulatory hard-delete must handle derived content before deleting source links; source-link cascade alone is insufficient.

## Follow-On Work

Create `plans/recmem_epistemics.md` for deferred work:

- amend and supersede paths.
- `episode_supersede` task type.
- supersession-aware retrieval.
- batch-aware routing.
- temporal retrieval modes.
- salience beyond recurrence.
- user correction interface.
- raw trivial-turn filtering.
- rederivation after redaction.
- rederivation after embedding model upgrade.

## Minimal First Slice

1. Tables:
   - `subconscious_units`
   - `recmem_consolidation_tasks`
   - `memory_source_units`
   - validity columns on `memories`
2. Indexes.
3. SQL:
   - `format_recmem_turn`
   - `normalize_recmem_text`
   - `compute_recmem_idempotency_key`
   - `recmem_ingest_turn`
   - embed claim/apply/fail functions
   - route claim/route/fail functions
   - `recmem_unhealthy_items`
   - `recmem_redact_unit`
4. Python API:
   - `CognitiveMemory.remember_turn_raw`
   - `link_to_source_unit`
   - `redact_unit`
5. Embed and route loops on a 2-second interval.
6. `services/chat.py` and `channels/conversation.py` changes including ordering guard.
7. Validity filtering in all retrieval paths that can surface `memories` rows, because this slice includes redaction.
8. Recent same-session unembedded raw-unit inclusion in RecMem hydration.
9. Merge-task coalescing and merge-rejection recurrence fallback.
10. Hard-delete administrative behavior documented and tested so derived content is not left retrievable.
11. Config:
   - `memory.recmem_enabled = true`
   - `chat.eager_memory_enabled = true` for one-week dual-write
   - `memory.recmem_dual_write_compare = true` during dual-write only
12. Phase 0 metrics and quality eval captured before any flip.

This slice removes synchronous embedding and synchronous long-term-memory writes from the hot path, gives every downstream operation durable state, supports redaction from day one, and yields retrieval-quality signal during dual-write. Worker consolidation and RecMem retrieval ship in later phases behind quality gates.

---

# Revision 5 — The Lifecycle (2026-07-17)

Rev 4 built the substrate; Rev 5 gives it a metabolism. Diagnosis from live use:
64 turns/day became ~46 near-verbatim episodic memories (per-turn direct
promotion at importance≥0.8 preempted consolidation; recurrence needed 5
similar turns before creating anything), timeline recall cost verbatim-
transcript prices, the journal had zero entries, and the retention substrate
(db/47) shipped dark. RecMem accumulated but never digested. Issues #73–#76.

## The grain hierarchy

```
turn (subconscious_units, kept forever, verbatim)
  → scene (episodic memory, consolidated at session close)      [#73]
    → day (journal entry, her deliberate practice)              [#75]
      → gist (retention merges aged low-strength scenes,        [#74]
              fidelity-tracked, lessons distilled upward)
```

Recall serves the cheapest grain that answers the question, with drill-down
(`open_memory`) to verbatim when exact words matter (#76). Cost per question
becomes proportional to the grain needed, not the amount lived — that is the
"unlimited context window" property, implemented as compression plus paging.

## Changes from Rev 4

1. **Session boundaries are the consolidation trigger** (db/63). A session
   idle past `memory.scene_idle_seconds` (30 min) enqueues ONE
   `episode_create` task covering its unconsumed units, time-ordered. The
   Rev-4 recurrence router remains for cross-session merge and sessionless
   units; the sweep remains for stragglers.
2. **Scenes carry lived time**: `metadata.recmem.occurred_from/occurred_to`
   plus `session_id`, stamped in `apply_recmem_episode_create`.
3. **Direct promotion is a safety valve, not the main path**:
   `memory.direct_promotion_min_importance` (default 0.95) replaces the
   hardcoded 0.8 that made every "i like…" turn its own episodic memory.
4. **Retention runs** (`retention.enabled` default true): aged low-strength
   scenes merge into gists via the existing IN_EPISODE grouping, full text
   preserved in `metadata.consolidation.full_content` through the grace
   window, lessons distilled upward. Capacity pruning stays off (capacity=0).
5. **The journal is the day grain** — deliberately written by the agent
   (heartbeat awareness line + practice prompt), never by a cron.
6. **Graded retrieval surface**: browse mode returns previews with a loud
   truncation/paging signal; hydration renders scenes before raw turns;
   `get_memory_story`/`open_memory` re-hydrate the verbatim units (or the
   pre-gist full text) behind any memory.
7. **Deferred**: fusing fast_recall and recmem_recall_context into one scorer
   (association/temporal terms into the recmem tiers) — the seam map lives in
   issue #76's exploration notes.
