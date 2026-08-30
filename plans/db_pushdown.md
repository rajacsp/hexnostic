# DB Pushdown Plan — move Python business logic into Postgres

**This is the authoritative continuation of `plans/python-to-postgres.md`**
(slices 0–6, complete: runtime tables, prompt store, chat/channel/agent-loop
lifecycle, RecMem/subconscious application, tool catalog/policy/workflow/
scheduling, and DB-native tool dispatchers). The tranches below are
effectively its Slice 7+, derived from a fresh whole-codebase audit. The
Slice 0 inventory (`plans/python-to-postgres-inventory.md`) is superseded by
this document.

**Goal:** Python should be event triggers, loops, and I/O only (LLM/HTTP calls, file
parsing, transport, CLI/UI). Everything else — selection, scoring, thresholds, state
transitions, JSON shaping, multi-query read-modify-write — lives in `db/*.sql`.

**Source:** 7-way parallel audit of core/, services/, apps/, channels/, core/tools/
(~60k lines of Python) cross-referenced against all 56 `db/*.sql` files (2026-07-16,
at the tree that became `e42426e` — line references include the active-persona/
appraisal work; the digest-standard commit `df021d6` added `db/57`, so new SQL
files start at `db/58`).

## Progress metric

`scripts/db_brain_audit.py` (built by the prior plan's Slice 0) is the
measurable definition of done. Baseline at `df021d6` (2026-07-16):

```
python scripts/db_brain_audit.py --json   # 579 findings
  direct_domain_sql: 151
  policy_state_machine: 150
  workflow_or_schedule_logic: 123
  config_branching: 92
  prompt_assembly: 63
```

Every tranche's completion notes MUST state the new counts. Per the prior
plan's convention, once an area is migrated its audit rule is promoted from
advisory to blocking (a test that fails if Python reintroduces moved domain
logic), so the count can only go down.

## Conventions carried forward from `plans/python-to-postgres.md`

- **Parity tests before each move**: compare old Python output to the new SQL
  output on representative fixtures, then delete the Python (parity tests
  become golden-output tests against SQL).
- **Wrapper tests prove delegation**: remaining Python entrypoints must be
  shown to call SQL rather than re-implement it.
- **Each item independently shippable**: migration `db/migrations/NNNN_*.sql`
  + baseline mirror + tests + hosted CI green per item or small group.
- **Public Python entrypoints stay stable**; they become thin wrappers.
- **Tool-thinning priority order**: memory/goals/backlog/contacts/schedule →
  email/calendar ingestion → channel/messaging → web/search/browser →
  filesystem/shell/code-execution policy.

**Headline:** the architecture is already mostly right — the agent loop, heartbeat,
channel turns, tool policy, and prompt rendering all have SQL owners. The debt is
concentrated in four buckets:

1. **Live duplicates**: Python re-implementations of SQL functions that already exist
   (some with real drift).
2. **Python sagas**: multi-query read-modify-write sequences that should be one atomic
   SQL function.
3. **Bypasses**: raw inline SQL that skips existing functions (and their trust/
   provenance/graph side-effects).
4. **Policy data in code**: prompts, price tables, thresholds, and pattern tables
   hardcoded in Python instead of seeded in the DB.

Estimated total: ~2,000+ lines of Python business logic eliminated, ~30 new/extended
SQL functions, and removal of every known Python/SQL drift hazard.

---

## Tranche 1 — Delete duplicates of SQL that already exists (no new SQL)

Highest value per unit effort; every item below is drift risk today.

> **Progress (2026-07-16, commits `484dfda` + `7ee6ab1`): audit 579 → 559.**
> Done: 1.1 (heartbeat prompt fork deleted; golden fixtures in
> `tests/fixtures/prompt_render/` pin the SQL output), 1.2 (dead channel
> helpers deleted; tests exercise prepare/finalize_channel_turn and
> flush_channel_history_to_memory directly), 1.3 (`render_subconscious_signals`
> is the only renderer; Python formatter deleted), 1.5 (croniter fallback
> deleted; delegation + live-DB tests). 1b done: `touch_contact` ×5, backlog
> `record_backlog_user_change`, fathom `create_episodic_memory`, and migration
> `0025` (finalize_agentic_heartbeat releases the active claim itself;
> `release_active_heartbeat()` for error paths).
> Corrections found during execution: the four "raw recall projections" were
> already thin SQL-function wrappers (no change needed; only
> `get_ingestion_receipts` remains raw — single read, Tranche 3.12 material).
> The `capability_maturity.py` worldview insert stays by design: the
> rollback-only alive-demo must not depend on the embedding service. The
> workflow `_update_workflow_record` swap moved to Tranche-D scope: the Python
> execution loop never records `workflow_step_runs`, so
> `finalize_workflow_execution` would derive empty results — the loop must
> adopt `apply_workflow_step_result` first. The agent pause/resume raw
> UPDATEs fold into 2.1 `apply_agent_config`. 1.4 done (migration `0026`):
> `render_chat_memory_context` gained the recall-hedge/felt-emotion-cue
> prefixes (config thresholds) and the knowledge-subgraph section, the chat
> paths render via `render_chat_memory_context_db`, and the Python renderer
> plus its hardcoded thresholds are deleted — a ~2,600-token-per-turn prompt
> block is now DB-owned and pinned by `chatctx_*` goldens. (The deleted
> renderer's f-strings were not among the audit rules' patterns, so the count
> holds at 559 — the metric tracks its rule set, not every deletion.)
> 1.6 is done for four of five handlers (migration `0027`): backlog, goals,
> contacts, and memory recall/remember/sense are DB-dispatch-only. Closing the
> gaps moved real policy into SQL — `execute_memory_tool` now owns the
> hybrid-vs-structured retrieval decision, labels rows with
> `retrieval_source`, and flattens `source_attribution` into `source_*` keys;
> malformed uuid args return `invalid_params`. Validation tests run against
> the real dispatcher.
> **cron is done** (migration `0028`): the SQL cron "math" was a
> `now + 1 minute` placeholder — a real defect that made DB-native cron tasks
> degrade to every-minute firing after their first run. `cron_next_fire`
> (db/19) now evaluates 5-field cron expressions with Vixie semantics
> (ranges/steps/lists/names, dom-OR-dow rule, 0/7=Sunday, timezone-aware,
> minute resolution; 6-field drops the seconds field) and doubles as the
> validator; `parse_schedule_input` validates cron at creation with a real
> `_next_run`; `recompute_cron_next_runs` uses the task's timezone;
> `manage_schedule_tool` reached fallback parity (curated list/stats shapes,
> outbox-delivery hiding, `recent_runs`, update delivery validation).
> cron.py went 810 → 209 lines (croniter helpers + fallback deleted); its
> tests now pin the SQL semantics directly, including a nine-case
> next-fire table.
> 1.7 done: `compose_personhood_prompt` (the runtime composer duplicating
> db/39 `compose_personhood`) is deleted; composition is DB-only, pinned by
> `personhood_*` goldens. `parse_personhood_modules` stays as build-time
> tooling — `scripts/gen_prompt_seed.py` uses it to seed the DB modules from
> `services/prompts/personhood.md`, which remains the authoring source.
>
> **TRANCHE 1 COMPLETE.** Audit: 579 → 500 (policy_state_machine 150→140,
> direct_domain_sql 151→130, workflow_or_schedule_logic 123→79,
> config_branching 92→89, prompt_assembly 63→62). Carried forward:
> workflow-loop adoption of `apply_workflow_step_result` +
> `finalize_workflow_execution` (from the 1.6 discovery note above).

| # | Python | SQL twin (exists) | Notes | Effort |
|---|--------|-------------------|-------|--------|
| 1.1 | `services/heartbeat_prompt.py:20-440` — `build_heartbeat_decision_prompt` + ~20 `_format_*` | `render_heartbeat_decision_prompt` + `render_*` family (db/39) | Self-admitted byte-parity fork; production already uses `render_heartbeat_decision_prompt_db`. Only `tests/db/test_prompt_render.py` uses the Python fork. Delete; keep golden-fixture parity tests against the SQL output. | S |
| 1.2 | `channels/conversation.py:89-368` — `_check_channel_energy`, `_get_or_create_session`, `_flush_trimmed_to_memory`, `_update_session`, `_log_message` | `prepare_channel_turn`, `finalize_channel_turn`, `flush_channel_history_to_memory`, `estimate_conversation_importance` (db/34) | Dead code — production paths (`process_channel_message`/`stream_channel_message`) already call the SQL. Only tests reach the helpers. Delete + repoint tests. | S |
| 1.3 | `services/agent.py:176-211` — `format_subconscious_signals` | `render_subconscious_signals` (db/39) | Byte-parity asserted in `tests/db/test_prompt_render.py:202`. Swap both call sites (agent.py:751, 948), drop the Python. | S |
| 1.4 | `core/cognitive_memory_api.py:1669-1820` — `format_context_for_prompt` + `_recall_hedge`/`_emotion_cue` (hardcoded 0.35/0.4 thresholds) | `render_chat_memory_context` (db/39:489) + config keys `memory.recall_low_vividness_threshold` / `memory.recall_emotion_cue_threshold` | **Drift found:** SQL `_pr_mem_line` doesn't emit the hedge/emotion-cue prefixes, and the live path (`services/agent.py:649,889`) still calls Python. Finish the SQL renderer, switch call sites, delete Python + its hardcoded thresholds. | M |
| 1.5 | `core/state.py:78-124` — cron next-run Python fallback (croniter+pytz loop, per-row UPDATEs) | `recompute_cron_next_runs` (db/36), `compute_next_run_at` (db/19) | Fallback exists for pre-migration schemas; migrations now guarantee the function. Delete. | S |
| 1.6 | Tool "compatibility path" fallbacks: `core/tools/backlog.py:153-550`, `cron.py:307-805`, `memory.py:159-261,496-530` (recall/remember), `goals.py:141-255`, `contacts.py` CRUD fallbacks | `execute_backlog_tool`, `manage_schedule_tool`, `execute_memory_tool`, `execute_goals_tool`, `execute_contact_tool` (db/36, db/38) | Each handler calls the DB dispatcher first, then carries a full second Python implementation. **Verify dispatcher covers every action first** (fallbacks may mask gaps — e.g. cron `_stats` may need a new `scheduled_task_stats()`), then delete. | S–M |
| 1.7 | `services/prompt_resources.py:60-97,305-328` — personhood markdown parse + kind→modules composition | `compose_personhood` (db/39) + seeds (db/40) | Two sources of truth for identity scaffolding. Consolidate on DB; keep `_COMPACT_PERSONHOOD` perf shortcut. | M |

### 1b — Swap raw inline SQL for existing functions (bypasses)

| Site | Should call |
|------|-------------|
| `core/tools/fathom.py:262,281`, `core/tools/contacts.py:466,554`, `core/tools/email.py:1000` — raw `UPDATE contacts SET last_touch` ×5 | `touch_contact()` |
| `core/tools/backlog.py:531`, `core/tools/fathom.py:231`, `core/capability_maturity.py:121` — raw `INSERT INTO memories` (skips trust/provenance/graph side-effects) | `create_episodic_memory()` / `create_worldview_memory()`; backlog case is literally `record_backlog_user_change()` |
| `core/agent_api.py:348-356` — raw pause/unpause UPDATEs | `pause_heartbeat()`; add small `resume_heartbeat()` companion |
| `apps/hexis_api.py:676`, `services/heartbeat_agentic.py:342` — raw clear-active-heartbeat UPDATEs | `finalize_agentic_heartbeat()` |
| `core/cognitive_memory_api.py:500,535,573,983` — raw projections for recall_by_id / recall_cluster / recall_episode / spontaneous | `get_memory_by_id()`, `get_cluster_sample_memories()`, `get_episode_memories()`, `get_spontaneous_memories()` |
| `core/tools/workflow.py:569-619` — inline `UPDATE workflow_executions` | `finalize_workflow_execution()` |
| `core/cognitive_memory_api.py:1233-1286` — `_create_memory` 4-way type dispatch | `create_memory()` dispatcher (db/05:914; needs per-type params/metadata extension) |

---

## Tranche 2 — Small new SQL functions, big atomicity wins

| # | New SQL | Replaces | Effort |
|---|---------|----------|--------|
| 2.1 | `apply_agent_config(p_config jsonb)` | `core/agent_api.py:254-360` — ~18 sequential `set_config` calls + pause toggles inside a Python txn (~107 lines) | M |
| 2.2 | `get_agent_status() RETURNS jsonb` | `core/agent_api.py:92-109` — 4 round-trips + Python AND-policy for "configured" | S |
| 2.3 | `upsert_contact(name,email,source)` + `upsert_contacts_from_attendees(jsonb)` + `enrich_attendees_with_crm(jsonb)` | The worst N+1 in the codebase: contact upsert loop duplicated ×5 (`contacts.py:417-483,512-571`, `email.py:928-1013`, `fathom.py:246-290`, `calendar.py:636-680`) | M |
| 2.4 | ~~`hmx_content_hash_v1(text)` / `hmx_normalize_v1(text)`~~ **SHIPPED** in `db/57_functions_hmx_digest.sql` + migration `0024` (byte-parity proven by `tests/db/test_hmx_digest_sql.py`). **Remaining:** adopt at the 2 inline-normalization sites in `db/48` (`_transient_normalized_content` import/trigger dedup) and the Python dry-run dedup query. `core/digest.py` stays as the portable reference implementation. | S |
| 2.5 | `spend_energy(p_cost float)` (conditional debit) + `mark_user_contact()` | Inline energy debit / last_user_contact UPDATEs (`channels/conversation.py`, `core/rabbitmq_bridge.py:141`) | S |
| 2.6 | `boost_memory_confidence(id, boost)`, `find_worldview_by_hint(text, threshold)`, `decay_rate_for_intensity(intensity, permanent)` (config-driven bands) | `services/ingest.py:1533-1548, 2331-2348, 215-222` magic numbers + inline UPDATEs; feeds Tranche 3.1 | S |
| 2.7 | `mood_label(valence, arousal)` | `core/cli_api.py:717-744` nested threshold ladder; co-locate with `update_mood()` (db/13) | S |
| 2.8 | `hmx_recompute_batch_status(batch_id)` + `hmx_reject_staged(id, rationale)` | Copy-pasted batch-status CASE block ×3 in `core/memory_exchange.py:2645,2675,2811`; reject is pure DB mutation | S |
| 2.9 | `hmx_source_context() RETURNS jsonb` | `core/memory_exchange.py:1063-1095` — 6+ queries to build the envelope source block | S |
| 2.10 | `record_tool_execution(...)` | `core/tools/hooks.py:323-326` inline INSERT | S |

---

## Tranche 3 — Consolidate Python sagas into atomic SQL orchestrators

| # | New SQL | Replaces | Effort / risk |
|---|---------|----------|---------------|
| 3.1 | `ingest_persist_extractions(p_source, p_encounter_id, p_appraisal, p_extractions jsonb, ...) RETURNS jsonb` | `services/ingest.py:2215-2329` `_create_semantic_memories` — post-LLM persistence loop (route → create/dedup → source-merge → confidence boost → concept links → worldview lookup → edges → decay), **no LLM anywhere in it**; a mid-loop failure currently leaves half-written state. Also shrinks the 3× copy-pasted FAST-mode call sites. | L / low |
| 3.2 | `slow_ingest_persist_facts(p_facts, p_assessment, p_source, p_encounter_id, p_worldview_ids)` | `slow_ingest_rlm.py:317-415` + duplicated `586-621` — per-fact create + 4 edge kinds; **kills the Python `0.92` dedup that drifts from config `memory.ingest_theta_dup`** (reuse `ingest_route_embedding`). Fold in `_TRUST_MULTIPLIERS` as config. | M–L / low |
| 3.3 | `hmx_import_additive(p_document jsonb, p_intent, p_reviewed, p_retry_failed_work, p_initial_ref_map)` | `core/memory_exchange.py:2334-2499` — 14-call SQL saga threaded through Python (ref_map accumulation, ordering). Pattern already proven by `hmx_import_authoritative` (db/54). Schema validation + digests stay Python. | L / med |
| 3.4 | Fold export row-shaping into SQL: add `p_export_id` to `hmx_export_*` or one `hmx_export_sections(p_export_id, p_sections, ...)` | `core/memory_exchange.py:652-776` `_postprocess_section` + `_enrich_provenance` — ref scoping, field renames, provenance defaults, content hashes (via 2.4); also collapses N export round-trips into one | M–L / med |
| 3.5 | `hmx_enrich_import_provenance(p_record, p_intent, ...)` | `core/memory_exchange.py:1158-1377` acquisition-mode state machine + import_chain/modification_chain bookkeeping | M / med |
| 3.6 | `build_inline_appraisal_context(p_user_message, p_memories jsonb, p_char_budget)` + `normalize_inline_appraisal(p_doc, p_allowed_memory_ids)` | `services/agent.py:335-415` (4 round-trips + JSON bounding pre-LLM) and `:76-173` (confidence thresholds, clamping, allow-list filtering post-LLM). LLM call stays Python in between. Preserve thresholds pinned by `tests/services/test_subconscious_appraisal.py`. | M / low |
| 3.7 | `heartbeat_agentic_plan(p_context jsonb) RETURNS jsonb` | `services/heartbeat_agentic.py:27-291` — 4 enrichment reads + energy×2/timeout/max_tokens/shell+file-write permission math + 2 prompt renderers. Security-relevant: SQL becomes the single authority on permission grants. | M / med |
| 3.8 | `hydrate_context(p_query, p_session, p_opts jsonb)` | `core/cognitive_memory_api.py:265-354` `hydrate()` — 4 queries + Python dedup/slicing/assembly. Note: loses cross-connection parallelism, gains one round-trip; measure latency. | L / med |
| 3.9 | Extend `recmem_recall_context` | `core/cognitive_memory_api.py:1338-1408` — derived-source filtering, dedup, and the separate `touch_memories` reinforce write become in-function | M / low |
| 3.10 | `get_status_overview()`, `validate_agent_config()`, `build_character_card(name)` | `core/cli_api.py:589-757` (8-query status assembly + regen math), `:113-215` (config policy engine; env-var checks stay Python), `apps/hexis_cli.py:1638-1770` (6-query character-card export) | M each |
| 3.11 | `capability_maturity_scorecard() RETURNS jsonb` | `core/capability_maturity.py:347-521` — ~175 lines of threshold ladders + evidence strings over one fetched row | L / low |
| 3.12 | Read-shapers for tools: `aggregate_signals(domain,days,limit)`, `query_usage(period,view,source)`, `explore_concept(...)`, `explore_subgraph(...)`, `fast_recall_by_type(...)`, `scheduled_task_stats()`, `ingest_status_summary()` + `ingest_pending_list()` | `council.py:480-671`, `usage_query.py:107-196`, `memory.py:591-928`, `cron.py:733-805`, `ingest.py:2884-2944` — fetch-then-aggregate/shape in Python | S–M each |
| 3.13 | `resolve_last_active_target(sender)` / `list_broadcast_targets()` (window as config), `get_agent_status_summary()` for channel commands (+ use existing `get_goals_by_priority`) | `channels/outbox.py:231-304` (hardcoded 7-day policy), `channels/commands.py:126-239` | S |
| 3.14 | HMX dry-run forecasts: `hmx_forecast_duplicate_memories(text[])`, `hmx_forecast_bootstrap_and_lineage(...)` | `core/memory_exchange.py:1380-1879` dedup/lineage/bootstrap checks (digest verification stays Python) | M |
| 3.15 | Set-based HMX analysis staging + audit of the remaining 13 `conn.transaction()` multi-insert blocks in `memory_exchange.py` / `protected_replacement.py` | `core/memory_exchange.py:2053-2093` row-by-row insert loop | M |

---

## Tranche 4 — Policy data out of Python, into DB seeds/config

| # | Data | Today | Target |
|---|------|-------|--------|
| 4.1 | External-call prompts (brainstorm_goals, inquire, reflect, consent_request, termination_confirm) | String literals in `services/external_calls.py:223-428` | `prompt_modules` seeds + `render_prompt()` (db/33/40) |
| 4.2 | Model price table + cost math | `core/usage.py:26-81` `_MODEL_COSTS` + `estimate_cost()` | `model_costs` table + `estimate_api_cost(...)`; `record_api_usage` does `COALESCE(p_cost_usd, estimate_api_cost(...))` so the DB self-costs |
| 4.3 | Council personas | `core/tools/council.py:39-80` dict | `prompt_modules` seeds |
| 4.4 | Humanizer AI-pattern table (24 regexes + weights) | `core/tools/humanizer.py:30-199` | `ai_writing_patterns` table + `humanize_detect(text)`; **risk:** Python vs Postgres regex dialect — verify per pattern |
| 4.5 | Skill scoring/ranking (`AUTO_ACTIVATE_SCORE_THRESHOLD`, token-overlap scoring) | `services/skill_runtime.py:52-146` | Blocked on a skills catalog table (skills live on disk/plugins today). Defer until/unless skills move into the DB. |
| 4.6 | Misc magic numbers → config: decay bands (ingest), trust multipliers (slow ingest), hybrid triage 0.7/0.6, worldview-hint 0.7, confidence boost 0.05, broadcast 7-day window | Python literals | `config` keys, read inside the Tranche 2/3 functions |

---

## Explicitly staying in Python (the "absolutely can't" list)

- **LLM/HTTP calls** and provider SDK response parsing (`core/llm.py`, `usage.extract_usage`), gateway HTTP execution.
- **Document readers/parsers** (`services/ingest.py:267-1068` — PDF/DOCX/EPUB/audio/OCR/…), file I/O, `git clone`/`pg_dump` subprocesses.
- **RabbitMQ transport, channels adapters, CLI/TUI/FastAPI/MCP surfaces** (verified clean of business logic except items listed above).
- **HMX canonical digests** (`protected_section_digest_v1`, `audit_record_digest_v1`, canonical JSON): cross-implementation byte contract pinned by `tests/fixtures/digest/`; Postgres numeric formatting cannot reproduce CPython float `repr`. Only `content_hash_v1` (plain string hash) is safely shareable (2.4).
- **jsonschema validation** of HMX documents; **trust anchors / Ed25519** signature code.
- **Protected-replacement orchestration loops** — digest-gated between SQL steps, correct split as-is.
- **`hexis_rlm.py`** — REPL engine with process-local state.
- **Already-thin layers** (verified): `core/agent_loop.py` (DB owns the loop via `start_agent_turn`/`next_agent_step`/`apply_*_result`/`finish_agent_turn`), `services/worker_service.py`, `core/subconscious.py`, `core/consent.py`, `core/state.py` (minus 1.5), `journal.py`/`documents.py` tool handlers (the exemplary pattern), `apps/hexis_init.py`, `apps/worker.py`.

## Suggested execution order

1. **Tranche 1** first — deletes drift with zero new SQL (1.1–1.5 and the 1b swaps are near-mechanical; 1.6 needs dispatcher-coverage verification per tool).
2. **Tranche 2** — each item is one small migration + one call-site change.
3. **Tranche 3** in this order: 3.1/3.2 (ingest atomicity, real corruption risk today), 3.3/3.4 (HMX), 3.6/3.7 (appraisal + heartbeat plan), then the read-shapers.
4. **Tranche 4** opportunistically alongside the tranche that touches each file.

Every schema change ships as `db/migrations/NNNN_*.sql` + baseline mirror per
`db/migrations/README.md`; every deletion needs its tests repointed at the SQL
function it duplicated (parity tests become golden-output tests against SQL).

## Findings during execution (2026-07-17, Tranche 2 + 3.1/3.2)

- **Trust multiplier is cosmetic**: `slow_ingest`'s acceptance→trust
  multiplier (now config `memory.slow_ingest_trust_multipliers`) has no
  observable effect — provenance triggers recompute `memories.trust_level`
  from source attribution, and always did (the Python path passed the same
  multiplied value into the same function). Either the triggers should
  respect an explicit seed, or the multiplier should scale the SOURCE trust.
  Needs a design call before "fixing".
- **Router-failure fallback removed intentionally**: the old Python caught a
  routing failure and created ALL facts without dedup. In SQL, router and
  creator share one transaction — a router failure now fails the pass loudly
  instead of silently bypassing dedup.

## Findings during execution (2026-07-18, 3.6/3.7 + 3.12/3.13 + Tranche 4 + session-new)

Shipped: 3.6 (0054), 3.7 (0055), persona render (0056), search_history
dispatch (0057), turn source identity (0058), apply_channel_config (0059),
model_costs (0060), council personas (0061), external-call prompts (0062),
read-shapers (0063), channel shapers (0064). Audit 515 → ~460.

- **Three tools were broken on every call** and the pushdown surfaced them:
  `get_procedures`/`get_strategies` filtered `fast_recall` on a column it
  does not return; the channel `/status` and `/energy` commands read
  `heartbeat_state.max_energy` / `energy_regen_rate` / `last_heartbeat`
  (none exist — the truth is config + `last_heartbeat_at`); the channel
  `/goals` command filtered `status IN ('active','queued')` where 'queued'
  is not a memory_status (priority lives in metadata). All fixed in the SQL
  ports (0063/0064) with regression tests.
- **`heartbeat_agentic_plan` enrichment is gap-fill**: an injected context
  value wins over the DB read — production passes no pending-summary keys so
  the DB reads stand, and tests inject state without seeding HMX tables.
- **manage_schedule stats + ingest status summaries** listed under 3.12 were
  already DB-owned by earlier tranches (plan line refs were stale).
- **Remaining**: 4.4 humanizer patterns (per-pattern Python↔Postgres regex
  dialect verification — do it fresh, not as a tail-end item); deferred
  sagas 3.3-3.5/3.8/3.10/3.11/3.14/3.15; trust-multiplier design call.
