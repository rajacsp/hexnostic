# Python-To-Postgres Migration Inventory

> **Superseded (2026-07-16):** this Slice 0 inventory is retained for
> history. The current, whole-codebase audit and prioritized work plan live
> in `plans/db_pushdown.md`. Most rows below were completed by slices 1–6
> (see `plans/python-to-postgres.md`).

This inventory tracks Python logic that should move into PostgreSQL under the DB-brain migration. The target boundary is aggressive: Postgres owns state, policy, lifecycle, routing, ranking, validation, retries, prompt assembly, and result shaping; Python owns UI, streaming transport, provider SDK calls, filesystem/process/browser I/O, and dumb side-effect execution.

## Highest-Priority Logic To Move

| Area | Current Python Surface | DB Target |
| --- | --- | --- |
| Chat turn memory | `services/chat.py::_remember_conversation`, `_estimate_importance`, `_conversation_source_identity` | `record_chat_turn_memory(...)` owns importance, RecMem/eager/direct-promotion choices, idempotency, metrics, and comparison enqueueing. |
| Channel lifecycle | `channels/conversation.py` energy checks, session upsert, message log, history trim, compaction flush | `prepare_channel_turn(...)`, `finalize_channel_turn(...)`, `flush_channel_history_to_memory(...)`. |
| Agent loop | `core/agent_loop.py` iteration, phase, continuation, energy, stop-reason, tool-call policy | `start_agent_turn(...)`, `next_agent_step(...)`, `apply_agent_*_result(...)`, `finish_agent_turn(...)`. |
| Tool policy | `core/tools/config.py`, `core/tools/registry.py` enabled-tool, optional-tool, energy, context policy | `tool_definitions`, `get_tool_specs_for_context(...)`, `evaluate_tool_call(...)`, `plan_tool_batch(...)`. |
| Workflow orchestration | `core/tools/workflow.py` DAG validation, template resolution, retries, final status | `create_workflow_execution(...)`, `claim_workflow_steps(...)`, `apply_workflow_step_result(...)`, `finalize_workflow_execution(...)`. |
| Scheduling | `core/tools/cron.py`, `core/state.py::recompute_cron_next_runs` shorthand parsing and cron next-run logic | `parse_schedule_input(...)`, `compute_next_run_at(...)`, `apply_scheduled_task_action(...)`, with `pg_cron` for DB-owned recurring jobs. |
| RecMem worker | `services/recmem.py` task context loading, output normalization, prompt selection | `load_recmem_task_context(...)`, `normalize_recmem_episode_output(...)`, `normalize_recmem_fact_output(...)`. |
| RecMem rollout/eval | Retired (#57): the rollout/eval apparatus (stub modules + 6 tables) was removed in migration 0039 — RecMem is fully rolled out. | None. |
| Subconscious dopamine | `services/subconscious.py` observation normalization and RPE computation | `normalize_subconscious_observations(...)`, `compute_dopamine_rpe(...)`, `apply_subconscious_decider_result(...)`. |
| External calls | `services/external_calls.py` think-kind dispatch, prompt shape, result normalization | `resolve_external_call_kind(...)`, `build_llm_request(...)`, `apply_think_result(...)`, `apply_tool_use_result(...)`. |
| Outbox routing | `channels/outbox.py` delivery-mode resolution, domain routing, last-active/broadcast target selection | `resolve_outbox_delivery(...)`, `claim_outbox_delivery_batch(...)`, `record_channel_delivery_result(...)`. |

## Python That Should Remain

- CLI/TUI/FastAPI presentation and streaming response formatting.
- Provider SDK calls for LLMs that cannot practically run through DB HTTP.
- Channel adapter network I/O.
- Filesystem, shell, browser, code execution, OAuth, and MCP side effects.
- Thin drivers that claim DB-issued work, perform the side effect, and submit the result.

## Audit Heuristics

The Slice 0 audit script flags Python patterns that often indicate DB-owned logic has leaked back into Python:

- Config branching: `get_config`, direct `config` table reads, and config-key conditionals.
- Direct domain mutations: inline `INSERT`, `UPDATE`, `DELETE`, or `SELECT set_config`.
- Prompt construction: `load_*_prompt`, `compose_personhood_prompt`, and direct prompt file references.
- Policy/state-machine branching: `energy_budget`, `max_iterations`, `route_status`, `on_error`, `delivery_mode`, `tool_context`.
- Workflow/scheduling logic: topological sorting, cron parsing, next-run computation, retry loops.

The audit is advisory in Slice 0. Later slices should make subsystem-specific checks blocking after the migration for that subsystem is complete.
