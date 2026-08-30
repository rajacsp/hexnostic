# HMX MVP Acceptance

Audit date: 2026-07-10

Specification: `plans/hmx.md`, HMX 1.7

Result: **complete**. Every MVP-Core and MVP-Protected Replacement acceptance
criterion has an implementation owner and executable evidence. This audit found
and closed four gaps: non-material edits were classified as derived, unknown
future sections were discarded without a warning, protected-history target
diagnostics were not event-specific, and an invalid lineage proof could still
enter the ordinary agent-acceptance path.

Validation: 2157 repository tests pass. The existing 421 pytest marker warnings
and focused `core/memory_exchange.py` mypy baseline remain advisory; formatting,
compilation, migration survivability, wheel contents, and diff hygiene pass.

## MVP-Core

| ID | Acceptance proof | Implementation and executable evidence |
|---:|---|---|
| 0 | Schema prerequisites and provenance backfill are live. | `db/migrations/0001_*` through `0003_*`; `tests/db/test_hmx_slice0.py`; `tests/db/test_migrations.py` |
| 1 | Export requires an explicit intent and validates its output. | `apps/hexis_cli.py`; `core/memory_exchange.py::export_hmx`; `tests/cli/test_hmx_cli.py::test_export_jsonl_and_database_aware_dry_run` |
| 2 | JSON and JSONL transports round-trip. | `core/hmx_files.py`; `core/memory_exchange.py::iter_hmx_jsonl`; `tests/db/test_hmx_export.py::test_jsonl_round_trip_shape` |
| 3 | Telepathy and analysis omit protected state by default. | `core/memory_exchange.py::resolve_export_sections`; `tests/core/test_hmx_exchange.py::TestIntentPolicy` |
| 4 | Dry-run reports validation, counts, policy, target state, embeddings, warnings, and conflicts without mutation. | `core/memory_exchange.py::dry_run_hmx`; `tests/cli/test_hmx_cli.py::test_export_jsonl_and_database_aware_dry_run`; `tests/db/test_hmx_import.py::TestDryRun` |
| 5 | Additive import handles memories, episodes, edges, clusters, and dedupe. | `tests/db/test_hmx_import.py::test_imports_and_remaps_memory_episode_cluster_and_edges`; `test_duplicate_content_maps_to_existing_memory` |
| 6 | All acquisition modes remain distinguishable. | `tests/db/test_hmx_slice0.py`; `tests/db/test_hmx_staging.py`; `tests/db/test_hmx_import.py`; schema `provenance.acquisition_mode` enum |
| 7 | Material edits become derived; non-material edits preserve accepted mode. | `core/memory_exchange.py::_modification_is_material`; `tests/db/test_hmx_staging.py::test_material_modify_then_accept_becomes_derived`; `test_non_material_modify_preserves_mode_and_reexports_chain` |
| 8 | Accepted imports are freshly embedded, refreshed, and recallable. | `db/51_hmx_reembedding.sql`; `tests/db/test_hmx_reembedding.py::test_accepted_import_is_embedded_and_refreshes_derivatives` |
| 9 | Staged and analysis records never enter active/main embedding queues. | `tests/db/test_hmx_reembedding.py::test_staged_analysis_and_ordinary_memories_never_enter_hmx_queue` |
| 10 | Analysis storage is physically separate and unreachable by active recall. | `db/50_hmx_analysis_storage.sql`; `tests/db/test_hmx_staging.py::test_analysis_only_is_physically_isolated_and_not_pending_review` |
| 11 | Promotion copies content/provenance, not embeddings. | `db/50_hmx_analysis_storage.sql::hmx_promote_to_staged`; `tests/db/test_hmx_staging.py::test_promote_copies_and_demote_preserves_both_histories` |
| 12 | Import and modification chains survive a re-export. | `tests/db/test_hmx_staging.py::test_non_material_modify_preserves_mode_and_reexports_chain`; protected round trip in `tests/db/test_hmx_import.py::test_empty_target_port_round_trips_all_protected_shapes` |
| 13 | Unknown minor fields/sections are tolerated and unsupported content is reported. | `tests/core/test_hmx_exchange.py::test_unknown_fields_and_sections_are_forward_compatible`; `tests/db/test_hmx_import.py::test_unknown_minor_fields_and_sections_remain_forward_compatible` |
| 14 | Supersession is exported and imported as `SUPERSEDES`. | `tests/db/test_hmx_export.py::test_port_export_wire_contract`; `tests/db/test_hmx_import.py::test_imports_and_remaps_memory_episode_cluster_and_edges` |
| 15 | Narrative scaffolding is portable and can enter deliberative staging. | `tests/db/test_hmx_export.py::test_port_export_wire_contract`; `tests/db/test_hmx_import.py::test_empty_target_port_round_trips_all_protected_shapes`; `tests/db/test_hmx_staging.py::test_narrative_is_staged_as_one_reviewable_bundle` |
| 16 | Deliberative records use dedicated staging, never archived as a staging surrogate. | `db/49_hmx_import_staging.sql`; `tests/db/test_hmx_staging.py::test_deliberative_stages_without_active_mutation` |
| 17 | Port/duplicate carries resumable consolidation and reconsolidation intent. | `db/52_hmx_in_flight_work.sql`; `tests/db/test_hmx_in_flight_work.py` |
| 18 | Port/duplicate carries immutable audit history. | `core/protected_replacement.py::import_audit_records`; `tests/db/test_hmx_protected_replacement.py::test_audit_dedupe_round_trip_and_append_only_records` |
| 19 | Promote/demote transitions retain history and do not bypass review. | `db/50_hmx_analysis_storage.sql`; `tests/db/test_hmx_staging.py::test_promote_copies_and_demote_preserves_both_histories` |
| 20 | Audit dedupe uses `audit_id`; digest divergence fails loudly. | `core/digest.py::audit_record_digest_v1`; `tests/db/test_hmx_protected_replacement.py::test_audit_dedupe_round_trip_and_append_only_records` |
| 21 | Empty-target direct protected import is limited to port/duplicate. | `tests/db/test_hmx_import.py::test_empty_target_port_preserves_mode_and_adopts_lineage`; `test_telepathy_cannot_use_empty_target_protected_fast_path` |
| 22 | Active-target direct protected import fails with `bootstrap_state_violation` and names MVP-PR recovery. | `core/memory_exchange.py::dry_run_hmx`; `tests/db/test_hmx_import.py::test_reports_protected_policy_without_mutation` |
| 23 | Empty-target diagnostics cover replacement, verification, and reversion history with event-specific blockers. | `db/48_functions_memory_exchange.sql::hexis_instance_is_empty`; migration `0015_hmx_acceptance_diagnostics`; `tests/db/test_hmx_protected_replacement.py::test_empty_target_diagnostics_distinguish_all_protected_audit_types` |

## MVP-Protected Replacement

| ID | Acceptance proof | Implementation and executable evidence |
|---:|---|---|
| 1 | Canonical protected digests cover all six sections and every required relation. | `core/digest.py`; `tests/fixtures/digest/`; `tests/core/test_hmx_digest_fixtures.py` |
| 2 | Canonical audit digests exclude transport-local fields and drive dedupe. | `core/digest.py::audit_record_digest_v1`; fixture suite; audit round-trip test |
| 3 | Trust is deployment-pluggable and unverified claims never authorize protocol operations. | `core/trust_anchors.py`; `tests/core/test_hmx_trust_anchors.py`; `tests/db/test_hmx_protected_replacement.py::test_unverified_operator_signature_is_discarded_and_reported` |
| 4 | Audit schema is an event-discriminated union with event-specific requirements. | `schemas/hmx-1.7.schema.json`; `tests/core/test_hmx_exchange.py::test_audit_union_requires_event_specific_fields` |
| 5 | Authoritative replacement requires explicit sections and executes all six only through the protocol. | `core/protected_replacement.py::import_authoritative_hmx`; `tests/db/test_hmx_authoritative_import.py::test_authoritative_acceptance_and_reversion_verify_each_section`; authoritative dry-run test |
| 6 | Identical trusted content is an audited no-op; divergence enters the full protocol. | `tests/db/test_hmx_protected_replacement.py::test_phase_zero_is_audited_noop_without_consent_or_snapshot`; divergence test |
| 7 | Verified-audit failure fails closed before mutation. | `test_phase_zero_audit_failure_rolls_back_and_fails_closed` |
| 8 | Consent is durable and contains source, scope, and rationale before execution. | `db/53_hmx_protected_replacement.sql::hmx_consent`; consent assertions in `test_divergence_queues_once_and_refusal_cannot_be_bypassed_by_retry` |
| 9 | Accept, refuse, request-modification, defer, and timeout paths are durable and non-destructive until acceptance. | authoritative acceptance tests; refusal test; `test_acknowledgement_supports_defer_and_modification_request`; timeout test |
| 10 | Refusal is immutable for the request and cannot be retried or overridden. | `test_divergence_queues_once_and_refusal_cannot_be_bypassed_by_retry`; `tests/db/test_hmx_authoritative_import.py::test_operator_override_cannot_bypass_agent_refusal` |
| 11 | Replacement, verification, and reversion write self-contained immutable audits. | `db/53_hmx_protected_replacement.sql`; authoritative replacement/reversion journey tests; Phase 0 test |
| 12 | Audit history survives port/duplicate round trips with stable-ID dedupe and canonical comparison. | `test_audit_dedupe_round_trip_and_append_only_records` |
| 13 | Reversion closes on the earlier heartbeat or wall-clock limit, defaulting to 7/30 days. | `db/55_hmx_reversion.sql`; `test_snapshot_window_closes_on_earlier_heartbeat_limit`; wall-clock counterpart |
| 14 | Explicit in-window reversion restores prior state and emits a schema-valid audit. | `core/protected_replacement.py::revert_protected_replacement`; authoritative all-section reversion test |
| 15 | Expiry purges snapshot payload and returns an actionable window-expired error. | `test_reversion_window_expiry_purges_payload_and_blocks_restore`; protected snapshot expiry tests |
| 16 | Override requires an exact phrase, enumerated reason, evidence reference, and verified Ed25519 signature. | `core/trust_anchors.py::Ed25519TrustAnchors`; `core/protected_replacement.py::_authorize_operator_override`; operator and CLI tests |
| 17 | Agent refusal cannot be described as failure or bypassed by override. | `test_operator_override_cannot_bypass_agent_refusal`; override reason enum excludes refusal equivalents |
| 18 | Override audits record bypass acknowledgement and all authorization evidence. | `test_verified_operator_override_executes_atomically_and_is_reversible` |
| 19 | Subset scope parses but fails with whole-section/deliberative recovery guidance. | `core/protected_replacement.py::_validate_request`; `test_subset_scope_is_parseable_but_refused_with_recovery_path` |
| 20 | Invalid lineage proof is distinct from digest mismatch and only it blocks normal agent acceptance in favor of override. | `core/protected_replacement.py::evaluate_protected_replacement`; `acknowledge_protected_replacement`; migration `0015`; `test_lineage_integrity_failure_requires_operator_override`; ordinary divergence test |
| 21 | Verified Phase 0 history exports and imports beside replacement history. | Phase 0 export assertions; `test_audit_dedupe_round_trip_and_append_only_records` |

## Experience-Bar Journey

The end-to-end operator and agent journeys are covered separately from the
criterion-level tests:

- CLI: export -> dry-run -> explicit intent confirmation -> import, including
  signed operator override and explicit reversion (`tests/cli/test_hmx_cli.py`).
- Agent: skill discovery -> private file workflow -> deliberative review, plus
  pending -> inspect -> defer -> accept -> audit -> revert -> audit
  (`tests/core/test_hmx_tools.py`).
- Worker: accepted import -> bounded re-embedding -> derivative refresh ->
  recall eligibility (`tests/db/test_hmx_reembedding.py` and
  `tests/services/test_hmx_reembedding.py`).
