# Portable Brain Audit

Hexis should be portable as a brain, not merely as a data dump. A restored
Postgres database should preserve as much cognitive functionality as possible
when attached to a new host language, UI, or application. Code outside the DB
should be swappable adapter code: senses, hands, transports, renderers, and
effect drivers.

## Boundary Rule

DB-owned logic:

- Durable state, provenance, permissions, policy, ranking, lifecycle, and
  cognitive transitions.
- Memory creation, recall, source-document preservation, trust, sensitivity,
  consolidation, retention, affect, drives, goals, journal, and change logs.
- Tool catalog, tool policy, tool audit, workflow/schedule bookkeeping, and
  external-driver queues.
- Connector manifests, setup attempts, account identity, grants, revocation,
  cursors, ingest receipts, source artifacts, and action authorization policy.
- Conversation and channel session lifecycle whenever the history is part of
  continuity.

Adapter-owned logic:

- Provider side effects: LLM calls, OAuth token exchange, Gmail/Slack/Telegram/
  Signal/Twitter API calls, web fetches, filesystem reads, OCR/PDF extraction,
  and message sending.
- Secret material: local credential files, OS keychain entries, env-provided
  credentials, and token refresh results. The DB stores redacted references,
  grants, identity, status, and audit state.
- Embedding inference execution. Stored vectors and retrieval policy belong in
  the DB; a new host must supply a compatible embedding driver for new content.

Presentation/transport-owned logic:

- CLI/TUI/web rendering, keyboard behavior, streaming display, HTTP/SSE framing,
  channel gateway connection loops, and provider-specific setup prompts.

## Current DB-Owned Surfaces

| Surface | DB contract | Host role | Status |
|---|---|---|---|
| Config/defaults | `config_defaults`, `get_config*`, `set_config` | Render/edit settings and call SQL | DB-owned |
| Memory/recall | `execute_memory_tool`, `recmem_*`, `recall_*`, source attribution | Supply embeddings and external content | DB-owned core |
| Source documents | `upsert_source_document`, `search_source_documents`, `open_source_document`, `get_memory_story` | Read files/provider bodies and pass raw content | DB-owned |
| Chat/channel turns | `chat_sessions`, `chat_messages`, `hydrate_chat_session`, `record_chat_session_turn`, `clear_chat_session_context`, `record_chat_turn_memory`, `prepare_channel_turn`, `finalize_channel_turn`, `channel_source_items`, `upsert_channel_source_item` | Transport messages, stream output, and render history | DB-owned active context and live channel source-artifact preservation; transport caches are fallback/rendering only |
| Tool runtime | `sync_tool_definitions`, `get_tool_specs_for_context`, `evaluate_tool_call`, schedules/workflows | Execute Python-driver side effects | DB-owned policy/catalog |
| Connectors | `integration_connectors`, `integration_connections`, `connection_attempts`, `prepare_connection_attempt`, status/start/complete/error/revoke functions | OAuth/API calls, secret files, env vars, and provider verification | DB-owned setup substrate and requested-scope policy; Gmail/Slack/Telegram/Signal manifests wired; Twitter/X cataloged as planned |
| Channel runtime status | `channel_adapter_runtime`, `record_channel_adapter_status`, `list_channel_adapter_status` | Start/stop provider adapters and report observed runtime state | DB-owned status surface for configured/running/error/missing-dependency visibility |
| Connector backfill | `connector_backfill_jobs`, `connector_sync_cursors`, `connector_source_items`, connector backfill lifecycle functions, provider-scoped claims, `upsert_connector_source_item` | Provider page fetches and body downloads | DB-owned cursor/job/source-artifact substrate; Gmail adapter wired |
| Connector actions | `connector_action_tool_map`, `connector_action_policies`, `connector_action_audit`, `evaluate_connector_action_call`, `grant/list/revoke_connector_action_policy`, connector-aware `evaluate_tool_call` | Provider sends/replies/labels/deletes and delivery receipts | DB-owned authorization and audit substrate; Gmail send/reply/label/spam-triage tools wired |
| Ingest jobs/receipts | `ingestion_jobs`, `ingestion_receipts`, source-document functions | Parse/read/fetch content | DB-owned job state |

## Known Gaps

1. Chat UI presentation caches still need a frontend audit:
   API, CLI, TUI, and channel chat now hydrate active context from
   `hydrate_chat_session`; client/TUI history lists are fallback/rendering
   state. The remaining check is the Next.js UI's local persistence behavior:
   it should render responsively from API events without becoming an alternate
   continuity source.

2. Most provider backfill adapters are not wired yet:
   the DB now owns cursors, provider item receipts, raw source artifacts,
   ingestion links, retries, pause/resume/cancel, status, and provider-scoped
   claims. Gmail is wired through the saved Hexis OAuth credential, token
   refresh, chunked message fetches, raw source-document preservation, and
   ingestion-job enqueueing. Live channel messages now preserve exact
   source-document artifacts through a DB trigger, and Slack/Telegram/Signal
   are first-class setup manifests, but historical Slack/Telegram/Signal/
   Twitter backfill workers still need to call the same substrate without
   silently consuming ambient credentials.

3. Provider effect coverage is still partial:
   connector action grants, constraints, context gates, revocation, evaluation,
   and audit are DB-owned. Gmail send/reply/label/spam-triage tools now use
   the substrate. Permanent delete remains intentionally unimplemented, and
   importance/spam classifiers plus non-Gmail effect adapters still need to
   use the same policy path before intervention is a complete product path.

4. UI setup state is not yet a peer of conversational setup:
   conversational setup can now inspect/start/configure/verify Gmail, Slack,
   Telegram, and Signal through DB state, and channel workers write runtime
   status into Postgres. CLI/web/channel surfaces should all render the same
   setup state, exact next steps, and worker status.

5. Some prompt/orchestration choices remain app-owned:
   model calls and streaming stay in code, but task lifecycle, prompt-module
   selection, and rendered cognitive context should continue moving toward DB
   functions/views.

## Contract Tests

The portable-brain contract should be tested at the SQL surface, not through
Python tool handlers. A passing contract means a new host language can attach
to the database and exercise the same cognitive primitives by calling SQL.

Covered now:

- Config/default resolution.
- Source-document upsert/search/open.
- DB-native memory/tool execution.
- Tool catalog/policy decisions.
- Chat/channel turn lifecycle and DB-owned active session hydration/clear.
- Live channel message source-document preservation and configurable inbound
  ingestion-job enqueueing.
- Connector setup state transitions and manifest-driven capability/scope
  derivation.
- Conversation-native setup/status/verification tools for manual channel
  connectors against the DB setup substrate.
- Channel adapter runtime status recording and listing.
- Connector backfill cursor/job lifecycle and raw provider source-item
  preservation.
- Gmail provider adapter lifecycle against the DB-owned backfill substrate.
- Connector action authorization: autonomous denial without policy, constrained
  grants, conditional Gmail state-change detection, revocation, and action audit.

Next contract tests:

- Non-Gmail provider adapter worker lifecycle against the DB substrate.
- Non-Gmail provider effect tools that consume connector action policies.
- Web setup surfaces and live channel-worker status rendering.
