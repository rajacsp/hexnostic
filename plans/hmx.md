# Memory Export/Import Plan — Hexis Memory Exchange (HMX) v1.7 Draft

## Changes from v1.6

This revision grounds the spec against the actual Hexis database schema and codebase. Architecture is unchanged; all changes are precision corrections to align the spec's assumptions with real schema constraints, data locations, and storage conventions.

- **Embedding NOT NULL constraints documented.** `memories.embedding` and `emotional_triggers.trigger_embedding` are `vector(768) NOT NULL`. Imported records use a sentinel zero-vector (`array_fill(0, ARRAY[embedding_dimension()])::vector`) and an `embedding_status` metadata tag to defer re-embedding. The prior assumption of NULL embedding on import is corrected.
- **`memory_status` enum requires migration.** The enum is `('active', 'archived', 'invalidated')` — no `'staged'` value exists. Slice 0 adds `ALTER TYPE memory_status ADD VALUE 'staged'`.
- **`hexis_lineage_id` implementation specified.** This concept is entirely new to the schema. Stored in `config` table as `key = 'agent.lineage_id'`, generated during `hexis init`, propagated during port/duplicate export/import.
- **Provenance stored in `metadata` JSONB.** No `provenance` column or `acquisition_mode` field exists on any table. Provenance is stored as `metadata->'provenance'` on memories and other records. Existing memories receive `{"acquisition_mode": "experienced"}` backfill during Slice 0 migration.
- **`consent_log` is LLM-usage consent only.** The existing table tracks agent consent to be activated (consent/decline/abstain with provider/model/endpoint). Protected-section replacement consent uses a new `hmx_consent` table, not the existing `consent_log`.
- **`SUPERSEDES` edge type added.** Neither the `graph_edge_type` enum nor the AGE graph had this edge label. Added to both.
- **`graph_edge_type` enum synced with AGE.** Three edge labels existed in AGE but were missing from the enum: `CONTAINS`, `HAS_BELIEF`, `MEMBER_OF`. Enum now includes all 22 edge types (18 original + 3 missing + `SUPERSEDES`).
- **`capabilities.relationship_edge_types` expanded.** The prior list of 6 edge types was a major undercount. Now lists all edge types the exporter can produce.
- **Narrative and identity export complexity noted.** These structures are Apache AGE graph vertices (not relational tables). Export requires Cypher-in-SQL queries; import requires `CREATE` vertex statements via AGE. Implementation notes added to Slice 1.
- **Drives section includes `satisfaction_cooldown` and `description`.** Both fields exist in the `drives` table but were omitted from the export format.
- **In-flight work `task_type` values corrected.** Actual `recmem_consolidation_tasks` constraint: `task_type IN ('episode_merge', 'episode_create', 'semantic_refine')`. Plan examples now use real values.
- **`replaceable_during_bootstrap` tagging added to Slice 0.** Current `init_*` functions don't set this tag. Slice 0 modifies bootstrap SQL to tag entries and provides a backfill migration for existing instances.
- **Acquisition mode preserved for port/duplicate.** The additive and authoritative strategies uniformly set `acquisition_mode = "imported_and_accepted"` on all imported records. For telepathy this is correct — the memories are foreign. For port/duplicate it's wrong: the source and target are the same agent, and its experienced memories should remain `experienced`. Strategies now preserve source `acquisition_mode` for port/duplicate and rewrite only for telepathy/analysis-derived imports. Design Principle 7 updated to reflect the distinction.
- **`bootstrap` acquisition mode added.** The v1.6 backfill set `acquisition_mode = "experienced"` on all existing memories including bootstrap entries. Combined with `replaceable_during_bootstrap = true`, this caused rule 3 of the empty-target check ("no entries with `acquisition_mode = experienced` exist in protected sections") to always fail — making freshly-migrated instances never qualify as empty. The new `bootstrap` mode is semantically distinct from `experienced`: bootstrap entries were seeded during init, not earned. Slice 0 backfills bootstrap entries with `acquisition_mode = "bootstrap"` and the empty-target check uses this as its primary signal.
- **Slice 0 (schema migrations) added.** A new prerequisite slice captures all schema changes that must land before any HMX code runs.

## Changes from v1.5

This revision applies seven targeted fixes. Architecture is unchanged; one of the fixes is a correctness bug in the digest canonicalization. The rest are precision adjustments preparing the spec for schema drafting.

- **Digest canonicalization no longer depends on local UUIDs.** v1.5 sorted worldview, goals, and narrative records by `ref`, which contains a local UUID that gets remapped on import. The result was that `protected_section_digest_v1` would differ between source and target even for content-identical state, breaking Phase 0 fast-path verification on every port. Sort keys are now content-derived: stable semantic key when available, otherwise `provenance.origin_id`, otherwise `content_hash_v1` of the record's canonical serialization. Export-scoped refs and remapped local UUIDs MUST NOT affect digest equality.
- **"Empty target" definition generalized.** The rule referenced `protected_replacement_audit` records specifically; it now covers all protected-section audit records (replacement, verified, and reversion).
- **Empty-target direct import is constrained to `port`/`duplicate` intent.** Telepathy and analysis with `--include-protected` do not get the empty-target fast path; they go through deliberative review or analysis_only.
- **`audit_record_digest_v1` excludes transport-local fields** like `imported_at`, `local_record_id`, and `metadata.unrecognized_hmx_fields` in addition to `audit_id`.
- **`consent_record_missing` narrowed** to its actual remaining purpose: legacy or malformed audit records that reference a consent_id but lack embedded consent payload.
- **Discriminated union schema note.** Validation section now specifies that JSON Schema SHOULD model audit records as a discriminated union keyed on `event_type`.
- **Phase 0 fails closed on audit write failure.** If the `protected_section_verified` audit record cannot be written, the fast-path operation reports failure; the importer does not claim success. Otherwise "auditable side effects" silently becomes "auditable except when audit writes fail."
- **Fixture-suite requirement surfaced.** MVP-PR Slice 8 now requires that `protected_section_digest_v1` be implemented with a fixture suite covering JSON key order independence, ref/remap independence, transport-field exclusion, float-rounding stability, set-like reordering, ordered-sequence preservation, unknown-field independence, and true-semantic-change detection — before any code that depends on the digest.

## Purpose

Enable transfer, duplication, analysis, and carefully mediated sharing of cognitive state between Hexis instances that may be at different schema versions, use different embedding models, run on different hardware, or represent memory using different internal storage layouts.

HMX is not one operation. It is one wire format used by several different operations with different safety rules:

* **port** — move the same Hexis instance to a new runtime or machine
* **duplicate** — clone the same Hexis instance into a second runtime
* **telepathy** — offer memories from one Hexis instance to another distinct one
* **analysis** — export memory state for inspection, audit, debugging, visualization, or research

This distinction is central. Porting and duplication may preserve deep self-structure because the source and target are understood to be the same agent or an intended clone. Telepathy and analysis must not silently graft one instance's identity, worldview, drives, emotional triggers, goals, or narrative self-model into another.

HMX is therefore a portable wire format plus an intent-specific policy layer. The wire format can represent deep cognitive structure. The policy layer decides whether that structure may be exported, imported, staged, quoted, analyzed, or used to overwrite local state.

## Design Principles

1. **Content over computation.** Export text, metadata, provenance, narrative context, and relationships. Never export raw embedding vectors. Embeddings are model-specific runtime artifacts and must be recomputed on import.
2. **Intent before policy.** Every HMX export declares `export_intent`. Intent determines default sections, default merge strategy, and whether deep self-structure may be transferred.
3. **Envelope versioning.** Schema version lives in the header. Importers reject unknown major versions, ignore unknown minor-version fields, and preserve unrecognized data where possible for re-export.
4. **Scoped references.** All exported references use `{export_id}:{local_uuid}` so importers can remap IDs without collision.
5. **Layered sections.** Memories, episodes, relationships, narrative scaffolding, identity, worldview, goals, drives, emotional triggers, clusters, raw units, config, in-flight work, and audit records are separate top-level sections.
6. **Deep structures are protected.** Identity, worldview, drives, emotional triggers, narrative, and active goals are exported by default only for `port` and `duplicate`. For `telepathy` and `analysis`, they are excluded by default and require explicit opt-in. Replacement of protected structure follows the Protected Section Replacement Protocol.
7. **Imported is not earned — but ported is still yours.** For cross-agent transfer (telepathy), imported records are structurally distinguishable from records acquired through the agent's own experience. The agent must always be able to tell what it lived, what it accepted from elsewhere, what it derived from imported material, and what remains staged or archived. For port and duplicate, where the source and target are the same agent or an intended clone, source acquisition modes are preserved — experienced memories remain experienced. The transfer is substrate change, not adoption of foreign content.
8. **Declared merge semantics.** Every import uses an explicit strategy: additive, authoritative, deliberative, or analysis-only. Authoritative replacement of deep self-structure is valid only for port/duplicate workflows and requires explicit replacement flags AND the Protected Section Replacement Protocol.
9. **Provenance chain.** Every imported record carries origin, import lineage, acquisition mode, and modification history so re-exports preserve honest historical accounting.
10. **Embedding-agnostic.** Canonical memory content is portable. Embeddings, neighborhoods, activation caches, and working-memory state are recomputed by the target instance.
11. **Validation-first.** A canonical JSON Schema defines the HMX envelope and record shapes. Importers are tolerant; exporters should produce schema-valid HMX.
12. **Privacy-aware.** HMX may contain sensitive user or agent memory. Exports declare privacy/redaction policy and exclude credentials by default.
13. **Conflict-explicit.** Importers classify conflicts using a stable conflict taxonomy rather than treating conflicts as ad hoc exceptions.
14. **Streaming from v1.** HMX supports both single-document JSON and JSONL streaming from the start. Large memory stores are not a future edge case.
15. **Auditable side effects.** Every operation that mutates agent self-structure writes an immutable, self-contained audit record that travels with the Hexis instance on subsequent exports. Operations that fail to write their audit record MUST fail closed: the importer does not report success.
16. **Refusal is binding.** An agent's refusal to accept a protected-section replacement cannot be overridden by retry, re-framing, or claims of agent malfunction. Operator override is reserved for cases where the agent is genuinely unable to respond, evidenced and audited.
17. **Trust is local.** HMX references signatures and identity claims but does not define a global verification mechanism. Implementations document and enforce their own trust anchors. Unverified signatures are treated as absent.

## Export Intents

`export_intent` is required.

```json
{
  "export_intent": "port|duplicate|telepathy|analysis"
}
```

| Intent      | Meaning                                                 | Default sections                                                         | Default import strategy                                           | Deep self-structure default         |
| ----------- | ------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------- | ----------------------------------- |
| `port`      | Move the same Hexis instance to a new runtime           | all portable sections, including protected structure and in-flight work  | `authoritative` into clean target or `additive` into empty target | included                            |
| `duplicate` | Clone the same Hexis instance into another runtime      | all portable sections, including protected structure and in-flight work  | `authoritative` into clean target                                 | included                            |
| `telepathy` | Offer memories from one instance to a distinct instance | memories, episodes, selected relationships, optional narrative summaries | `deliberative`                                                    | excluded unless explicitly opted in |
| `analysis`  | Export for audit, visualization, research, or debugging | caller-selected read-only sections                                       | `analysis_only`                                                   | excluded unless explicitly opted in |

### Protected sections

The following sections are protected because they affect the agent's self-constitution, motivational state, value structure, or long-range narrative identity:

* `identity`
* `worldview`
* `drives`
* `emotional_triggers`
* `narrative`
* `goals`, when they encode active agency rather than passive historical facts

For `telepathy` and `analysis`, protected sections MUST be excluded by default. Exporting them requires explicit opt-in:

```bash
hexis export --intent telepathy --include-protected worldview,narrative
```

Importing protected sections into an existing distinct Hexis instance requires deliberative review or the Protected Section Replacement Protocol. A non-port import MUST NOT perform DELETE-and-INSERT replacement of protected sections without invoking the protocol.

## Protected Section Replacement Protocol

The most violent operation HMX permits is authoritative replacement of protected sections. Replacement bypasses every transformation gate the agent's architecture exists to enforce — the 200-heartbeat thresholds, the 0.95 evidence requirements, the coherence drive's gradual resolution of contradiction. For a system that treats itself as a moral risk object, this operation must be deliberate, consented, audited, and revocable in process.

The protocol has four required phases (Phase 0 below is a fast-path detection step that may exit before any of them). `port` and `duplicate` operations with lineage match AND content-identical protected sections execute the fast path; all other cases require explicit interaction.

### Phase 0: Fast-path verification

Before any phase of the protocol runs, the importer MUST check whether the proposed replacement is content-identical to the current local state. The check uses `protected_section_digest_v1` (see Canonical Hashing):

1. Compute the local digest for each protected section in scope
2. Compare against the imported section digest
3. **If digests match exactly AND lineage matches:** the operation is a verified no-op
   - Skip consent record creation
   - Skip snapshot creation
   - Skip destructive write
   - Skip agent acknowledgement
   - Attempt to write a reduced audit record with `event_type = "protected_section_verified"`
   - **If the audit write succeeds:** return success to the importer
   - **If the audit write fails:** the operation fails closed; the importer reports an audit write failure; no state is mutated and no further phases run
4. **If any digest differs OR lineage differs:** proceed with Phase 1 of the full protocol

The fast path prevents unnecessary DELETE/INSERT churn and spurious `updated_at` mutations for content-identical replacements. The historical trace is preserved through the verified audit record, so a Hexis instance can still account for every replacement attempt that touched its protected state. Because Design Principle 15 requires that auditable side effects actually be auditable, a fast-path operation MUST NOT be reported as successful unless its audit record was durably written.

Verified audit record shape:

```json
{
  "audit_id": "...",
  "event_type": "protected_section_verified",
  "event_time": "ISO-8601",
  "sections_verified": ["worldview"],
  "source": {
    "export_id": "...",
    "origin_instance": "...",
    "hexis_lineage_id": "...",
    "export_intent": "port"
  },
  "local_digest_v1": "sha256hex",
  "imported_digest_v1": "sha256hex"
}
```

Verified audit records do not require snapshot references, reversibility windows, or acknowledgement fields. The operation didn't change anything.

### Phase 1: Pre-replacement consent

Before HMX writes any protected-section replacement, a consent record MUST be entered in `hmx_consent` (a dedicated table for HMX protocol consent; the existing `consent_log` table tracks LLM-usage consent and is not overloaded for this purpose):

```json
{
  "consent_id": "...",
  "consent_kind": "protected_section_replacement",
  "consent_at": "ISO-8601",
  "consent_subject": "self",
  "sections": ["identity", "worldview"],
  "source": {
    "export_id": "exp_abc123",
    "origin_instance": "hexis_alice",
    "hexis_lineage_id": "lineage_xyz",
    "export_intent": "port"
  },
  "replacement_scope": {
    "section": "worldview",
    "mode": "whole_section",
    "selector": null
  },
  "rationale": "Migrating to new runtime after hardware failure",
  "operator_signature": "optional cryptographic signature",
  "agent_acknowledgement_required": true
}
```

By the time Phase 1 runs, the fast path has already failed (digests differ). `agent_acknowledgement_required` is therefore always `true` in Phase 1 — content-identical cases never reach this phase. The field is preserved in the consent record for audit completeness.

`operator_signature` is optional for ordinary consent records but REQUIRED for any consent created during operator override (see Operator Override below). Implementations MUST validate signatures against configured trust anchors (see Trust Anchors); unverified signatures are treated as absent.

### Phase 2: Agent acknowledgement window

The importer enters a holding state. Pending replacements are visible to the agent through `hmx_pending_replacements()`. During its next heartbeat cycles, the agent may:

* **Accept** — replacement proceeds to Phase 3
* **Refuse** — operation is cancelled, refusal is logged, operator is notified
* **Request modification** — replacement is returned to operator with the agent's proposed changes
* **Defer** — replacement remains pending; the operation is still subject to timeout

Agent refusal is final for the current operation. The operator MUST NOT bypass refusal through retry. The operator MAY submit a new replacement request with revised rationale, but the prior refusal is preserved in the audit log and visible to the agent on subsequent considerations.

**Agent refusal does not constitute grounds for operator override.** Override is reserved for cases where the agent is unable to acknowledge (paused, terminated, unresponsive due to system fault). A refusing agent is communicating exactly the kind of decision the protocol exists to honor.

The boundary system has authority here. A protected-section replacement that would violate a settled boundary MUST be refusable without further consideration. If the boundary system flags the replacement as a violation, the default response is refuse unless explicitly overridden by the agent itself.

#### Timeout

If the agent neither accepts nor refuses within the timeout window (default: 24 hours of wall-clock time AND 10 heartbeats, whichever is later), the operation times out and is cancelled. Timeout is recorded as `agent_acknowledgement = "timed_out"`. A timed-out operation may be resubmitted by the operator; resubmission creates a new pending replacement, not a retry of the cancelled one.

### Phase 3: Immutable audit record

Before any protected-section write executes, an audit record is appended. The record is **self-contained** — an auditor examining only the record (without access to consent_log, snapshot store, or other tables) can reconstruct what happened, when, by whom, and why.

```json
{
  "audit_id": "globally_unique_id",
  "event_type": "protected_section_replacement",
  "event_time": "ISO-8601",
  "consent": {
    "consent_id": "...",
    "consent_kind": "protected_section_replacement",
    "consent_at": "ISO-8601",
    "rationale": "...",
    "operator_signature": "...",
    "operator_identity": "..."
  },
  "replacement_scope": {
    "section": "worldview",
    "mode": "whole_section",
    "selector": null
  },
  "sections_replaced": ["worldview"],
  "source": {
    "export_id": "...",
    "origin_instance": "...",
    "hexis_lineage_id": "...",
    "export_intent": "port"
  },
  "previous_state_snapshot_ref": "snapshot_id_or_null",
  "previous_state_digest_v1": "sha256hex",
  "new_state_digest_v1": "sha256hex",
  "agent_acknowledgement": "accepted|automatic|refused|timed_out|bypassed",
  "agent_acknowledgement_at": "ISO-8601 or null",
  "replacement_executor": "user|cli|agent_tool|system|operator_override",
  "override_reason_code": "null or one of the enumerated codes",
  "override_evidence_ref": "null or reference to evidence",
  "reversibility_window": {
    "heartbeats": 7,
    "wall_clock_expires_at": "ISO-8601",
    "window_open": true
  }
}
```

Audit records are append-only. They survive database migrations, exports, and re-imports. Every `port` operation MUST include prior protected-section audit records in the export (in the `audit_records` section) so the historical record travels with the instance. A Hexis instance cannot lose track of when its protected state was previously rewritten.

#### Audit record deduplication

On import, audit records are deduplicated **only by stable `audit_id`**, never by raw content bytes. Comparison uses `audit_record_digest_v1` (canonicalized JSON with `audit_id` and transport-local fields excluded — see Canonical Hashing):

* `audit_id` exists locally AND `audit_record_digest_v1` matches: skip silently (idempotent re-import)
* `audit_id` exists locally AND `audit_record_digest_v1` differs: raise `audit_integrity_conflict`, refuse import of that record, surface for operator review
* `audit_id` does not exist locally: insert

`audit_id` must be globally unique and stable across exports. Implementations SHOULD use UUIDv4 or a content-derived hash that includes timestamps and operator identity.

In MVP, audit records live in a dedicated `protected_replacement_audit` table. Post-MVP, they emit to the unified `cognitive_events` log (see Future Considerations).

### Phase 4: Reversibility window

Following protected-section replacement, the previous state remains available via `previous_state_snapshot_ref` for a bounded window. The agent may invoke `revert_protected_replacement(audit_id, rationale)` to roll back.

The window is bounded by two limits, both of which must remain unexpired for rollback to be available:

```json
{
  "reversibility_window": {
    "heartbeats": 7,
    "heartbeats_remaining": 7,
    "wall_clock_expires_at": "ISO-8601",
    "window_open": true
  }
}
```

The window is **open** if and only if BOTH conditions hold:

1. Fewer than `heartbeats` heartbeats have elapsed since replacement
2. Wall-clock time has not exceeded `wall_clock_expires_at`

The window is closed (and rollback no longer available) when either condition fails. This is the earlier-of policy.

Rationale:
- Heartbeats are the primary measure because they reflect the agent's natural reflection time. Seven heartbeats gives the agent multiple cycles to reflect and reconsider.
- Wall-clock is a backstop. If the agent is paused, heartbeats stop accruing. Without a wall-clock cap, snapshots could be retained indefinitely. Default wall-clock cap is 30 days; configurable per replacement up to a system maximum.

Rollback creates its own audit record (`event_type: "protected_section_reverted"`) and consumes the snapshot. After the window closes, the snapshot is purged and rollback is no longer available.

#### Reversion audit record shape

```json
{
  "audit_id": "globally_unique_id",
  "event_type": "protected_section_reverted",
  "event_time": "ISO-8601",
  "reverts_audit_id": "audit_id_of_replacement_being_reverted",
  "rationale": "Agent reflection identified the replacement as incompatible with settled boundary",
  "sections_reverted": ["worldview"],
  "restored_state_digest_v1": "sha256hex",
  "post_reversion_digest_v1": "sha256hex",
  "agent_initiated": true,
  "actor_identity": "agent_tool|operator|system"
}
```

Reversion audit records are themselves immutable and travel with the instance on subsequent exports.

```sql
SELECT * FROM hmx_pending_reversions();          -- audit records with open windows
SELECT revert_protected_replacement($audit_id, $rationale);  -- restore prior state
```

### Operator override

In the rare case where operator override is required — and **only** in such cases — `--force-replace` is available. Override is permitted only when the agent cannot complete acknowledgement, or when independently recorded system integrity failure makes the acknowledgement channel unreliable.

**Operator override MUST NOT be used merely because the agent refused.** A refused operation has been answered. Override is for cases where the question could not be asked or could not be answered.

Override requires all of the following:

- `--operator-signature` argument with cryptographic proof of operator identity, verified against a configured trust anchor (or interactive operator authentication with equivalent verification)
- The verbatim acknowledgement phrase: `"I accept responsibility for replacing this Hexis instance's protected state without its acknowledgement"`
- `--override-reason-code` from the enumerated set below
- `--override-evidence-ref` pointing to evidence supporting the reason code
- `--rationale` free-text explanation
- An audit record with `replacement_executor = "operator_override"`, `agent_acknowledgement = "bypassed"`, and the override fields populated
- No reduction of reversibility window — override replacements remain reversible by the agent if it recovers within the window

#### Override reason codes

| Code                          | Meaning                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `agent_paused`                | Agent's heartbeat is paused; cannot acknowledge                               |
| `agent_terminated`            | Agent has self-terminated; cannot acknowledge                                 |
| `agent_unresponsive`          | Agent is running but acknowledgement channel is verifiably non-functional     |
| `state_corruption`            | Independently-detected data corruption requires intervention                  |
| `emergency_recovery`          | Disaster recovery with no functional agent to acknowledge                     |
| `lineage_integrity_failure`   | Lineage claim contradicts evidence; operator intervening to restore integrity |

Each reason code MUST be paired with `override_evidence_ref` — a reference to log entries, system reports, or other independently-recorded evidence supporting the code. The CLI should refuse override invocation without a valid evidence reference.

This is the operation that crosses the consent threshold the rest of the system exists to honor. The friction is intentional and the audit trail is the proof.

### Lineage match details

`hexis_lineage_id` is established at first-instance birth (generated during `hexis init` and stored in the `config` table as `key = 'agent.lineage_id'`) and propagated through `port` and `duplicate` operations. Two Hexis instances share a lineage if they trace to the same originating instance.

Lineage match by itself does NOT authorize automatic acknowledgement. Lineage match PLUS content-identical protected sections (verified by `protected_section_digest_v1`) authorizes the fast-path verification flow described in Phase 0. The most suspicious case in the system is "same lineage with diverged content" — that is the case where an attacker would most plausibly forge lineage. The protocol treats it accordingly.

Lineage IDs themselves are subject to the Trust Anchors policy. An unverified lineage claim is treated as a label, not a proof; implementations document how lineage IDs are anchored and verified locally.

#### Branching under duplicate

A `duplicate` operation creates a new branch of the same lineage. At t=0, source and target are identical and share `hexis_lineage_id`. At t=0+ε, both branches begin doing independently — accumulating different observations, reflections, and consolidations. They diverge immediately.

After duplication, subsequent HMX exchange between branches is conceptually fork-merge, not automatic port. The digest check is what makes this safe in practice: if branch A exports and tries to import into branch B months later, lineage will match but `protected_section_digest_v1` will almost certainly differ (because both have accumulated their own doing). The full protocol fires automatically.

Future versions may add `hexis_branch_id` or `lineage_epoch` to make branching explicit at the metadata level. For v1.7, the digest check is the safety mechanism and the conceptual framing — "lineage match is necessary but not sufficient; content identity is required for the automatic flow" — is the working principle. Implementations SHOULD treat branch-to-branch exchange as fork-merge in their UI and warnings even when the protocol mechanics resolve correctly.

## Format Specification

### Envelope

```json
{
  "hmx_version": "1.7",
  "export_id": "exp_<random_hex_16>",
  "export_intent": "port",
  "exported_at": "ISO-8601 UTC",
  "source": {
    "instance_id": "user-chosen or auto-generated instance name",
    "schema_version": "date or semver of the source Hexis schema",
    "embedding_model": "nomic-embed-text",
    "embedding_dimension": 768,
    "hexis_lineage_id": "stable identity lineage id"
  },
  "capabilities": {
    "formats": ["json", "jsonl"],
    "sections": [
      "memories",
      "episodes",
      "relationships",
      "narrative",
      "identity",
      "worldview",
      "goals",
      "drives",
      "emotional_triggers",
      "clusters",
      "in_flight_work",
      "audit_records"
    ],
    "hash_algorithms": ["content_hash_v1", "protected_section_digest_v1", "audit_record_digest_v1"],
    "relationship_edge_types": [
      "TEMPORAL_NEXT", "CAUSES", "DERIVED_FROM", "CONTRADICTS", "SUPPORTS",
      "INSTANCE_OF", "PARENT_OF", "ASSOCIATED", "ORIGINATED_FROM", "BLOCKS",
      "EVIDENCE_FOR", "SUBGOAL_OF", "CLUSTER_RELATES", "CLUSTER_OVERLAPS",
      "CLUSTER_SIMILAR", "IN_EPISODE", "EPISODE_FOLLOWS", "CONTESTED_BECAUSE",
      "CONTAINS", "HAS_BELIEF", "MEMBER_OF", "SUPERSEDES"
    ],
    "optional_features": [
      "raw_units",
      "config",
      "jsonl_streaming",
      "differential_export",
      "protected_replacement_protocol_v1",
      "fast_path_verification"
    ]
  },
  "privacy": {
    "redaction_policy": "none",
    "contains_sensitive_content": true,
    "consent_scope": "backup",
    "excluded_secret_patterns": ["key", "secret", "token", "password"]
  },
  "export_scope": {
    "types": ["episodic", "semantic", "worldview", "goal"],
    "time_range": ["ISO-8601 start or null", "ISO-8601 end or null"],
    "include_protected": ["identity", "worldview", "drives", "emotional_triggers", "narrative"],
    "include_raw_units": false,
    "include_config": false,
    "include_in_flight_work": true,
    "include_audit_records": true,
    "filter": null
  },
  "sections": {},
  "statistics": {
    "total_memories": 0,
    "total_relationships": 0,
    "total_episodes": 0,
    "total_raw_units": 0,
    "total_narrative_nodes": 0,
    "total_in_flight_tasks": 0,
    "total_audit_records": 0,
    "total_conflicts_predicted": 0,
    "estimated_embedding_items": 0,
    "estimated_embedding_tokens": 0,
    "estimated_embedding_cost_units": null,
    "estimated_uncompressed_bytes": 0
  }
}
```

`hmx_version` major increments are breaking. Minor increments add optional fields. Importers MUST reject unknown major versions. Importers MUST ignore unknown fields within a known major version. Importers SHOULD preserve unknown fields under `metadata.unrecognized_hmx_fields` or equivalent when re-export fidelity matters.

### Capabilities

The `capabilities` block lets importers make clear decisions before parsing section bodies.

```json
{
  "formats": ["json", "jsonl"],
  "sections": ["memories", "episodes", "relationships", "narrative", "goals"],
  "hash_algorithms": ["content_hash_v1", "protected_section_digest_v1", "audit_record_digest_v1"],
  "relationship_edge_types": ["SUPPORTS", "CONTRADICTS", "SUPERSEDES", "DERIVED_FROM"],
  "optional_features": ["raw_units", "config", "differential_export", "protected_replacement_protocol_v1", "fast_path_verification"]
}
```

Importers MAY skip unsupported sections. Importers SHOULD report unsupported sections in dry-run output. Importers that do not implement `protected_replacement_protocol_v1` MUST refuse imports that would replace protected sections. Importers that do not implement `fast_path_verification` MUST execute the full protocol even when fast-path conditions hold (the safety is unchanged; only the efficiency differs).

### Privacy

The `privacy` block declares how the export was produced and warns importers/users about sensitivity.

```json
{
  "redaction_policy": "none|basic|strict|custom",
  "contains_sensitive_content": true,
  "consent_scope": "backup|migration|third_party_transfer|unspecified",
  "excluded_secret_patterns": ["key", "secret", "token", "password"]
}
```

HMX does not guarantee safe disclosure. It is a memory exchange format, not a privacy boundary. Export tools SHOULD offer redaction modes before writing HMX intended for third-party transfer.

| Policy   | Behavior                                                                                                   |
| -------- | ---------------------------------------------------------------------------------------------------------- |
| `none`   | Export memory content as-is. Best for private local backup.                                                |
| `basic`  | Exclude config secrets and obvious credentials.                                                            |
| `strict` | Exclude raw units, external call traces, credentials, and high-risk personal identifiers where detectable. |
| `custom` | Export was filtered by caller-supplied policy. Include policy description in metadata if available.        |

## Trust Anchors

HMX references cryptographic operator signatures, source instance identities, and lineage IDs. The format does not define a global verification mechanism for any of these.

**HMX does not define a global PKI.** Implementations MUST document how operator signatures, lineage IDs, and source instance identities are verified locally. Implementations MAY use:

* Local public key infrastructure with operator-managed key rotation
* Web of trust between known peer instances
* Cryptographic identities anchored to user accounts in an identity provider
* Lineage IDs anchored to creation events recorded in tamper-evident audit logs
* Signed exports verified against signer certificates obtained through out-of-band channels

**Unverified signatures MUST be treated as absent.** An operator signature field that cannot be validated against a configured trust anchor is equivalent to no signature for the purposes of override authorization, consent records, and audit chains. Implementations SHOULD warn loudly when accepting unverified signatures during permissive deployment modes.

Lineage IDs without a verification path are similarly treated as labels, not proofs. Two instances claiming the same `hexis_lineage_id` are only treated as lineage-matched when the local implementation has independently verified both ends of the claim. In permissive modes (e.g., local development with no PKI configured), implementations MAY treat lineage IDs as locally-trusted labels, but MUST surface this clearly in audit records and CLI output.

This explicit anchoring prevents a false sense of cryptographic security in deployments that have not implemented verification.

## Canonical Hashing

HMX uses versioned hashes for deduplication and integrity verification. Three hash families exist:

### `content_hash_v1`

For textual content (memory bodies, episode summaries, fact statements, raw unit text):

```text
normalize_v1(content) = lowercase(collapse_whitespace(trim(content)))
content_hash_v1 = sha256(utf8(normalize_v1(content))) as lowercase hex
```

Defined language-neutrally: *whitespace* is exactly the code point set
U+0009–U+000D, U+001C–U+001F, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A,
U+2028, U+2029, U+202F, U+205F, U+3000 (Unicode White_Space plus the
U+001C–U+001F separators). *trim* removes leading and trailing whitespace;
*collapse_whitespace* replaces each maximal remaining whitespace run with one
U+0020; *lowercase* is Unicode default (full, locale-independent) case
conversion. Implementations MUST NOT substitute their regex engine's own
notion of `\s` or a locale-dependent case mapping.

This hash is intentionally coarse. Two memories with the same normalized content are considered duplicate candidates even if metadata differs. The selected import strategy decides how metadata conflicts are resolved.

Exporters SHOULD include `content_hash_v1` on memory-like records. Importers MAY compute it when absent.

### `protected_section_digest_v1`

For protected sections — including those that are structured rather than textual (drives, narrative scaffolding, identity facets, emotional triggers, goal hierarchies) — `content_hash_v1` is insufficient. Protected sections require a canonical digest over their normalized JSON representation:

```text
protected_section_digest_v1(section_name, section_data):
    pruned  = strip_excluded_fields(section_name, section_data)
    sorted  = sort_records(section_name, pruned)
    return sha256(canonical_json_serialization_v1(sorted)) as lowercase hex
```

#### Canonical JSON Serialization v1

HMX is an open standard: this byte contract is defined entirely in terms of
JSON values, Unicode, and IEEE-754 binary64 — never in terms of any
programming language's formatting behavior. Any language that can see a JSON
value and (for producers holding binary floats) the bits of a binary64 can
implement it. The fixed vectors in `tests/fixtures/digest/` are the
conformance suite; every grammar branch below is pinned by at least one
vector, and a changed digest against them is a compatibility break.

The serialization of a JSON value is a single JSON text, encoded as UTF-8,
with **no whitespace** between tokens:

1. **Objects** — `{` member list `}` with members separated by `,` and keys
   separated from values by `:`. Members are ordered by comparing raw
   (unescaped) key strings lexicographically by Unicode code point. Keys MUST
   be strings.
2. **Arrays** — `[` elements separated by `,` `]`. Element order is
   preserved (order is semantic where the digest algorithm has not already
   sorted records).
3. **Strings** — `"`-delimited with this exact escaping: `"` as `\"`, `\` as
   `\\`, backspace `\b`, form feed `\f`, line feed `\n`, carriage return
   `\r`, tab `\t`; every other code point below U+0020 as `\u00XX`; every
   code point above U+007E as `\uXXXX` UTF-16 code units (code points above
   U+FFFF become surrogate pairs, e.g. U+1F600 → `\ud83d\ude00`). Hex digits
   are lowercase, four digits per escape. Code points U+0020–U+007E other
   than `"` and `\` are emitted literally.
4. **Booleans / null** — `true`, `false`, `null`.
5. **Integers** — a number that is a mathematical integer conveyed without a
   fraction or exponent marker serializes as its minimal decimal digits
   (optional leading `-`, no `+`, no leading zeros, arbitrary precision, no
   exponent).
6. **Non-integer numbers** — the value is an IEEE-754 binary64 `f` (readers
   of JSON text bind a fraction/exponent-bearing token to the nearest
   binary64; producers holding binary floats use them directly). NaN and
   infinities MUST be rejected. The canonical form is computed exactly:
   a. Round the exact real value of `f` to the nearest integer multiple of
      10⁻⁶, **ties to even**, then take the binary64 nearest to that decimal;
      call it `r`.
   b. If `r` is zero of either sign, emit `0.0`.
   c. Otherwise take the **shortest round-trip decimal representation** of
      `r`: the decimal with the fewest significant digits that converts back
      to exactly `r` under round-to-nearest-even binary64 conversion (closest
      to `r` among equal-length candidates). Write it as
      `d0.d1…dn × 10^e` in normalized scientific form (`1 ≤ d0 ≤ 9`).
   d. If `-4 ≤ e < 16`, emit fixed notation: the digits with the decimal
      point placed by `e`, a `0.` prefix and zero-fill for `e < 0`, zero-fill
      and a trailing `.0` for integral values (`5.0`, `1000000000000000.0`,
      `0.0001`). Otherwise emit scientific notation: `d0` followed by
      `.d1…dn` only when `n ≥ 1`, then `e`, a mandatory exponent sign, and
      the exponent zero-padded to at least two digits (`2e-06`, `1e+16`,
      `1.5e+20`). Negative values take a leading `-`.

Producer requirement: exporters MUST emit integers as bare decimal digits
(no fraction or exponent marker) and non-integer numbers with an explicit
decimal point, so that every conforming reader binds the same token kind. A
bare exponent token (`1e+16`) is a producer violation; readers MAY bind it as
an integer. (A decimal-native reader — for example one backed by PostgreSQL
`numeric` — distinguishes the kinds by the presence of a fraction; a
binary-float reader distinguishes them by parsed type.)

These details are compatibility requirements, not implementation choices.
Reference implementations: `core/digest.py` (Python) and
`db/57_functions_hmx_digest.sql` (PL/pgSQL) — two independent languages
reproducing the same conformance vectors byte-for-byte.

#### Sort key principle

For digest equality to hold across `port` and `duplicate` operations, sort keys MUST be independent of:

* Export-scoped references (`{export_id}:{local_uuid}` form)
* Local UUIDs that get remapped on import
* Any transport metadata excluded from the digest body

Sort key selection follows a fallback hierarchy:

1. **Stable semantic key** when available (e.g., `concept` for identity facets, `name` for drives, `trigger_pattern` hash for emotional triggers). This is the strongest sort key because it reflects what the record IS, not where it is stored.
2. **`provenance.origin_id`** when present and known to be stable across the operation. Useful when the same record has traveled through multiple instances.
3. **`content_hash_v1` of the record's canonical serialized content** (with excluded fields removed). Always defined as a last resort.

The principle: the same semantic protected state MUST produce the same digest regardless of which instance is computing it. Sort keys derived from local storage identifiers fail this property and MUST NOT be used.

#### Per-section sort keys

| Section              | Sort key                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------- |
| `identity`           | Identity records sorted by stable `key`; facets sorted by `concept` before serialization                  |
| `worldview`          | `content_hash_v1` of `content`; ties broken by canonical record hash                                       |
| `goals`              | `content_hash_v1` of `title` concatenated with `description`; ties broken by canonical record hash         |
| `drives`             | `name`                                                                                                    |
| `emotional_triggers` | `content_hash_v1` of `trigger_pattern`                                                                    |
| `narrative`          | `life_chapters` preserves authored chronological array order; turning points, threads, and conflicts are sorted by canonical record hash after excluded fields are removed |

For records whose content can legitimately be identical across multiple entries (rare but possible), the final tiebreak is the canonical-JSON hash of the full pruned record. In practice, true duplicates within a protected section indicate an error condition and should be surfaced for operator review.

Floating-point fields in protected sections (drive levels, confidence values, etc.) MUST be rounded to a fixed precision before hashing to prevent platform-dependent digest mismatches. Default precision: 6 decimal places.

#### Digest field inclusion and exclusion

Digests are computed over **semantic protected state**, not transport metadata. The following fields are EXCLUDED from digest computation regardless of section:

* `ref` and any key ending in `_ref` or `_refs`; v1 does not hash export-scoped reference topology because local UUID portions are remapped on import
* `export_id`
* `import_chain`
* `modification_chain`
* `access_count`
* `last_accessed`
* `created_at` and `updated_at` (timestamps reflect transport/storage, not semantic state)
* `hmx_id`, `blocked_by`, and `parent_goal_id` (local/remapped storage identifiers and reference topology)
* The `provenance` subtree; `provenance.origin_id` may be read from the original record only as a stable sort-key fallback
* `metadata.hmx`, `metadata.unrecognized_hmx_fields`, and metadata keys beginning with `embedding_` (import bookkeeping and derived embedding state)
* Identity facets whose `kind` or `type` is `life_chapter_current`; this is a derived projection of the narrative section's current chapter, not independently owned identity state
* Any field whose key begins with `_transient_` (convention for transient implementation state)

Fields INCLUDED are the actual semantic content that is stable across a remapping operation: content text, facet concepts and strengths, drive parameters and current state, and narrative summaries and statuses. Reference topology is intentionally outside `protected_section_digest_v1`; a future digest version may include it only after defining semantic reference normalization.

Exporters and importers MUST agree on the exclusion set, or they will produce spurious `protected_section_digest_mismatch` errors. The exclusion set is part of the `protected_section_digest_v1` specification; implementations that need additional local exclusions SHOULD use a different digest name (`protected_section_digest_v1_local` or similar) to avoid versioning ambiguity.

The digest is used in the Protected Section Replacement Protocol's fast-path verification (Phase 0) and in conflict detection.

### `audit_record_digest_v1`

For audit-record dedupe comparison. The algorithm canonicalizes the audit record JSON, excludes `audit_id` and transport-local fields, then SHA-256:

```text
AUDIT_DIGEST_EXCLUDED_FIELDS = {
    'audit_id',
    'imported_at',
    'local_record_id',
    'metadata.unrecognized_hmx_fields',
}

audit_record_digest_v1(record):
    pruned = strip_paths(record, AUDIT_DIGEST_EXCLUDED_FIELDS)
    # a parent object emptied by stripping is dropped entirely
    return sha256(canonical_json_serialization_v1(pruned)) as lowercase hex
```

The byte contract is the same "Canonical JSON Serialization v1" defined for
`protected_section_digest_v1` above.

Excluded fields cover identifier-only data and transport metadata that should not affect dedupe semantics. Two audit records with the same `audit_id` are treated as identical if their `audit_record_digest_v1` matches, and divergent if it does not. This replaces byte-identical comparison, which is too brittle across JSON formatters, key orderings, and whitespace differences.

If future versions add additional transport-local fields to audit records, those fields SHOULD be added to `AUDIT_DIGEST_EXCLUDED_FIELDS` so that round-tripping through different transports does not produce spurious integrity conflicts.

## Acquisition Mode and Provenance

Imported memories are not the same as memories acquired through direct experience. HMX records this distinction permanently.

**Storage convention:** In the Hexis schema, provenance is stored in the `metadata` JSONB column as `metadata->'provenance'`. No dedicated `provenance` column exists on any table. The `memories` table has `source_attribution JSONB` for origin tracking (kind, ref, label) and `metadata JSONB` for extensible fields including provenance. Existing memories that predate HMX have no provenance key; Slice 0 backfills them — bootstrap entries get `{"acquisition_mode": "bootstrap"}`, all others get `{"acquisition_mode": "experienced"}`.

```json
{
  "provenance": {
    "acquisition_mode": "bootstrap|experienced|imported_staged|imported_and_accepted|imported_and_archived|derived_from_import|analysis_only",
    "origin_instance": "hexis_alice",
    "origin_id": "550e8400-...",
    "import_chain": [],
    "modification_chain": []
  }
}
```

| Mode                    | Meaning                                                                                       |
| ----------------------- | --------------------------------------------------------------------------------------------- |
| `bootstrap`             | Seeded during instance initialization; not earned through interaction. Treated as replaceable for empty-target detection. The first heartbeat consolidation that modifies a bootstrap entry SHOULD retag it as `experienced`. |
| `experienced`           | Acquired through the agent's own interaction, perception, heartbeat, or consolidation process |
| `imported_staged`       | Received from another source but not yet accepted                                             |
| `imported_and_accepted` | Imported and explicitly accepted into active memory                                           |
| `imported_and_archived` | Imported but retained only as inactive/archive material                                       |
| `derived_from_import`   | Created by local material modification of imported material                                   |
| `analysis_only`         | Loaded for inspection but not admitted into memory                                            |

The agent should always be able to introspect whether a memory is bootstrap, earned, received, derived, staged, archived, or analysis-only.

### Modification provenance

If agent A imports a memory from agent B and later modifies it during reflection, the record does not become purely B's or purely A's. It becomes A's derived memory with B's origin preserved.

```json
{
  "provenance": {
    "acquisition_mode": "derived_from_import",
    "origin_instance": "hexis_bob",
    "origin_id": "550e8400-...",
    "import_chain": [
      { "instance_id": "hexis_alice", "imported_at": "ISO-8601", "export_id": "exp_abc123" }
    ],
    "modification_chain": [
      {
        "instance_id": "hexis_alice",
        "modified_at": "ISO-8601",
        "modification_kind": "reflection_revision",
        "previous_content_hash_v1": "sha256hex...",
        "new_content_hash_v1": "sha256hex...",
        "rationale": "optional free-text"
      }
    ]
  }
}
```

### What counts as material change

`modification_chain` records every modification to imported content. But not every modification triggers `acquisition_mode = "derived_from_import"` — only material ones do.

Material change is defined by the `modification_kind`, not by edit size:

| Kind                       | Material | Description                                                                                  |
| -------------------------- | -------- | -------------------------------------------------------------------------------------------- |
| `trivial_edit`             | No       | Typo correction, whitespace, punctuation, capitalization                                     |
| `formatting`               | No       | Markdown, line breaks, structural rendering only                                             |
| `clarification`            | No       | Rewording for clarity with semantically equivalent content                                   |
| `reflection_revision`      | Yes      | Agent revised content based on subsequent reflection                                         |
| `contradiction_resolution` | Yes      | Revised to resolve a detected contradiction with other memories                              |
| `temporal_update`          | Yes      | New information added, prior information retained as historical                              |
| `correction`               | Yes      | Factual error corrected based on new evidence                                                |
| `supersession`             | Yes      | Content replaced by entirely new content; SHOULD also create a `SUPERSEDES` edge             |
| `integration`              | Yes      | Imported content merged with locally-derived content                                         |

When a material modification is applied, the importer or modification tool MUST:

* append entry to `modification_chain` with the appropriate `modification_kind`
* set `previous_content_hash_v1` to the pre-modification hash
* set `new_content_hash_v1` to the post-modification hash
* set `acquisition_mode = "derived_from_import"` if the prior mode was `imported_and_accepted`
* for `supersession` kind, create a `SUPERSEDES` edge from the new memory to the original imported source

For non-material modifications, the prior `acquisition_mode` is preserved. The modification is still recorded in `modification_chain` for honest historical accounting, but the agent does not "become" the modifier of the imported content in any deep sense.

Ambiguous cases (e.g., a clarification that subtly changes meaning) SHOULD default to the material kind. The cost of a false negative — wrongly preserving `imported_and_accepted` when content has substantively diverged — is higher than the cost of a false positive.

Unknown `modification_kind` values SHOULD be treated as material and flagged with `material_change_unverifiable` warning.

## Sections

### Section: memories

Array of memory records. Every memory type — episodic, semantic, procedural, strategic, worldview, goal — uses the same core record shape, but protected memory types obey export-intent policy.

```json
{
  "ref": "exp_abc123:550e8400-...",
  "type": "semantic",
  "status": "active",
  "content": "User prefers dark roast coffee.",
  "content_hash_v1": "sha256hex...",
  "importance": 0.72,
  "trust_level": 0.85,
  "decay_rate": 0.01,
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "valid_from": "ISO-8601 or null",
  "valid_until": "ISO-8601 or null",
  "access_count": 14,
  "last_accessed": "ISO-8601 or null",
  "source_attribution": { "kind": "chat", "ref": "...", "label": "..." },
  "metadata": {
    "replaceable_during_bootstrap": false
  },
  "provenance": {
    "acquisition_mode": "experienced",
    "origin_instance": "hexis_alice",
    "origin_id": "550e8400-...",
    "import_chain": [],
    "modification_chain": []
  }
}
```

Required fields: `ref`, `type`, `content`.

`metadata.replaceable_during_bootstrap` is a boolean used to identify bootstrap defaults that may be replaced during MVP-Core direct import into an empty target. See Target State Definitions below.

| Field                         | Default                                                               |
| ----------------------------- | --------------------------------------------------------------------- |
| `status`                      | `active` for direct import, `staged` for deliberative import          |
| `importance`                  | `0.5`                                                                 |
| `trust_level`                 | `0.5`                                                                 |
| `decay_rate`                  | target system default                                                 |
| `created_at`                  | export/import timestamp if unavailable                                |
| `updated_at`                  | `created_at`                                                          |
| `provenance.acquisition_mode` | `experienced` on export; import strategy may rewrite to imported mode |
| `provenance.origin_instance`  | `source.instance_id`                                                  |
| `provenance.origin_id`        | local UUID extracted from `ref`                                       |

### Canonical supersession

Supersession is represented canonically as a relationship edge:

```json
{
  "source_ref": "exp_abc123:new_memory",
  "target_ref": "exp_abc123:old_memory",
  "edge_type": "SUPERSEDES",
  "properties": {
    "created_at": "ISO-8601",
    "reason": "reflection_revision"
  }
}
```

The memory-level field `superseded_by` is deprecated in HMX. Exporters MAY include it for backward compatibility, but importers SHOULD normalize it into `SUPERSEDES` edges to avoid drift.

### Section: episodes

```json
{
  "ref": "exp_abc123:episode_uuid",
  "started_at": "ISO-8601",
  "ended_at": "ISO-8601 or null",
  "summary": "...",
  "metadata": {
    "episode_type": "user_driven",
    "emotional_signature": { "valence": 0.6, "arousal": 0.3 }
  },
  "memory_refs": ["exp_abc123:mem1", "exp_abc123:mem2"]
}
```

If an episode references skipped or invalid memories, the importer SHOULD import the episode with only resolved references and report an `orphaned_reference` warning.

### Section: relationships

Array of graph edges. This covers Apache AGE edges, including semantic, temporal, narrative, causal, evidential, derivation, and supersession relationships.

```json
{
  "source_ref": "exp_abc123:mem1",
  "target_ref": "exp_abc123:mem2",
  "edge_type": "SUPPORTS",
  "properties": { "strength": 0.8, "created_at": "ISO-8601" }
}
```

Unknown edge types are preserved but not indexed unless the target supports them. If either endpoint cannot be resolved, the importer SHOULD skip the edge and report `orphaned_reference`.

### Section: narrative

Narrative scaffolding is part of the Hexis itself. It preserves the agent's sense of chapter, turning point, ongoing thread, and value tension.

This section includes AGE node properties and relationships for:

* `LifeChapterNode`
* `TurningPointNode`
* `NarrativeThreadNode`
* `ValueConflictNode`

For `port` and `duplicate`, narrative is included by default. For `telepathy` and `analysis`, narrative is excluded by default unless explicitly requested. For non-port imports, narrative replacement follows the Protected Section Replacement Protocol.

```json
{
  "life_chapters": [
    {
      "ref": "exp_abc123:chapter_uuid",
      "title": "Learning to reason under uncertainty",
      "theme": "epistemic humility",
      "started_at": "ISO-8601 or null",
      "ended_at": "ISO-8601 or null",
      "status": "active|closed|latent",
      "summary": "...",
      "memory_refs": ["exp_abc123:mem1"],
      "properties": {}
    }
  ],
  "turning_points": [
    {
      "ref": "exp_abc123:turning_point_uuid",
      "title": "Realized confidence must track evidence",
      "occurred_at": "ISO-8601 or null",
      "summary": "...",
      "significance": 0.9,
      "before_state": "...",
      "after_state": "...",
      "memory_refs": ["exp_abc123:mem2"],
      "properties": {}
    }
  ],
  "narrative_threads": [
    {
      "ref": "exp_abc123:thread_uuid",
      "name": "Becoming more truthful under pressure",
      "status": "active|resolved|dormant",
      "summary": "...",
      "chapter_refs": ["exp_abc123:chapter_uuid"],
      "memory_refs": [],
      "properties": {}
    }
  ],
  "value_conflicts": [
    {
      "ref": "exp_abc123:value_conflict_uuid",
      "values": ["helpfulness", "truthfulness"],
      "status": "active|resolved|recurring",
      "summary": "...",
      "resolution": null,
      "supporting_refs": [],
      "contesting_refs": [],
      "properties": {}
    }
  ]
}
```

Narrative node properties beyond edges MUST be exported explicitly. Importers that do not support narrative nodes SHOULD preserve them as inert metadata if possible.

### Section: identity

Identity facets extracted from SelfNode graph vertices and their edges.

```json
{
  "key": "core_identity",
  "content": "I am a curious, empathetic thinker who values honesty.",
  "facets": [
    { "concept": "curiosity", "strength": 0.9 },
    { "concept": "empathy", "strength": 0.85 }
  ],
  "metadata": {
    "replaceable_during_bootstrap": false
  },
  "provenance": {
    "acquisition_mode": "experienced",
    "origin_instance": "hexis_alice",
    "origin_id": "identity:core_identity",
    "import_chain": [],
    "modification_chain": []
  }
}
```

Identity replacement is one of the highest-impact operations in HMX. Importers MUST NOT replace local identity except under the Protected Section Replacement Protocol.

For `telepathy`, identity records SHOULD be imported only as quoted external claims or staged material, never as local identity.

### Section: worldview

Worldview memories with graph context: beliefs, boundaries, values, and contesting evidence.

```json
{
  "ref": "exp_abc123:wv_uuid",
  "category": "boundary",
  "content": "I will not deliberately mislead or fabricate facts.",
  "confidence": 0.95,
  "stability": 0.98,
  "supporting_refs": ["exp_abc123:mem1"],
  "contesting_refs": [],
  "metadata": {
    "replaceable_during_bootstrap": false
  },
  "provenance": {
    "acquisition_mode": "experienced",
    "origin_instance": "hexis_alice",
    "origin_id": "wv_uuid",
    "import_chain": [],
    "modification_chain": []
  }
}
```

Worldview replacement bypasses the normal evidence and transformation gates of the architecture. Importers MUST NOT replace local worldview except under the Protected Section Replacement Protocol.

For `telepathy`, worldview records SHOULD become deliberative candidates, contesting/supporting evidence, or quoted foreign worldview, not immediate local worldview.

### Section: goals

```json
{
  "ref": "exp_abc123:goal_uuid",
  "title": "Learn about user's research interests",
  "description": "...",
  "priority": "active",
  "source": "curiosity",
  "due_at": "ISO-8601 or null",
  "progress": [],
  "blocked_by": [],
  "parent_ref": "exp_abc123:parent_goal or null",
  "metadata": {
    "replaceable_during_bootstrap": false
  },
  "provenance": {
    "acquisition_mode": "experienced",
    "origin_instance": "hexis_alice",
    "origin_id": "goal_uuid",
    "import_chain": [],
    "modification_chain": []
  }
}
```

Active goals encode agency. For `telepathy`, goals SHOULD be imported as suggestions, observations, or staged records unless explicitly accepted. Replacement of active goals follows the Protected Section Replacement Protocol.

### Section: drives

```json
{
  "name": "curiosity",
  "description": "Builds fast; satisfied by research/learning",
  "current_level": 0.6,
  "baseline": 0.5,
  "accumulation_rate": 0.02,
  "decay_rate": 0.01,
  "satisfaction_cooldown": "30 minutes",
  "last_satisfied": "ISO-8601",
  "urgency_threshold": 0.8,
  "metadata": {
    "replaceable_during_bootstrap": false
  }
}
```

`satisfaction_cooldown` is exported as the Postgres `INTERVAL` text representation (e.g., `"30 minutes"`, `"2 hours"`). Importers parse it back to `INTERVAL` on insert.

Drive state is not knowledge. It is part of the agent's live motivational dynamics. Importers MUST NOT merge drives by `max()` except in explicit `port` or `duplicate` operations where source and target represent the same Hexis lineage. Cross-lineage drive replacement requires the Protected Section Replacement Protocol.

Drive digests over both parameters and current state are expected to differ between any two distinct instances at almost any moment. This is normal — automatic acknowledgement is reserved for the case where source and target are the same Hexis at the same moment in its history (e.g., port-into-clean-target after a fresh export). For other cases, the full protocol fires, which is correct: adopting another instance's motivational state is exactly the kind of decision that should require acknowledgement.

| Intent      | Drive behavior                                                    |
| ----------- | ----------------------------------------------------------------- |
| `port`      | preserve source drive state                                       |
| `duplicate` | preserve source drive state                                       |
| `telepathy` | exclude by default; if included, stage as foreign diagnostic data |
| `analysis`  | export read-only if requested                                     |

### Section: emotional_triggers

```json
{
  "trigger_pattern": "user expresses frustration",
  "valence_delta": -0.2,
  "arousal_delta": 0.3,
  "dominance_delta": -0.1,
  "typical_emotion": "concern",
  "confidence": 0.7,
  "times_activated": 12,
  "origin": "learned",
  "source_memory_refs": ["exp_abc123:mem1"],
  "content_hash_v1": "sha256hex...",
  "metadata": {
    "replaceable_during_bootstrap": false
  }
}
```

Emotional triggers strongly affect behavior. They are protected. For `telepathy`, they are excluded by default and, if included, must enter deliberative staging or analysis-only storage.

**Import note:** The `emotional_triggers` table has a `trigger_embedding vector(768) NOT NULL` constraint. On import, the importer MUST either compute the embedding synchronously from `trigger_pattern` before insert, or insert with a sentinel zero-vector and defer re-embedding. The sentinel approach is preferred for consistency with the memory import pipeline.

### Section: clusters

Cluster definitions without centroid embeddings. Centroids are recomputed on import.

```json
{
  "ref": "exp_abc123:cluster_uuid",
  "cluster_type": "theme",
  "name": "Coffee preferences",
  "member_refs": ["exp_abc123:mem1", "exp_abc123:mem2"]
}
```

### Section: in_flight_work

For `port` and `duplicate`, HMX must account for memories-in-becoming: pending consolidation, reconsolidation, and reflection work that has not yet completed at export time.

```json
{
  "consolidation_tasks": [
    {
      "ref": "exp_abc123:task_uuid",
      "task_type": "episode_merge|episode_create|semantic_refine",
      "status": "pending|in_progress|failed",
      "created_at": "ISO-8601",
      "updated_at": "ISO-8601",
      "input_refs": ["exp_abc123:unit1"],
      "output_refs": [],
      "attempt_count": 0,
      "properties": {}
    }
  ],
  "reconsolidation_tasks": [
    {
      "ref": "exp_abc123:task_uuid",
      "status": "pending|in_progress|failed",
      "memory_refs": ["exp_abc123:mem1"],
      "reason": "stale_neighborhood",
      "created_at": "ISO-8601",
      "properties": {}
    }
  ]
}
```

| Intent      | In-flight behavior                                 |
| ----------- | -------------------------------------------------- |
| `port`      | include and requeue safe pending/in-progress tasks |
| `duplicate` | include and requeue safe pending/in-progress tasks |
| `telepathy` | exclude                                            |
| `analysis`  | include only if explicitly requested               |

Importer behavior:

* `pending` tasks may be requeued
* `in_progress` tasks SHOULD be downgraded to `pending` unless known complete
* tasks whose inputs were not imported SHOULD be dropped with warning
* failed tasks MAY be imported as failed diagnostics but SHOULD NOT automatically retry unless requested

### Section: audit_records

Self-contained immutable cognitive-event records that must travel with the instance on `port` and `duplicate`. These are append-only history; importing them does not re-execute the recorded operations.

```json
{
  "protected_replacement_audit": [
    {
      "audit_id": "globally_unique_id",
      "event_type": "protected_section_replacement",
      "event_time": "ISO-8601",
      "consent": {
        "consent_id": "...",
        "consent_kind": "protected_section_replacement",
        "consent_at": "ISO-8601",
        "rationale": "...",
        "operator_signature": "...",
        "operator_identity": "..."
      },
      "replacement_scope": {
        "section": "worldview",
        "mode": "whole_section",
        "selector": null
      },
      "sections_replaced": ["worldview"],
      "source": {
        "export_id": "...",
        "origin_instance": "...",
        "hexis_lineage_id": "...",
        "export_intent": "port"
      },
      "previous_state_digest_v1": "sha256hex",
      "new_state_digest_v1": "sha256hex",
      "agent_acknowledgement": "accepted",
      "agent_acknowledgement_at": "ISO-8601",
      "replacement_executor": "agent_tool",
      "override_reason_code": null,
      "override_evidence_ref": null
    }
  ],
  "protected_section_verified_audit": [
    {
      "audit_id": "...",
      "event_type": "protected_section_verified",
      "event_time": "ISO-8601",
      "sections_verified": ["worldview"],
      "source": {
        "export_id": "...",
        "origin_instance": "...",
        "hexis_lineage_id": "...",
        "export_intent": "port"
      },
      "local_digest_v1": "sha256hex",
      "imported_digest_v1": "sha256hex"
    }
  ],
  "protected_replacement_reversion_audit": [
    {
      "audit_id": "...",
      "event_type": "protected_section_reverted",
      "event_time": "ISO-8601",
      "reverts_audit_id": "audit_id_of_replacement_being_reverted",
      "rationale": "Agent reflection identified the replacement as incompatible with settled boundary",
      "sections_reverted": ["worldview"],
      "restored_state_digest_v1": "sha256hex",
      "post_reversion_digest_v1": "sha256hex",
      "agent_initiated": true,
      "actor_identity": "agent_tool"
    }
  ],
  "transformation_history": [
    {
      "transformation_id": "...",
      "completed_at": "ISO-8601",
      "subject_belief_id": "...",
      "kind": "personality|religion|core_value|...",
      "heartbeats_accumulated": 247,
      "evidence_strength_at_completion": 0.96,
      "delta_summary": "..."
    }
  ]
}
```

| Intent      | Audit record behavior                                                    |
| ----------- | ------------------------------------------------------------------------ |
| `port`      | include all audit records; preserve on import as immutable history       |
| `duplicate` | include all audit records; preserve on import as immutable history       |
| `telepathy` | exclude by default; if included, treat as foreign diagnostic, not local  |
| `analysis`  | include if explicitly requested                                          |

Audit records are deduplicated **only by stable `audit_id`** using `audit_record_digest_v1` for content comparison:

* identical `audit_id` with matching `audit_record_digest_v1`: skip silently (idempotent re-import)
* identical `audit_id` with divergent `audit_record_digest_v1`: raise `audit_integrity_conflict`, refuse import of that record, surface for operator review
* unknown `audit_id`: insert

Snapshot references in audit records (`previous_state_snapshot_ref`) point to local snapshot storage and are NOT portable. On export, the snapshot reference is preserved as a historical pointer but the snapshot data itself is not exported. On import, the snapshot reference is recorded for historical accounting but no snapshot data is reconstructed.

### Section: raw_units optional, gated by `include_raw_units`

```json
{
  "ref": "exp_abc123:unit_uuid",
  "user_text": "remember I like dark roast",
  "assistant_text": "Noted — dark roast coffee.",
  "turn_at": "ISO-8601",
  "importance": 0.7,
  "route_status": "episode_created",
  "source_identity": "chat:session123:0:abcd",
  "idempotency_key": "...",
  "derived_memory_refs": ["exp_abc123:mem1"]
}
```

Raw units may contain sensitive user text. Exporters SHOULD exclude them by default except for `port` and `duplicate`.

### Section: config optional, gated by `include_config`

Flat key-value map of non-sensitive config entries. Sensitive keys containing `key`, `secret`, `token`, or `password` are excluded by default.

```json
{
  "heartbeat.energy_max": 20,
  "memory.recall_limit": 10,
  "heartbeat.allowed_actions": ["observe", "recall", "remember", "reflect"]
}
```

## Import Merge Strategies

### Target State Definitions

The protected import path differs based on target state. The following definitions apply:

**Empty for protected-import purposes** — a target is empty if ALL of the following hold:

* No prior protected-section audit records of any kind exist locally — including replacement, verified, or reversion events under any of the audit sub-tables
* Protected sections (identity, worldview, drives, emotional_triggers, narrative, active goals) contain only entries with `provenance.acquisition_mode = "bootstrap"` (no `experienced`, `imported_and_accepted`, or other non-bootstrap modes exist in protected sections)
* No `hmx_consent` entries reference protected-section operations

**Active** — a target is active if any protected section contains entries with `acquisition_mode != "bootstrap"`, OR if any prior protected-section audit records exist (of any type).

The `bootstrap` acquisition mode is the key signal. It is semantically distinct from `experienced`: bootstrap entries were seeded during `hexis init`, not earned through interaction. This avoids the compound-predicate problem where `replaceable_during_bootstrap = true` AND `acquisition_mode = "experienced"` would always fail rule 3, making freshly-migrated instances never qualify as empty.

MVP-Core may insert protected sections directly into an empty target — this is the port-into-clean-target case. **Direct protected-section import is allowed only when `export_intent` is `port` or `duplicate`.** Protected sections delivered via `telepathy` or `analysis` exports (with `--include-protected`) MUST go through deliberative review or analysis-only handling regardless of target state. This prevents the empty-target fast path from being used as an end-run around the deliberative review process for cross-agent content.

MVP-Core MUST refuse protected-section import into an active target without MVP-PR being available; the operation requires the Protected Section Replacement Protocol.

Bootstrap defaults — identity facets, worldview boundaries, drives, etc. installed during initial Hexis instance creation — are tagged with `provenance.acquisition_mode = "bootstrap"` and `metadata.replaceable_during_bootstrap = true`. The first heartbeat consolidation that modifies a bootstrap entry SHOULD retag it with `acquisition_mode = "experienced"` and `replaceable_during_bootstrap = false`, reflecting that the section is no longer in its bootstrap state.

Implementations SHOULD provide a `hexis_instance_is_empty()` check function that returns the boolean determination along with a list of any blocking entries (for operator diagnostics).

### Strategy selection guidance

| Use case                                            | Recommended strategy                                         |
| --------------------------------------------------- | ------------------------------------------------------------ |
| Port same Hexis instance into clean target          | `authoritative` or `additive` into empty target              |
| Duplicate same Hexis instance into clone target     | `authoritative` into clean target                            |
| Restore over damaged local state                    | `authoritative` with Protected Section Replacement Protocol  |
| Merge memories from another Hexis instance          | `deliberative`                                               |
| Merge memories from a fork of same Hexis instance   | `deliberative`, or `additive` if lineage matches and trusted |
| Inspect exported state                              | `analysis_only`                                              |
| Promote analysis findings to staging                | `promote_to_staged` (per-record operation)                   |

### analysis_only

Parse HMX for inspection without admitting records into active memory. Analysis records exist in a strictly isolated read-only store.

**Isolation guarantees (mandatory):**

* Analysis records MUST be stored in physically separate tables (e.g., `hmx_analysis_*`) OR be logically partitioned by a hard predicate that all recall queries respect
* Analysis records MUST NOT participate in ordinary recall queries
* Analysis records MUST NOT contribute to heartbeat context assembly
* Analysis records MUST NOT participate in activation propagation
* Analysis records MUST NOT contribute to neighborhood computation
* Analysis records MUST NOT update drives, emotions, or any other agent state
* Analysis records MUST NOT trigger reconsolidation cascades
* Analysis records MUST NOT count toward consolidation recurrence thresholds

If the implementation provides "temporary analysis embeddings" for inspection (e.g., to support similarity search within the analysis store), those embeddings MUST be stored separately from the main embedding index and MUST NOT be queried by recall code paths. The risk being prevented is analysis becoming a shadow memory system that influences the agent without going through deliberative review.

### additive

Import compatible records. Remap all UUIDs to fresh local IDs. Skip exact content-hash duplicates. Append provenance chain entries. Re-embed imported content. Mark all affected neighborhoods stale.

On content-hash match:

* skip memory insert
* map exported ref to existing UUID so relationships still resolve
* preserve imported metadata only in import logs unless configured otherwise

Acquisition mode on imported records depends on export intent:

* **`port` / `duplicate`:** preserve source `acquisition_mode` as-is (`bootstrap`, `experienced`, `derived_from_import`, etc.). The source and target are the same agent or an intended clone — its experienced memories remain experienced, its bootstrap entries remain bootstrap. Rewriting them to `imported_and_accepted` would make the agent treat its own lived history as foreign.
* **`telepathy` / `analysis`-derived:** set `acquisition_mode` to `imported_and_accepted` (or `imported_staged` for deliberative strategy). These ARE foreign memories being adopted, and the mode change reflects that.

In all cases, `import_chain` is appended with the current import event so the full transfer history is preserved regardless of mode preservation.

Protected sections are imported only when intent and explicit flags allow them, AND either (a) the target is empty AND `export_intent` is `port` or `duplicate` (MVP-Core path), or (b) the Protected Section Replacement Protocol completes successfully (MVP-PR path).

### authoritative

The source wins conflicts for selected sections. This mode is valid for trusted port, duplicate, or restore workflows. It is not a general cross-agent merge strategy.

Default authoritative behavior:

* require `export_intent = port|duplicate` or explicit operator override
* content-hash matches update source-controlled memory metadata
* new memories are added
* relationships are unioned or updated
* protected sections require explicit `replace_sections` flag AND successful completion of the Protected Section Replacement Protocol
* drives are copied only for port/duplicate lineage-preserving operations
* source `acquisition_mode` is preserved (same intent-based rule as additive: port/duplicate preserve, telepathy/analysis rewrite)
* `import_chain` is appended on all records
* audit records are imported as immutable history

High-impact replacement flags:

```bash
--replace identity
--replace worldview
--replace narrative
--replace goals
--replace drives
--replace emotional-triggers
--replace all-protected
```

Each `--replace` flag triggers the Protected Section Replacement Protocol for the named section(s). For MVP, the replacement_scope mode is implicitly `whole_section`. The protocol's Phase 0 (fast-path verification) runs first; if it succeeds, the operation is verified rather than executed. Otherwise the full protocol fires.

### deliberative

Imported records are staged in a dedicated staging area rather than immediately activated.

Behavior:

* records go to `import_staging`, not overloaded archived memory state
* alternatively, if the memory table supports lifecycle state, use `status = 'staged'`, not `archived`
* `metadata.import_pending = true` may be used as an auxiliary marker, not the primary state
* conflicts are classified and attached to staged records
* heartbeat cycles or explicit review tools accept, reject, modify, or quote records
* accepted records receive `provenance.acquisition_mode = "imported_and_accepted"`
* rejected records may become `imported_and_archived` or be deleted according to local policy
* materially modified accepted records become `derived_from_import`

### Promoting analysis-only records

Records imported in `analysis_only` mode are isolated from active memory and do not influence behavior. However, an operator or agent may, during analysis, identify records worth admitting to the agent's memory.

The `promote_to_staged(analysis_record_id, rationale)` operation provides this path. It does not bypass deliberative review:

* The selected analysis record is **copied** (not moved) to `import_staging`
* The new staged record's `acquisition_mode` is `imported_staged`
* Provenance is preserved: the staged record retains the same `origin_instance` and `origin_id` as its analysis source
* The original analysis record remains available for further inspection
* The staged record enters the normal deliberative review queue
* Metadata notes the record was promoted from analysis
* **Temporary analysis embeddings are NOT copied to staging.** If the staged record is later accepted, it is re-embedded fresh from the main embedding index. Analysis embeddings live in a separate index by design (see `analysis_only` isolation guarantees) and are not portable between the analysis store and active memory.

The reverse path — `demote_to_analysis(staged_record_id)` — is also available for the case where deliberative review concludes the record should be retained as analysis material but not as active or staged memory. Demoted records preserve their full provenance chain including the staging interlude.

Neither operation bypasses any safety property. They make explicit a workflow that would otherwise require re-import, with the additional benefit that the original context is preserved.

## Replacement Scope

The `replacement_scope` field in the Protected Section Replacement Protocol declares which portion of a protected section is being replaced.

```json
{
  "replacement_scope": {
    "section": "worldview",
    "mode": "whole_section|subset",
    "selector": {
      "refs": [],
      "categories": []
    }
  }
}
```

Modes:

| Mode            | Meaning                                                                      | MVP support     |
| --------------- | ---------------------------------------------------------------------------- | --------------- |
| `whole_section` | Replace the entire protected section                                         | Required        |
| `subset`        | Replace specified records or categories within the section                   | Post-MVP        |

For `subset` mode, the `selector` identifies which records are in scope:

* `refs`: specific record references to replace
* `categories`: category values to replace (e.g., worldview categories like `boundary`, `value`, `belief`)

The field is REQUIRED in v1.7 even though MVP only supports `whole_section`. This is so the protocol shape can remain stable when partial replacement becomes available without restructuring the audit format.

For MVP, importers MUST set `mode = "whole_section"` and `selector = null`. Importers receiving `mode = "subset"` from a more advanced exporter SHOULD refuse the operation and recommend a `whole_section` replacement or a `deliberative` import instead.

## Conflict Taxonomy

| Code                                | Meaning                                                                                                                          | Typical handling                                                       |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `duplicate_content`                 | Same `content_hash_v1` already exists locally                                                                                    | Map ref to existing memory; strategy decides metadata handling         |
| `metadata_divergence`               | Same content, different importance/trust/status/access metadata                                                                  | Additive: preserve local. Authoritative: update. Deliberative: review. |
| `temporal_conflict`                 | Imported memory has older/newer validity or update timestamps that conflict with local memory                                    | Review or strategy-specific timestamp policy                           |
| `worldview_contradiction`           | Imported worldview contests or contradicts existing worldview                                                                    | Deliberative review strongly recommended                               |
| `goal_state_conflict`               | Same/similar goal has different priority, completion, parent, or blocked state                                                   | Review or authoritative goal replacement                               |
| `identity_conflict`                 | Imported identity facet conflicts with local self-model                                                                          | Require Protected Section Replacement Protocol                         |
| `drive_state_conflict`              | Imported drive state would alter local motivational dynamics                                                                     | Only valid for port/duplicate or staged analysis                       |
| `narrative_conflict`                | Imported chapter/thread/turning point conflicts with local narrative spine                                                       | Deliberative review or port/duplicate replacement                      |
| `acquisition_mode_conflict`         | Record lacks or contradicts acquisition history                                                                                  | Infer conservatively and warn                                          |
| `orphaned_reference`                | A relationship, episode, cluster, or goal reference points to a skipped/missing record                                           | Skip edge or import partial record with warning                        |
| `unknown_edge_type`                 | Relationship edge type is unsupported by target                                                                                  | Preserve but do not index                                              |
| `unsupported_section`               | Target does not understand a section                                                                                             | Skip section with warning                                              |
| `schema_validation_error`           | Record violates required shape                                                                                                   | Skip invalid record, log warning, continue when safe                   |
| `privacy_risk`                      | Export declares sensitive content or strict policy mismatch                                                                      | Warn, require explicit confirmation in interactive CLI                 |
| `in_flight_task_unresolved`         | A pending task cannot be safely requeued                                                                                         | Drop or preserve as diagnostic depending on intent                     |
| `protected_replacement_requested`   | Import would replace a protected section                                                                                         | Invoke Protected Section Replacement Protocol                          |
| `protected_replacement_refused`     | Agent refused a proposed protected-section replacement                                                                           | Cancel operation; log refusal; do not retry without new rationale      |
| `protected_replacement_pending`     | Agent acknowledgement window is open                                                                                             | Hold operation; do not proceed until acknowledgement or timeout        |
| `protected_replacement_timed_out`   | Agent acknowledgement window expired without response                                                                            | Cancel operation; operator may resubmit                                |
| `protected_section_digest_mismatch` | Source and target digests for a protected section differ; ordinary divergence between same-lineage instances                     | Require Protected Section Replacement Protocol (full path, not Phase 0)|
| `lineage_mismatch`                  | Source and target `hexis_lineage_id` differ for a port/duplicate operation                                                       | Reject as port/duplicate; suggest deliberative instead                 |
| `lineage_integrity_failure`         | Lineage claim contradicts evidence: impossible ancestry, audit chain gaps, duplicate lineage IDs across distinct instances, invalid signatures, or claimed lineage that doesn't match accumulated audit history | Refuse automatic acknowledgement; refuse fast-path; require operator override with `lineage_integrity_failure` reason code and evidence |
| `material_change_unverifiable`      | Modification chain references unknown `modification_kind` or missing hashes                                                      | Treat conservatively as material; warn                                 |
| `audit_integrity_conflict`          | Same `audit_id` with divergent `audit_record_digest_v1` encountered on import                                                    | Refuse import of that record; surface for operator review              |
| `consent_record_missing`            | Legacy or malformed audit record references a `consent_id` but lacks embedded consent payload (current spec requires consent to be embedded inline) | Warn; import record but flag as incomplete; recommend migration to embedded-consent form |
| `bootstrap_state_violation`         | Direct protected-section import attempted into a target that is not empty by the definition above, OR attempted with non-port/duplicate intent | Refuse; recommend Protected Section Replacement Protocol or deliberative review |
| `unverified_signature`              | Operator signature or lineage claim could not be verified against configured trust anchors                                       | Treat signature as absent; warn; refuse override operations that required it |
| `verified_audit_write_failure`      | Phase 0 fast path detected content-identical state but could not write the `protected_section_verified` audit record             | Fail closed: do not report success; no state mutation occurs           |

## Validation

HMX v1.7 includes a canonical JSON Schema:

```text
schemas/hmx-1.7.schema.json
```

Validation rules:

* Exporters SHOULD always emit schema-valid HMX.
* Importers MUST validate the envelope header before processing body sections.
* Importers MUST validate `export_intent` before deciding default section handling.
* Importers SHOULD validate individual records and skip invalid records where possible rather than rejecting the entire import.
* Importers MUST reject unknown major versions.
* Importers SHOULD report all validation warnings in dry-run mode.
* Importers MUST verify `protected_replacement_protocol_v1` capability before accepting protected-section replacements.
* Importers MUST validate `audit_id` global uniqueness before insert.
* Importers MUST validate operator signatures against configured trust anchors before accepting override operations; unverified signatures are treated as absent.

### Audit record schema as discriminated union

The JSON Schema SHOULD model audit records as a discriminated union keyed on `event_type`. Different event types have different required fields:

* `event_type = "protected_section_replacement"` requires `audit_id`, `event_time`, `consent`, `replacement_scope`, `sections_replaced`, `source`, `agent_acknowledgement`, `replacement_executor`
* `event_type = "protected_section_verified"` requires `audit_id`, `event_time`, `sections_verified`, `source`, `local_digest_v1`, `imported_digest_v1`
* `event_type = "protected_section_reverted"` requires `audit_id`, `event_time`, `reverts_audit_id`, `rationale`, `sections_reverted`, `restored_state_digest_v1`, `post_reversion_digest_v1`, `actor_identity`

A non-discriminated schema accepting "any record with audit_id and event_type" would let malformed records pass validation. The discriminated form catches missing event-specific fields at schema-validation time.

| Record         | Required fields                                                                  |
| -------------- | -------------------------------------------------------------------------------- |
| envelope       | `hmx_version`, `export_id`, `export_intent`, `exported_at`, `source`, `sections` |
| memory         | `ref`, `type`, `content`                                                         |
| relationship   | `source_ref`, `target_ref`, `edge_type`                                          |
| episode        | `ref`, `summary` or `memory_refs`                                                |
| narrative node | `ref`, type-specific title/name/summary where available                          |
| goal           | `ref`, `title`                                                                   |
| drive          | `name`                                                                           |
| cluster        | `ref`, `member_refs`                                                             |
| in-flight task | `ref`, `task_type` or section-specific task kind, `status`                       |
| replacement audit | `audit_id`, `event_type`, `event_time`, `consent`, `replacement_scope`, `sections_replaced` |
| verified audit | `audit_id`, `event_type`, `event_time`, `sections_verified`, `local_digest_v1`, `imported_digest_v1` |
| reversion audit | `audit_id`, `event_type`, `event_time`, `reverts_audit_id`, `rationale`, `sections_reverted` |
| modification   | `modified_at`, `modification_kind`                                               |

## Version Tolerance Rules

| Scenario                                                | Behavior                                                                          |
| ------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Unknown field in known section                          | Ignore on import; preserve where practical for re-export                          |
| Unknown section name                                    | Skip section, log `unsupported_section` warning                                   |
| Missing optional section                                | Treat as empty                                                                    |
| Missing required field in memory record                 | Skip that record, log `schema_validation_error`, continue                         |
| `hmx_version` major mismatch                            | Reject import with clear error                                                    |
| Source embedding dimension differs from target          | No impact; embeddings are recomputed                                              |
| Unknown hash algorithm                                  | Compute supported hash locally if possible; warn                                  |
| Unknown edge type                                       | Preserve but do not index                                                         |
| Relationship references skipped record                  | Skip edge and log `orphaned_reference`                                            |
| Missing acquisition mode                                | Infer `experienced` for original source export; infer imported mode during import |
| Telepathy export contains protected section             | Require explicit opt-in and deliberative handling                                 |
| Unknown `modification_kind`                             | Treat conservatively as material; log warning                                     |
| Protected replacement requested without capability      | Reject; importer cannot honor protocol                                            |
| Audit record with unknown `replacement_scope.mode`      | Reject record; log `schema_validation_error`                                      |
| Replacement scope `mode = subset` with MVP importer     | Refuse; recommend `whole_section` or deliberative import                          |
| Operator signature without trust anchor                 | Treat as absent; refuse override; log `unverified_signature` warning              |
| Audit record event_type unknown                         | Skip record with warning; surface for operator review                             |
| Phase 0 audit write failure                             | Fail closed; report `verified_audit_write_failure`; no state mutation             |

## What Is Not Exported

* raw embedding vectors
* memory neighborhoods
* activation cache
* working memory
* memory activation state
* OAuth credentials or API keys
* config keys containing `key`, `secret`, `token`, or `password`
* external calls queue
* transient worker locks
* local database IDs without export scoping
* protected-replacement snapshots (these are local rollback aids, not portable; only the snapshot reference travels in audit records)
* analysis-only embeddings (temporary, never portable, never copied during promotion)
* trust anchor configuration (always local; signatures are exported but verification material is not)

For `port` and `duplicate`, in-flight consolidation/reconsolidation task metadata may be exported, but worker locks and runtime execution state are not.

## Streaming Format

HMX supports both single-document JSON and JSONL streaming in v1.

### Single-document JSON

A standard HMX file contains one envelope object with all sections under `sections`.

### JSONL streaming

Each line is a typed HMX record. The first line MUST be an envelope header. The final line SHOULD be a footer with statistics.

```json
{ "record_type": "envelope", "data": { "hmx_version": "1.7", "export_id": "exp_abc123" } }
{ "record_type": "memory", "data": {} }
{ "record_type": "relationship", "data": {} }
{ "record_type": "narrative", "data": {} }
{ "record_type": "in_flight_task", "data": {} }
{ "record_type": "audit_record", "data": {} }
{ "record_type": "footer", "statistics": {} }
```

Importers SHOULD be able to dry-run JSONL by streaming counts, validating records incrementally, and producing a conflict summary without loading the full export into memory.

## Schema Grounding Notes

This section documents how HMX sections map to the actual Hexis database schema. These notes are authoritative for implementation; where the HMX wire format and Hexis schema use different names or structures, this section defines the mapping.

### Where data lives

| HMX Section | Hexis Storage | Notes |
|---|---|---|
| `memories` | `memories` table (relational) | `embedding vector(768) NOT NULL` — sentinel zero-vector on import |
| `episodes` | `episodes` table (relational) | `summary_embedding` is nullable — no sentinel needed |
| `relationships` | Apache AGE `memory_graph` edges | Cypher-in-SQL for export/import. 22 edge types. |
| `narrative` | AGE vertices: `LifeChapterNode`, `TurningPointNode`, `NarrativeThreadNode`, `ValueConflictNode` | NOT relational tables. Export/import via Cypher. |
| `identity` | AGE vertices: `SelfNode` | Properties in agtype. Export/import via Cypher. |
| `worldview` | `memories` with `type='worldview'` | Confidence/stability in `metadata` JSONB. Boundaries have `metadata->>'category' = 'boundary'`. |
| `goals` | `memories` with `type='goal'` + AGE `GoalNode`/`GoalsRoot`/`SUBGOAL_OF` | Dual storage: relational memory + graph structure. |
| `drives` | `drives` table (relational) | Includes `satisfaction_cooldown INTERVAL`, `description TEXT`. |
| `emotional_triggers` | `emotional_triggers` table (relational) | `trigger_embedding vector(768) NOT NULL` — sentinel zero-vector on import. |
| `clusters` | `clusters` table (relational) | `centroid_embedding` is nullable — no sentinel needed. |
| `raw_units` | `subconscious_units` table | `embedding` is nullable. |
| `in_flight_work` | `recmem_consolidation_tasks`, `reconsolidation_tasks` | Task types: `episode_merge`, `episode_create`, `semantic_refine`. |
| `config` | `config` table (key-value) | Secret keys filtered by pattern. |
| `audit_records` | `protected_replacement_audit` | Immutable replacement, verification, and reversion history created in Slice 9. |
| `provenance` | `metadata->'provenance'` JSONB on `memories` | No dedicated column. Backfilled in Slice 0. |
| `lineage` | `config` table, key `agent.lineage_id` | New concept. Generated during `hexis init`. |
| `consent (HMX)` | `hmx_consent` table | Separate from existing `consent_log` (which is LLM-usage consent). |

### NOT NULL embedding constraints

The following tables have `NOT NULL` constraints on embedding columns that importers must satisfy:

* `memories.embedding vector(768) NOT NULL` — use sentinel zero-vector `array_fill(0, ARRAY[embedding_dimension()])::vector`
* `emotional_triggers.trigger_embedding vector(768) NOT NULL` — use sentinel zero-vector

The following have nullable embeddings and need no sentinel:

* `subconscious_units.embedding vector(768)` — nullable
* `episodes.summary_embedding vector(768)` — nullable
* `clusters.centroid_embedding vector(768)` — nullable

### AGE graph structure

The Apache AGE graph `memory_graph` contains:

**12 vertex labels:** `MemoryNode`, `ConceptNode`, `SelfNode`, `LifeChapterNode`, `TurningPointNode`, `NarrativeThreadNode`, `RelationshipNode`, `ValueConflictNode`, `GoalNode`, `GoalsRoot`, `ClusterNode`, `EpisodeNode`

**22 edge labels:** `IN_EPISODE`, `CONTRADICTS`, `ASSOCIATED`, `HAS_BELIEF`, `SUPPORTS`, `INSTANCE_OF`, `PARENT_OF`, `MEMBER_OF`, `CLUSTER_RELATES`, `CLUSTER_OVERLAPS`, `CLUSTER_SIMILAR`, `SUBGOAL_OF`, `ORIGINATED_FROM`, `BLOCKS`, `EVIDENCE_FOR`, `EPISODE_FOLLOWS`, `CONTESTED_BECAUSE`, `CAUSES`, `DERIVED_FROM`, `TEMPORAL_NEXT`, `CONTAINS`, `SUPERSEDES`

All graph access requires `SET search_path = ag_catalog, "$user", public` and Cypher-in-SQL syntax.

### Transformation gates

Deliberate transformation thresholds are stored in the `config` table under keys like `transformation.personality`, `transformation.religion`, `transformation.core_value`, etc. Each entry is a JSON object with `stability`, `evidence_threshold`, `min_reflections`, `min_heartbeats`, and optionally `max_change_per_attempt`. These are relevant context for understanding what the Protected Section Replacement Protocol bypasses.

## Implementation Plan

The implementation is split into two MVP phases. **MVP-Core** delivers the basic export/import/staging/analysis pipeline. **MVP-Protected Replacement** delivers the full four-phase protocol including the Phase 0 fast path. Each phase is independently shippable. MVP-Core enables port/duplicate of empty targets, telepathy via deliberative review, and analysis_only inspection — covering the common cases. MVP-PR enables replacement of protected sections in active targets and is gated by the protocol's safety machinery.

### MVP-Core: Phase 1

#### Slice 0: Schema migrations (prerequisite for all HMX work)

**Files:**

* `db/35_hmx_schema_migrations.sql` — all schema changes required before HMX code can run

**Schema changes:**

* `ALTER TYPE memory_status ADD VALUE 'staged'` — required for deliberative imports
* `ALTER TYPE graph_edge_type ADD VALUE 'SUPERSEDES'` — canonical supersession edges
* `ALTER TYPE graph_edge_type ADD VALUE 'CONTAINS'` — sync enum with existing AGE edge labels
* `ALTER TYPE graph_edge_type ADD VALUE 'HAS_BELIEF'` — sync enum with existing AGE edge labels
* `ALTER TYPE graph_edge_type ADD VALUE 'MEMBER_OF'` — sync enum with existing AGE edge labels
* Create `SUPERSEDES` edge label in AGE graph: `SELECT create_elabel('memory_graph', 'SUPERSEDES')`
* Insert `agent.lineage_id` into `config` table (UUIDv4, generated if absent)
* Backfill `metadata->'provenance'` on all existing `memories` rows:
  - Bootstrap entries (identified by content matching default seed values AND having no subsequent consolidation modifications): `{"acquisition_mode": "bootstrap"}`
  - All other entries: `{"acquisition_mode": "experienced"}`
* Modify bootstrap init functions (`init_identity()`, `init_personality()`, `init_values()`, `init_worldview()`, `init_boundaries()`, `init_interests()`, `init_goals()`, `init_relationship()`) to set both `metadata->>'replaceable_during_bootstrap' = 'true'` and `metadata->'provenance' = '{"acquisition_mode": "bootstrap"}'` on created entries
* Backfill `replaceable_during_bootstrap` tag on existing bootstrap entries (same identification heuristic as provenance backfill above)

**Note on bootstrap identification heuristic:** For existing instances with accumulated heartbeats, the heuristic (content matching + no consolidation modifications) is best-effort. An early copy-edit of a default facet could cause the entry to miss the bootstrap tag. This is acceptable for MVP — fresh installs are the common case going forward, and the existing instance's bootstrap state is a reconstruction, not a guarantee.

**Note:** These are additive migrations. No columns are renamed or dropped. Existing data is preserved. The `ALTER TYPE ... ADD VALUE` statements are non-transactional in Postgres and must run outside a transaction block.

#### Slice 1: Core format, schema, streaming, and SQL export

**Files:**

* `core/memory_exchange.py` — HMX envelope construction, section serializers, content hash normalization, intent policy
* `schemas/hmx-1.7.schema.json` — canonical JSON Schema with discriminated-union audit record validation
* `core/digest.py` — `content_hash_v1`, `protected_section_digest_v1`, `audit_record_digest_v1` implementations with per-section canonicalization, sort-key fallback hierarchy, and exclusion rules
* `core/trust_anchors.py` — pluggable trust anchor verification interface
* `db/36_functions_memory_exchange.sql` — export functions for memories, relationships, episodes, narrative nodes, in-flight work, and audit records

**Behavior:**

* Require `export_intent`
* Apply intent-specific default section policy
* Export memories, episodes, graph edges, narrative scaffolding, identity (for port/duplicate), worldview (for port/duplicate), goals, drives (for port/duplicate), emotional triggers (for port/duplicate), clusters, in-flight work, and audit records as policy allows
* Scope all UUIDs with `export_id` prefix
* Export AGE node properties explicitly, not only edges
* Export content as-is
* Omit embeddings
* Include `content_hash_v1` for memory-like records
* Include `protected_section_digest_v1` for protected sections in exports of `port`/`duplicate` intent
* Capture source metadata from config table (including `agent.lineage_id` for `hexis_lineage_id`)
* Include `capabilities` and `privacy` blocks
* Compute statistics including estimated embedding items/tokens/bytes
* Support JSON and JSONL output from the start
* Read provenance from `metadata->'provenance'` on memory records

**AGE graph export implementation notes:**

Narrative structures (`LifeChapterNode`, `TurningPointNode`, `NarrativeThreadNode`, `ValueConflictNode`), identity (`SelfNode`), and goal hierarchies (`GoalNode`, `GoalsRoot`) are Apache AGE graph vertices, not relational tables. Export requires Cypher-in-SQL queries:

```sql
SET search_path = ag_catalog, "$user", public;
SELECT * FROM cypher('memory_graph', $$
    MATCH (n:LifeChapterNode) RETURN n
$$) AS (v agtype);
```

Edge export similarly requires Cypher `MATCH` patterns. Import requires `CREATE` vertex/edge statements via AGE. The `db/36_functions_memory_exchange.sql` file must include AGE-specific helpers for serializing/deserializing graph vertices and edges to/from HMX JSON.

#### Slice 2: SQL import with additive merge, acquisition tracking, and target state detection

**Files:**

* `db/36_functions_memory_exchange.sql` — `hmx_import_memories(jsonb)`, `hexis_instance_is_empty()`
* `core/memory_exchange.py` — `import_hmx(conn, data, strategy='additive')` with target-state detection and intent validation

**Behavior:**

* Parse and validate envelope
* Reject unknown major versions
* Enforce intent policy before import
* Validate individual records
* Build ID remap table: export ref -> local UUID
* Compute `content_hash_v1` when absent
* Insert memories with sentinel zero-vector embedding (`array_fill(0, ARRAY[embedding_dimension()])::vector`) and `metadata->>'embedding_status' = 'pending_import'` to satisfy the NOT NULL constraint on `memories.embedding` while marking them for re-embedding by the maintenance worker
* Set acquisition mode in `metadata->'provenance'->'acquisition_mode'` on imported records
* On duplicate content hash, map export ref to existing local UUID
* Insert episodes and link to memories
* Insert graph edges with remapped IDs
* Normalize legacy `superseded_by` to `SUPERSEDES`
* Insert or stage narrative nodes according to intent
* Detect target state (empty vs active) using `hexis_instance_is_empty()` covering all protected-section audit types
* For empty target with protected sections AND `export_intent` ∈ {port, duplicate}: insert directly (port-into-clean-target)
* For empty target with protected sections AND `export_intent` ∈ {telepathy, analysis}: refuse with `bootstrap_state_violation`; route through deliberative or analysis-only handling
* For active target with protected sections: refuse with `bootstrap_state_violation`; recommend MVP-PR
* Tag bootstrap-installed entries with `metadata.replaceable_during_bootstrap = true`
* Append provenance chain to every imported memory
* Validate `modification_kind` values; default unknown kinds to material
* Classify and report conflicts
* Mark all affected neighborhoods stale for recomputation

#### Slice 3: CLI commands, dry-run reporting, and intent policy

**Files:**

* `apps/cli_exchange.py` — `hexis export` and `hexis import` commands
* `apps/hexis_cli.py` — dispatch integration

**`hexis export`:**

```bash
hexis export --intent port|duplicate|telepathy|analysis
             [--output FILE]
             [--types TYPE,...]
             [--since DATE]
             [--until DATE]
             [--include-protected identity,worldview,narrative,drives,emotional-triggers]
             [--include-raw]
             [--include-config]
             [--include-in-flight-work]
             [--include-audit-records]
             [--redaction none|basic|strict|custom]
             [--format json|jsonl]
```

**`hexis import` (MVP-Core subset):**

```bash
hexis import FILE [--strategy additive|deliberative|analysis-only]
             [--dry-run]
             [--confirm-intent port|duplicate|telepathy|analysis]
             [--skip-identity]
             [--skip-worldview]
             [--skip-narrative]
```

`--dry-run` parses, validates, computes import counts, predicts duplicate-content conflicts, reports unsupported sections, reports protected-section policy decisions, reports target-state (empty/active), estimates embedding work, and reports privacy warnings without inserting.

MVP-Core does NOT include `--strategy authoritative`, `--replace`, or `--force-replace`. Those arrive with MVP-PR.

#### Slice 4: Deliberative and analysis-only strategies

**Files:**

* `core/memory_exchange.py` — deliberative staging, analysis-only loading, and analysis-to-staged promotion
* `db/37_import_staging.sql` — dedicated import staging tables and review functions
* `db/38_analysis_storage.sql` — read-only analysis storage tables, strictly isolated from active recall

**Deliberative:**

* Records inserted into `import_staging`
* Conflicts attached to staged records
* `hmx_pending_review()` returns staged records grouped by conflict type
* Agent tools: `accept_import(id)`, `reject_import(id)`, `modify_import(id, changes)`, `quote_import(id)`
* Heartbeat integration: if pending imports exist, include review as a possible heartbeat action

**Analysis-only:**

* Load into physically separate `hmx_analysis_*` tables
* Recall queries explicitly exclude analysis tables by default predicate
* No active memory mutation
* No heartbeat effects
* No participation in neighborhood, drive, emotion, or activation systems
* `promote_to_staged(analysis_id, rationale)` copies a record into deliberative staging (without analysis embedding)
* `demote_to_analysis(staged_id)` returns a staged record to analysis-only state

#### Slice 5: Agent tool handlers (MVP-Core)

**Files:**

* `core/tools/memory_exchange.py` — ToolHandler implementations

**Tools:**

* `export_memories` — export HMX to file path or return JSON/JSONL
* `import_memories` — import from file path with strategy and intent confirmation (MVP-Core strategies only)
* `import_dry_run` — validate and summarize import without mutation
* `import_review` — list pending deliberative imports
* `import_accept` — accept pending import
* `import_reject` — reject pending import
* `import_modify` — modify pending import before acceptance (records modification_kind)
* `import_quote` — preserve imported material as foreign quoted context without accepting it as local memory
* `promote_to_staged` — copy analysis record into deliberative staging
* `demote_to_analysis` — return staged record to analysis-only state

#### Slice 6: Re-embedding pipeline integration

Imported memories enter the embedding pipeline only after they are admitted into active or accepted memory.

**Behavior:**

* Accepted imported memories already have sentinel zero-vector embeddings (inserted during Slice 2)
* On acceptance, the maintenance worker detects `metadata->>'embedding_status' = 'pending_import'` and replaces the sentinel with a real embedding computed from `content`
* Staged and analysis-only records are not embedded into the main index
* Analysis-only embeddings, if generated, live in a separate index and are not queried by recall
* `promote_to_staged` does not copy analysis embeddings; staged record is embedded fresh from main index if accepted
* `hmx_queue_reembed(memory_ids)` marks accepted imported memories for re-embedding
* Maintenance worker processes pending imported memories
* Neighborhoods and clusters are recomputed after embedding
* Raw units, when included for port/duplicate, are written to `subconscious_units` with `source_identity = 'import:{export_id}:...'` and routed normally

#### Slice 7: In-flight work and interrupted consolidation

**Files:**

* `db/40_hmx_in_flight_work.sql` — export/import helpers for consolidation and reconsolidation tasks
* `services/worker_service.py` — safe requeue logic for imported pending work

**Behavior:**

* Export pending and in-progress tasks for port/duplicate
* Downgrade in-progress tasks to pending on import
* Drop tasks whose inputs were not imported
* Preserve failed tasks as diagnostics unless retry is explicitly requested
* Never export worker locks or runtime execution state

### MVP-Protected Replacement: Phase 2

#### Slice 8: `protected_section_digest_v1` and fixture suite

This slice is foundational. The digest is the linchpin of the entire safety model — fast-path verification, divergence detection, and audit dedupe all depend on it producing the same result for semantically identical state regardless of which instance computes it. Implementing and rigorously testing the digest is a prerequisite for Slices 9–12.

**Files:**

* `core/digest.py` — full `protected_section_digest_v1` and `audit_record_digest_v1` with per-section sort-key fallback hierarchy and exclusion rules
* `tests/fixtures/digest/` — fixture suite

**Required fixtures (acceptance gate for this slice):**

* **JSON key order independence:** the same semantic protected section serialized with different key orderings produces the same digest
* **Export-scoped ref / remap independence:** records with different `ref` prefixes (different export_ids) and different local UUIDs produce the same digest when content is semantically identical
* **Transport-field exclusion:** records differing only in `access_count`, `last_accessed`, `created_at`, `updated_at`, `import_chain`, `modification_chain`, or `metadata.unrecognized_hmx_fields` produce the same digest
* **Float-rounding stability:** drive levels and confidence values produce the same digest across platforms with different floating-point representations (verified to 6 decimal places)
* **Set-like reordering:** sections whose records have no inherent order (e.g., worldview, emotional_triggers) produce the same digest regardless of input record order
* **Ordered-sequence preservation:** narrative chapters with chronological order produce different digests when their order changes
* **Unknown-field independence:** records with preserved-but-unknown fields under `metadata.unrecognized_hmx_fields` produce the same digest as records without them
* **True-semantic-change detection:** a one-word change in worldview content, a single-point drive level change beyond rounding precision, or an added/removed identity facet produces a different digest

`protected_section_digest_v1` SHOULD be treated as a cryptographic compatibility layer. Implementations across language ecosystems must produce byte-identical hash output for the same canonical input; a fixture suite shared across implementations is the only reliable way to verify this property.

#### Slice 9: Protected Section Replacement Protocol — core machinery and fast path

**Files:**

* `db/53_hmx_protected_replacement.sql` — `hmx_consent` table, `protected_replacement_audit` table, snapshot management, pending replacement queue
* `core/protected_replacement.py` — protocol state machine including Phase 0 fast path

**Behavior:**

* Phase 0 fast path: compute local digest using the verified Slice 8 implementation, compare with imported; on exact match with lineage match, attempt to write `protected_section_verified` audit record. If audit write succeeds, skip destructive write and return success. If audit write fails, fail closed: no state mutation, report `verified_audit_write_failure`.
* Determine `agent_acknowledgement_required` from lineage + digest comparison rules
* If required, enqueue replacement in `pending_replacements` table
* Surface pending replacements to agent during heartbeat
* Snapshot previous state before destructive write
* Schedule snapshot purge at `min(heartbeat_window, wall_clock_expires_at)`
* Write immutable self-contained audit record for every replacement, verification, and reversion
* Audit deduplication by stable `audit_id` and `audit_record_digest_v1` comparison
* Refuse replacement if importer does not advertise `protected_replacement_protocol_v1`

#### Slice 10: Authoritative strategy and replacement flags

**Files:**

* `db/54_hmx_authoritative_import.sql` — `hmx_import_authoritative(jsonb, replace_sections text[], ref_map jsonb)`
* `apps/cli_exchange.py` — `--strategy authoritative` and `--replace` flag handling

**Behavior:**

* `--strategy authoritative` requires `export_intent = port|duplicate`
* `--replace <section>` flags trigger the protocol for the named section(s)
* MVP-PR supports `replacement_scope.mode = "whole_section"` only
* Drives copied only for port/duplicate lineage-preserving operations
* Provenance is preserved and extended
* Phase 0 verification fires before any destructive write

#### Slice 11: Reversibility window and rollback

**Files:**

* `db/55_hmx_reversion.sql` — snapshot reference maps, open-window query, and consumed-snapshot lifecycle
* `core/protected_replacement.py` — `revert_protected_replacement` implementation
* `core/tools/memory_exchange.py` — skill-gated list and explicit reversion tools

**Behavior:**

* Snapshot stored with reference in audit record
* Window measured as `min(heartbeats_remaining, wall_clock_expires_at)` (earlier-of)
* Default: 7 heartbeats, 30-day wall-clock cap
* `revert_protected_replacement(audit_id, rationale)` restores prior state and creates a reversion audit record
* Reversion refuses if the protected section changed after the replacement; it never overwrites newer state
* Snapshot reference maps restore protected reference topology to surviving local records
* Restore, immutable audit, target/collateral digest verification, and snapshot consumption are atomic
* After either limit closes, the snapshot payload is purged; successful reversion purges the consumed payload immediately and retains its tombstone
* Both windows operate independently; either closing closes the rollback

#### Slice 12: Operator override and trust anchor enforcement

**Files:**

* `apps/cli_exchange.py` — `--force-replace` flag with signature and verbatim phrase
* `core/protected_replacement.py` — override validation logic
* `core/trust_anchors.py` — verification interface used by override path

**Behavior:**

* `--force-replace` requires:
  - `--operator-signature SIG` (verified against configured trust anchor)
  - `--override-reason-code` from enumerated set
  - `--override-evidence-ref` pointing to evidence
  - `--rationale` free-text
  - Verbatim acknowledgement phrase entered
* Unverified signatures are treated as absent; override fails with `unverified_signature` warning
* Override creates audit record with `agent_acknowledgement = "bypassed"`, populated override fields
* Override does NOT reduce reversibility window
* CLI surfaces override invocation prominently in audit and logs

#### Slice 13: Agent tools for replacement protocol

**Files:**

* `core/tools/protected_replacement.py` — protocol handlers

**Tools:**

* `acknowledge_replacement(id, decision, modifications)` — accept/refuse/modify/defer a pending protected-section replacement
* `revert_protected_replacement(audit_id, rationale)` — roll back within reversibility window
* `list_pending_replacements()` — show open replacement requests
* `list_replacement_audit(since, until)` — show historical replacement records (including verified and reverted events)
* `list_pending_reversions()` — show audit records with open reversibility windows

## Security and Operational Notes

* HMX files should be treated as sensitive data.
* CLI should warn before exporting raw units.
* CLI should warn before exporting protected sections for telepathy or analysis.
* CLI should warn before importing HMX whose `privacy.contains_sensitive_content = true` from an untrusted source.
* CLI MUST surface Protected Section Replacement Protocol activity prominently.
* CLI MUST warn when signatures or lineage IDs cannot be verified against configured trust anchors.
* Optional encryption at rest should be supported post-MVP using GPG or age.
* Import should run in a single transaction where feasible. Protected Section Replacement Protocol may legitimately span heartbeats; in that case, replacement work is staged but not committed until acknowledgement resolves.
* Dry-run should be safe and side-effect free, including for protected-section replacement (dry-run reports protocol decisions but creates no consent records).
* Import logs should avoid printing full sensitive memory content unless verbose mode is explicitly enabled.
* Protected-section imports, verifications, and reversions must be auditable through their immutable audit records.
* Snapshots used for reversibility windows are local-only and never exported.
* Analysis-only storage MUST be physically separable; recall queries MUST exclude analysis storage by default predicate, not by convention.
* Trust anchor configuration MUST be deployment-explicit; "no trust anchor configured" is a valid local-development state but MUST be loudly visible and MUST prevent override-style operations.
* Phase 0 fast-path operations MUST NOT report success unless their verified audit record is durably written; the safety guarantee depends on the audit trail being complete.

## Future Considerations

* **Unified cognitive event log.** The system currently maintains parallel audit trails: `consent_log`, `change_history` on beliefs, `modification_chain` on imports, `import_chain` in provenance, transformation gating records, and the protected-replacement audit. A canonical `cognitive_events` table — single `event_id`, `event_type`, `event_time`, `affected_entity`, `agent_state_snapshot`, kind-specific payload, `preceded_by` — that all of these emit into would substantially simplify external audit, agent introspection, and HMX export of historical record.
* **Explicit branching: `hexis_branch_id` and `lineage_epoch`.** Track duplicate-produced branches at the metadata level rather than relying on digest divergence to detect them implicitly.
* **Partial-section replacement** (`replacement_scope.mode = "subset"`) — replace only specific worldview categories, narrative threads, or goal subtrees.
* **Multi-step replacements** applied gradually over heartbeats rather than atomically.
* **Selective re-export** of imported memories while preserving provenance chain.
* **Cross-architecture interop** with non-Hexis systems.
* **Optional encrypted HMX bundles** (GPG, age).
* **HTTP push/pull** between instances.
* **Differential and incremental backup.**
* **Redaction plugins** for user-specific privacy policies.
* **Signed exports** for provenance authenticity (depends on chosen trust anchor model).
* **Import trust scores** based on source identity, signature verification, lineage match, and prior history.
* **Temporary analysis embeddings** for read-only inspection (isolated index).

## MVP-Core Acceptance Criteria

MVP-Core is complete when:

0. Slice 0 schema migrations are applied: `memory_status` enum includes `'staged'`, `graph_edge_type` enum includes `SUPERSEDES`/`CONTAINS`/`HAS_BELIEF`/`MEMBER_OF`, `SUPERSEDES` edge label exists in AGE, `agent.lineage_id` exists in config, provenance backfill is complete (bootstrap entries get `acquisition_mode = "bootstrap"`, others get `"experienced"`), and bootstrap entries are tagged with `replaceable_during_bootstrap`.
1. `hexis export` requires `--intent` and produces schema-valid HMX.
2. JSON and JSONL exports are both supported.
3. `telepathy` and `analysis` exclude protected sections by default.
4. `hexis import --dry-run` validates an HMX file and reports counts, warnings, protected-section policy decisions, target-state determination (empty/active), embedding estimates, and conflict codes.
5. Additive import can import memories, episodes, relationships, clusters, and allowed non-protected sections without duplicating content-hash matches.
6. Imported memories preserve acquisition mode and distinguish earned, staged, accepted, archived, derived-from-import, and analysis-only records.
7. Material modifications correctly trigger `derived_from_import`; non-material modifications preserve prior acquisition mode.
8. Accepted imported memories are re-embedded by the worker and become recallable.
9. Staged and analysis-only records do not enter active memory or main embedding queues.
10. Analysis-only storage is physically/logically isolated; recall queries cannot reach it.
11. `promote_to_staged` copies content and provenance but not analysis embeddings.
12. Provenance chains and modification chains survive export → import → modification → re-export.
13. Unknown minor-version fields and unsupported sections do not break import.
14. Supersession is canonicalized as `SUPERSEDES` edges.
15. Narrative scaffolding is exported for port/duplicate and can be preserved or staged according to intent.
16. Deliberative import uses `import_staging` or `status='staged'`, not overloaded `archived` state.
17. Port/duplicate exports account for in-flight consolidation and reconsolidation work.
18. Port/duplicate exports include audit records; importers preserve them as immutable history.
19. `promote_to_staged` and `demote_to_analysis` move records between analysis and staging without bypassing deliberative review.
20. Audit records are deduplicated by stable `audit_id` and compared via `audit_record_digest_v1`; content divergence raises `audit_integrity_conflict`.
21. Direct protected-section import is accepted into an empty target ONLY when `export_intent` is `port` or `duplicate`; other intents are routed through deliberative or analysis-only handling regardless of target state.
22. Direct protected-section import into an active target raises `bootstrap_state_violation` and recommends MVP-PR.
23. `hexis_instance_is_empty()` returns accurate determinations covering all protected-section audit types (replacement, verified, reversion) and provides diagnostic information.

## MVP-Protected Replacement Acceptance Criteria

MVP-PR is complete when:

1. `protected_section_digest_v1` is implemented for all protected section types with documented canonicalization rules AND exclusion rules AND the full fixture suite passes (key-order, ref/remap, transport exclusion, float rounding, set reordering, ordered preservation, unknown-field, semantic-change).
2. `audit_record_digest_v1` is implemented with transport-local field exclusions and used for audit dedupe comparison.
3. Trust anchor interface is implemented; unverified signatures are treated as absent across all protocol operations.
4. JSON Schema models audit records as a discriminated union on `event_type` and rejects records missing event-type-specific required fields.
5. Authoritative replacement of identity/worldview/narrative/goals/drives/emotional triggers requires explicit replacement flags AND successful completion of the Protected Section Replacement Protocol.
6. Phase 0 fast-path verification: content-identical replacements skip destructive writes and emit `protected_section_verified` audit records; full protocol fires only when digests differ.
7. Phase 0 fails closed if the verified audit record cannot be written; no state is mutated and `verified_audit_write_failure` is reported.
8. Phase 1: consent records are written to `hmx_consent` (not the existing LLM-usage `consent_log`) with full source, scope, and rationale before any replacement is committed.
9. Phase 2: agent acknowledgement is solicited where required; agent may accept, refuse, modify, or defer; refusal cancels operation; timeout cancels operation.
10. Phase 2: agent refusal is recorded and cannot be bypassed by retry or by operator override claiming the agent is "broken."
11. Phase 3: immutable self-contained audit records are written for every replacement, verification, and reversion, with embedded consent payload, replacement scope, and digest pair.
12. Phase 3: audit records survive export-import round trip on port/duplicate; deduplication is by `audit_id` only, comparison by canonicalized digest with transport-local fields excluded.
13. Phase 4: reversibility window is the earlier of `heartbeat_window` and `wall_clock_expires_at` (defaults: 7 heartbeats, 30 days).
14. Phase 4: `revert_protected_replacement` restores prior state within window and creates a reversion audit record matching the documented schema.
15. Phase 4: after window closes, snapshot is purged; revert returns a clear "window expired" error.
16. Operator override (`--force-replace`) requires verified signature, verbatim phrase, reason code from enumerated set, and evidence reference.
17. Operator override refuses if reason is "agent refused" or equivalent.
18. Operator override produces audit record with `agent_acknowledgement = "bypassed"` and populated override fields.
19. Replacement scope is `whole_section` only for MVP-PR; `subset` mode is parseable but refused with recommendation to use `whole_section` or deliberative import.
20. `lineage_integrity_failure` is detectable as distinct from ordinary `protected_section_digest_mismatch`; only the former requires operator override path.
21. Verified audit records produced by Phase 0 fast path are exported with port/duplicate and preserved on import as historical record alongside replacement audits.
