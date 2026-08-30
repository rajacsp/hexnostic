# Python-To-Postgres Migration Plan

## Summary

Move Hexis to a Postgres-owned logic architecture. Python remains only as UI/API surface, streaming transport, and thin external side-effect driver where the database cannot safely perform the action directly. All domain decisions, state transitions, policy, routing, ranking, prompt assembly, tool eligibility, scheduling, memory behavior, workflow state, rollout gates, and evaluation logic move into PostgreSQL functions.

Chosen defaults:

- Use staged slices, not a single cutover.
- Permit new PostgreSQL extensions.
- Target literal DB ownership of logic, with Python sidecars reduced to dumb executors.
- Prefer DB-side HTTP via existing `pgsql-http` for non-streaming LLM/provider calls where feasible.
- Do not use PL/Python or PLV8 in the first pass; use PL/pgSQL, SQL, `pgsql-http`, `pg_cron`, `pg_jsonschema`, pgvector, and AGE.

> **Status (2026-07-16): Slices 0–6 are complete and this document is now a
> historical record of that phase. The migration continues in
> `plans/db_pushdown.md`, which is the authoritative plan for all remaining
> Python-to-Postgres work (derived from a fresh whole-codebase audit) and
> carries this document's conventions forward — parity tests before each
> move, delegation-proving wrapper tests, the tool-thinning priority order,
> and `scripts/db_brain_audit.py` as the progress metric.**

## Implementation Status

Last updated: 2026-05-23

| Slice | Status | Notes |
| --- | --- | --- |
| Slice 0: Guardrails and Inventory | Complete | Added `assert_db_brain_ready(false)`, an advisory Python-domain-logic audit script, an inventory document, and first tests. |
| Slice 1: Runtime Tables, Prompt Store, and LLM Task Framework | Complete | Added runtime tables, prompt rendering, LLM task-kind registration/request building, external-driver queue functions, and DB tests. |
| Slice 2: Chat, Channel, and Memory Turn Lifecycle | Complete | Added DB-owned chat memory recording, channel prepare/finalize/flush functions, Python wrappers, and focused DB/core tests. |
| Slice 3: RecMem, Rollout, Eval, and Subconscious Completion | Complete | Added DB-owned RecMem task context/output normalization, eval execution, rollout phase gates/status, subconscious normalization/RPE application, thin Python wrappers, and focused DB/service tests. |
| Slice 4: Tool Catalog, Tool Policy, Workflow, and Scheduling | Complete | Added DB-owned tool catalog/spec/policy functions, schedule parsing/action functions, workflow layer/template/step-state functions, Python wrappers, and focused tool/cron/workflow tests. |
| Slice 5: Agent Loop and External Calls | Complete | Added DB-owned agent turn state/step/result/event functions, external-call dispatch/result helpers, AgentLoop state wrappers, external-call resolver delegation, and focused DB/agent/external-call tests. |
| Slice 6: Tool-By-Tool Side-Effect Thinning | Complete | Added DB-native execution helpers for memory, goals, backlog, and contacts; schedule was already DB-owned in Slice 4. Python handlers now delegate to SQL first with compatibility fallbacks and focused DB/tool tests. |

## Key Architecture Changes

### 1. Add a DB Runtime Foundation

Add a new SQL layer after the existing schema files:

- `db/32_tables_runtime.sql`
- `db/33_functions_runtime.sql`
- `db/34_functions_agent_runtime.sql`
- `db/35_functions_tool_runtime.sql`

Add extensions to the DB image and initialization path:

- Keep existing `pgvector`, `pgsql-http`, Apache AGE.
- Add `pg_cron` for DB-owned recurring jobs.
- Add `pg_jsonschema` for validating JSONB tool/task/LLM payloads.
- Update `ops/Dockerfile.db`, `docker-compose.yml`, and runtime compose to enable required shared preload settings for `pg_cron`.

Add runtime tables:

- `prompt_modules`: prompt templates currently stored in `services/prompts/*.md`.
- `llm_task_kinds`: task kind, provider config key, prompt module keys, JSON response schema, token defaults.
- `external_driver_calls`: durable queue for side effects that cannot safely run inside Postgres.
- `tool_definitions`: tool name, category, schema, default energy cost, allowed contexts, approval flags, execution kind.
- `agent_turns`: durable state for chat/heartbeat agent loops.
- `agent_turn_events`: append-only trace of loop events, LLM calls, tool calls, continuations, stop reasons.
- `workflow_step_runs`: normalized step state for workflow execution instead of embedding the whole workflow engine in Python JSON.

Add foundational SQL functions:

- `assert_db_brain_ready()`
- `render_prompt(p_key text, p_context jsonb) returns text`
- `build_llm_request(p_task_kind text, p_context jsonb) returns jsonb`
- `execute_llm_http(p_request jsonb) returns jsonb`
- `enqueue_external_driver_call(p_driver text, p_payload jsonb) returns uuid`
- `claim_external_driver_call(p_driver text, p_limit int) returns jsonb`
- `apply_external_driver_result(p_call_id uuid, p_result jsonb) returns jsonb`

Python may call these functions, but must not recreate their decision logic.

### 2. Move Chat, Channel, and Memory Logic Into DB

Replace `services/chat.py::_remember_conversation` with one SQL call:

- `record_chat_turn_memory(p_user_text, p_assistant_text, p_session_id, p_source_identity, p_context jsonb) returns jsonb`

That function owns:

- importance estimation
- RecMem raw ingest
- direct-promotion decision
- eager-memory compatibility write
- source identity/idempotency
- rollout metrics
- dual-write comparison enqueueing

Replace channel lifecycle logic with DB functions:

- `prepare_channel_turn(p_message jsonb) returns jsonb`
- `finalize_channel_turn(p_session_id uuid, p_user_text text, p_assistant_text text, p_result jsonb) returns jsonb`
- `flush_channel_history_to_memory(p_session_id uuid, p_trimmed_history jsonb) returns jsonb`

These functions own:

- channel energy/rate-limit checks
- session get/create
- inbound/outbound message logging
- history trimming
- compaction memory flush
- RecMem/eager routing

Python channel adapters keep only platform I/O and text chunking.

### 3. Move Agent Loop State Into DB

Convert `core/agent_loop.py` into a thin executor around a DB state machine.

Add SQL functions:

- `start_agent_turn(p_mode text, p_user_message text, p_session_id uuid, p_context jsonb) returns jsonb`
- `next_agent_step(p_turn_id uuid) returns jsonb`
- `apply_agent_llm_result(p_turn_id uuid, p_result jsonb) returns jsonb`
- `apply_agent_tool_result(p_turn_id uuid, p_tool_call_id text, p_result jsonb) returns jsonb`
- `finish_agent_turn(p_turn_id uuid) returns jsonb`

DB owns:

- iteration limits
- energy budget
- continuation prompts
- planning/execute/verify phase transitions
- stop reasons
- message list construction
- tool-call bookkeeping
- approval state
- event emission payloads
- result summary

Python owns:

- streaming tokens to UI
- executing an LLM request returned by `next_agent_step`
- executing a tool call returned by `next_agent_step`
- returning results to the DB

Non-streaming LLM calls should move to `execute_llm_http(...)` where provider support is straightforward. Streaming chat can remain Python-side because it is presentation/transport-specific, but prompt/message construction and loop policy still come from DB.

### 4. Move Prompt and External-Call Logic Into DB

Migrate prompt files from `services/prompts/*.md` into `prompt_modules` seed data.

Replace Python prompt builders in heartbeat, RecMem, subconscious, consent, termination, reflection, and inquiry flows with:

- `build_llm_request(...)`
- `render_prompt(...)`

Move external-call dispatch rules from `services/external_calls.py` into DB:

- `resolve_external_call_kind(p_call jsonb) returns jsonb`
- `apply_think_result(p_call_id uuid, p_result jsonb) returns jsonb`
- `apply_tool_use_result(p_call_id uuid, p_result jsonb) returns jsonb`

Python external-call processor becomes:

1. claim call from DB
2. execute provider/tool side effect
3. submit result
4. no policy branching except driver selection

### 5. Move Tool Policy, Specs, and Workflow Logic Into DB

Replace Python-owned tool config logic with DB-owned catalog and policy.

Add SQL functions:

- `register_tool_driver(p_name text, p_driver text, p_metadata jsonb) returns void`
- `get_tool_specs_for_context(p_context text) returns jsonb`
- `evaluate_tool_call(p_tool_name text, p_arguments jsonb, p_context jsonb) returns jsonb`
- `plan_tool_batch(p_calls jsonb, p_context jsonb) returns jsonb`
- `record_tool_result(p_call_id text, p_result jsonb) returns jsonb`

Move tool schemas from Python `ToolSpec` definitions into `tool_definitions`. Python handlers keep only executable side effects.

Move workflow orchestration into DB:

- `create_workflow_execution(p_plan jsonb, p_context jsonb) returns jsonb`
- `claim_workflow_steps(p_workflow_id uuid) returns jsonb`
- `apply_workflow_step_result(p_step_id uuid, p_result jsonb) returns jsonb`
- `finalize_workflow_execution(p_workflow_id uuid) returns jsonb`

DB owns:

- template resolution
- dependency validation
- topological layers
- retry policy
- skip/abort behavior
- final status
- energy accounting

Python only executes claimed workflow steps by invoking the requested tool driver.

### 6. Move Scheduling, Outbox Routing, and Workers Into DB

Replace Python cron parsing and next-run computation with DB-owned scheduling.

Add or replace SQL functions:

- `parse_schedule_input(p_input jsonb) returns jsonb`
- `compute_next_run_at(p_schedule jsonb, p_timezone text) returns timestamptz`
- `apply_scheduled_task_action(p_task_id uuid) returns jsonb`

Use `pg_cron` for DB-owned recurring maintenance jobs:

- RecMem sweep
- heartbeat due checks where appropriate
- maintenance
- queue cleanup

Move outbox routing into DB:

- `resolve_outbox_delivery(p_message jsonb) returns jsonb`
- `claim_outbox_delivery_batch(p_limit int) returns jsonb`
- `record_channel_delivery_result(p_delivery_id uuid, p_result jsonb) returns jsonb`

Python channel/outbox workers send messages to adapters or webhooks but do not decide routing, fallback, broadcast target set, or delivery mode.

### 7. Finish Moving RecMem, Rollout, Eval, and Subconscious Logic

RecMem is already close to the target. Finish the migration by moving remaining Python-owned logic:

- task context loading
- LLM output normalization
- prompt construction
- ~~eval-set execution / rollout phase matrix / readiness gate application~~ — retired (#57, migration 0039)

Add SQL functions:

- `load_recmem_task_context(p_task_id uuid) returns jsonb`
- `normalize_recmem_episode_output(p_output jsonb) returns jsonb`
- `normalize_recmem_fact_output(p_output jsonb) returns jsonb`
- ~~`run_recmem_eval_set` / `apply_recmem_rollout_phase`~~ — retired (#57): the rollout/eval apparatus was removed in migration 0039; RecMem is fully rolled out, so there is nothing to push down.

Move subconscious dopamine/RPE logic into DB:

- `normalize_subconscious_observations(p_doc jsonb) returns jsonb`
- `compute_dopamine_rpe(p_context jsonb, p_doc jsonb) returns jsonb`
- `apply_subconscious_decider_result(p_doc jsonb, p_raw_response jsonb) returns jsonb`

Python only performs the LLM call if DB-side HTTP cannot perform that provider call.

## Rollout Slices

### Slice 0: Guardrails and Inventory

- Add an inventory document generated from current code paths listing Python logic that remains.
- Add a lightweight audit script that flags new non-UI Python domain logic patterns: direct config branching, direct state mutation SQL, prompt construction, policy decisions, and workflow branching.
- Add `assert_db_brain_ready()` and extension checks.
- No behavior changes.

Acceptance:

- Existing tests pass.
- Startup reports missing DB-brain extensions clearly.
- Audit script runs in CI as advisory first, not blocking.

### Slice 1: Runtime Tables, Prompt Store, and LLM Task Framework

- Add runtime tables and prompt seed data.
- Add SQL prompt rendering and LLM request builders.
- Move RecMem/subconscious/heartbeat prompt text into DB seeds.
- Keep Python prompt loaders as compatibility wrappers that call DB.

Acceptance:

- Prompt rendering parity tests match existing prompt files.
- Existing LLM flows still work.

### Slice 2: Chat, Channel, and Memory Turn Lifecycle

- Implement `record_chat_turn_memory`.
- Implement `prepare_channel_turn`, `finalize_channel_turn`, and channel history flush functions.
- Replace Python memory/channel decision code with wrappers.

Acceptance:

- Chat tests pass.
- Channel tests pass.
- RecMem raw ingest, eager compatibility, direct promotion, and compaction behavior remain equivalent.
- Python no longer estimates conversation importance or branches on RecMem/eager memory config.

### Slice 3: RecMem, Rollout, Eval, and Subconscious Completion

- Move RecMem worker normalization/context logic into SQL.
- Move rollout phase matrix and eval execution into SQL.
- Move dopamine/RPE computation into SQL.
- Make Python services wrappers around DB functions plus external LLM calls.

Acceptance:

- DB RecMem tests cover all task lifecycle paths.
- Eval/rollout service tests assert Python delegates to SQL.
- Dopamine tests verify exact parity with previous behavior.

### Slice 4: Tool Catalog, Tool Policy, Workflow, and Scheduling

- Seed `tool_definitions` from existing tool specs.
- Replace Python tool enablement, energy-cost, optional-tool, and context-policy logic with SQL.
- Move workflow DAG/retry/template logic into SQL.
- Move schedule parsing and next-run computation into SQL/pg_cron-backed functions.

Acceptance:

- Tool spec output for chat/heartbeat/MCP matches current output.
- Workflow tests pass using DB-owned step state.
- Schedule tests pass without Python `croniter` logic.
- Python registry no longer owns policy decisions.

### Slice 5: Agent Loop and External Calls

- Add DB-owned agent turn state machine.
- Replace loop policy in Python with calls to `next_agent_step` and apply-result functions.
- Move external-call kind dispatch into SQL.
- Prefer DB-side HTTP LLM execution for non-streaming calls.
- Keep streaming token transport in Python.

Acceptance:

- Agent-loop tests pass against DB turn state.
- Heartbeat/external-call tests pass.
- Python loop no longer owns iteration, phase, continuation, stop, energy, or tool-call policy.

### Slice 6: Tool-By-Tool Side-Effect Thinning

For each tool module:

- Keep provider SDK/filesystem/shell/browser side effects in Python driver code only.
- Move argument normalization, validation, persistence, dedupe, contact/memory side effects, result shaping, and policy to SQL.
- Convert DB-native tools to direct SQL functions with no Python logic beyond adapter invocation.

Priority order:

1. memory, goals, backlog, contacts, schedule
2. email/calendar ingestion side effects
3. channel/messaging tools
4. web/search/browser tools
5. filesystem/shell/code execution policy and audit

Acceptance:

- Python tool handlers contain no domain branching beyond calling DB for plan/validation, executing the side effect, and submitting result.
- Tool result shape is produced by DB.

## Public Interface Changes

Python-facing APIs become compatibility wrappers around SQL:

- `CognitiveMemory.remember_turn_raw`, `remember`, `hydrate`, and RecMem APIs remain but delegate policy to DB.
- `ToolRegistry.get_specs`, `execute`, and `execute_batch` remain but call DB for specs, policy, and execution planning.
- Agent/chat/channel APIs remain stable for callers.
- Worker services remain stable as process entrypoints but become DB task executors.

New DB public API is JSONB-first:

- All new orchestration functions return JSONB.
- All side-effect workers claim DB-issued tasks and report DB-consumable results.
- All state transitions happen inside SQL transactions.

## Test Plan

- Add DB unit tests for every new SQL function, including bad payloads, stale claims, retries, policy denial, and idempotency.
- Add parity tests before each migration slice comparing old Python output to new SQL output for representative fixtures.
- Add wrapper tests proving Python code delegates to SQL instead of reimplementing logic.
- Add integration tests for chat, channels, heartbeat, RecMem, workflow, scheduling, tools, and outbox delivery.
- Add extension tests for `pg_cron`, `pg_jsonschema`, `pgsql-http`, pgvector, and AGE availability.
- Add audit tests that fail once a slice is complete if Python reintroduces moved domain logic.
- Add performance tests for hot chat path, agent-loop DB round trips, tool batch planning, and workflow execution.

## Assumptions

- New Postgres extensions are allowed and will be baked into `ops/Dockerfile.db`.
- Python may remain as a sidecar for actions Postgres cannot safely perform, but it must not own business logic for those actions.
- Streaming LLM token delivery is treated as UI/transport-specific and may remain Python-side.
- Non-streaming LLM calls should move DB-side where provider compatibility through HTTP is practical.
- Existing public Python entrypoints should remain stable during migration.
- Each slice must be independently shippable and tested before moving to the next.
