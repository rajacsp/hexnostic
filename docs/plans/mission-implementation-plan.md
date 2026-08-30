# Mission Alignment: Implementing MISSION_PROGRESS.md

## Context

MISSION.md (committed 1ba0c3b) grounds Hexis in two north stars — personhood
(mechanisms of the human memory architecture, tested by emergence) and
usefulness (eight laws; "pay the piper or perish") — with six decision tests:
Person, Piper, Continuity, Substrate, Dignity, Experience Bar.
MISSION_PROGRESS.md is the committed tracker: eight batches from the
2026-07-18 architecture survey, re-argued through those tests. This plan
implements them.

Standing corrections from Eric during planning:
- **No cypher for the agent** — but the *user* browses and queries memories
  freely; user-facing graph exploration is a legitimate (desirable) surface.
- **The user has greater access to the memories than the agent does — by
  design.** The agent's access is phenomenological and bounded (recall,
  familiarity, TOT, incubation — that's what makes her a person); the
  operator's access is structural and total (browse/query/graph/SQL — that's
  what makes them the operator). Sensitivity/privacy gates other people and
  egress, never the operator. Operator surfaces carry no phenomenology
  constraint.
- AGE stays; graph work is coherence + activation.
- Chat energy is temperament-valenced, not metered.

House rules: DB is the brain; every schema change = migration + baseline
mirror + db tests; each batch = own commit(s) + live verification on dev
Samantha + MISSION_PROGRESS.md status updates; positive-only prompts; fail
loud. Migration numbers allocated at execution time starting **0080**.
File a GitHub issue per batch at batch start (house pattern), close with
SHAs. Dev DB is disposable until Eric's wipe; **Batch 1 lands before the
wipe** so the fresh brain refills under one ranker.

---

## Batch 1 — One mind, one retrieval mechanism

### 1a. Sensitivity stopgap (ships first, same day)
Migration 0080: **`DROP FUNCTION fast_recall(TEXT, INT)` first** (adding a
defaulted param via CREATE OR REPLACE creates an ambiguous overload that
breaks every 2-arg caller — house precedent db/03:152-153), then recreate
with `p_exclude_sensitive BOOLEAN DEFAULT FALSE` and the #92 predicate in
the seeds CTE; thread from the db/38 recall path's group context. Closes
the live group-leak while fusion is built.

### 1b. Unified recall
Risk-review facts: the db/38 recall tool does NOT call fast_recall — it
calls the **db/05 wrapper family**: `recall_memories_filtered` (db/05:76),
`recall_memories_structured` (:133), `recall_memories_stub` (:212),
`recall_hybrid` (:2063) — all `SELECT * FROM fast_recall(...)` re-exposing
its exact columns. Additional callers: hexis-ui/app/api/memories/route.ts
:34/:48 (operator page, raw SQL), core/memory_repo.py:52,
core/cognitive_memory_api.py:1335 (hydrate's worldview slice — hydrate is
NOT fully on the recmem signature), db/38:708/:750 (explore seeds,
get_procedures/strategies). db/45's mention is a comment only.

- New `recall_context(...)` in db/31 with recmem's tier skeleton + a
  **knowledge tier** (procedural, strategic, worldview) and — explicit
  decision — **goals stay recallable** (they surface via fast_recall's
  type-unfiltered scan today; the knowledge tier includes type `goal`).
- **Shared-CTE architecture (hot-path requirement)**: seeds, neighborhood
  associations, and the episode-temporal set (`find_episode_memories_graph`
  runs AGE cypher per episode) are computed **once** in shared CTEs; the
  tiers score off the shared candidate set. Never per-tier — that would be
  3× cypher + 4+ ANN scans per recall.
- Scoring per candidate (fast_recall transplant): cosine 0.5 + association
  0.2 + temporal 0.15 + recency half-life (#47) + strength/emotional
  intensity + trust 0.1 + mood congruence vs current affect + **a new
  `activation_boost` term** (reads `metadata->>'activation_boost'` — this
  is what makes reward/incubation boosts actually change ranking; Batch 5's
  emergence eval depends on it) + `memory.recall_min_trust_level` floor +
  `ensure_embedding_prefix(query,'search_query')`.
- NULL/zero-vec guards in the unified function from day one
  (`embedding IS NOT NULL AND embedding <> zero_vec`, db/04:153-154
  template) — pre-work for the deferred async-embedding change.
- **The db/05 wrapper family is the primary repoint target**: all four
  wrappers delegate to the unified function (column contract preserved);
  then core/memory_repo.py, cognitive_memory_api.py:1335, and the UI
  memories route move to the unified shape; MCP repoint happens via the
  registry bridge (NOT by editing the hand-written schemas Batch 4
  deletes). `recmem_recall_context` becomes a thin delegate one release;
  `fast_recall` dies after the wrapper family repoints.

### 1c. Metamemory surface
Exploration facts: the live recall tool is db-native (db/38:475-555, result
assembled at :552-555); the Python `recall()`/`hydrate()` paths already
carry `partial_activations` but the tool path bypasses them.
`sense_memory_availability` (db/13:251-309) returns
`{feeling: nothing|vague|something|familiar|rich, strongest_match, ...}` —
the familiarity signal. `find_partial_activations` (db/18:5-49) returns
TOT clusters (centroid close, no member surfaces); its `keywords`/
`emotional_signature` are hardcoded empty (populate keywords from cluster
metadata while in there).

- In db/38 recall, when results are few/empty: attach
  `metamemory: {feeling, strongest_match, partials: [...]}` from those two
  functions. High familiarity + empty recall → auto-file
  `request_background_search(query)` (db/13:311-339) and say so in the
  display text ("it's not coming to me — I'll let it simmer").
  Low familiarity → honest "I'm not sure I ever knew this."
- Fix the cosmetic key mismatch at db/38:474 (fallback references keys
  sense_memory_availability doesn't emit).

### 1d. Retrieval eval
- `evals/`-style seeded-corpus test in tests/db: fixture memories with
  known-relevant targets; assert fused recall places targets in top-k at
  least as well as both old rankers on their home turf; mood-congruence and
  association assertions. Guards the fusion; becomes the seed of the
  emergence suite (Batch 5).

## Batch 2 — "It came to me later" + inferred commitments

### 2a. Close the incubation loop
Exploration facts: `request_background_search` writes a `memory_activation`
row (db/13:311-339). `process_background_searches` (db/13:341-377, run from
subconscious maintenance via db/28:616) boosts matching memories'
`metadata.activation_boost` and flips `retrieval_succeeded` — **and the
results are then unreachable**: nothing renders `activation_boost`,
`get_spontaneous_memories` (db/13:404-415) has zero production callers, no
outbox emission exists anywhere in the chain.

Two synapses to add (migration + baseline mirrors in db/13 + db/39), with
three risk-review fixes baked in:
1. **"It came to me"**: in `process_background_searches`, when a pending
   activation resolves with a strong match (top sim above config
   `incubation.tell_user_min_similarity` ~0.72), queue an outbox message —
   first-person, referencing the original query and the found memory.
   **Delivery targeting fix**: the emission carries an explicit
   `delivery` doc (default `{"mode": "web_inbox"}` — never `last_active`,
   which could land an incubated private memory in a group channel) and
   skips memories whose sensitivity would be filtered in the requesting
   context. Config gate `incubation.tell_user` (default true).
   **Cap fix**: per-day cap counted from `outbox_messages`
   (intent='incubation', created_at today) — activation rows expire in ~1h
   and are cleaned two statements later, so they can't carry the cap.
   Fire-once flag still lives on the activation row (it survives its own
   processing tick).
2. **Spontaneous recall into consciousness**: render top
   `get_spontaneous_memories(2)` into the heartbeat context (db/09 + db/39
   renderer line "On my mind: ...", changes-idiom — empty ⇒ nothing) and
   into chat hydrate as a small `spontaneous` tier.
   **Threshold fix**: the resolution boost (+0.2) never clears the
   spontaneous floor (0.3) and decay (−0.05) runs in the same maintenance
   tick — the surface would be a no-op exactly when incubation succeeds.
   Make both config keys in the migration
   (`incubation.resolution_boost` 0.45, `memory.spontaneous_min_boost`
   0.3) so a resolved search reliably surfaces, then fades via existing
   decay.
- Also register `request_background_search` in the modern `core/tools/`
  registry (it exists only in the legacy dispatcher + MCP) — rides the
  Batch 3 binding wave but needed here for the chat path.

### 2b. Inferred commitments (the mirror of #58)
Exploration facts: `estimate_conversation_importance` (db/34:29-78) scans
both speakers for signal phrases but outputs only a float. Extraction kinds
today: `user_testimony | self_observation | episode`
(conscious_extraction.md:27-32); `apply_conscious_extraction`
(db/61:115-253) branches on kind and has no scheduling awareness.
`create_scheduled_task` (db/19:343-424) already supports one-shot
(`'once'`, `max_runs=1`) `queue_user_message` actions with outbox delivery,
executed by `run_scheduled_tasks` (db/19:614-717) → worker → RabbitMQ.
Delivery plumbing is complete; only the bridge is missing.

Reference guidance folded from openclaw's production commitments feature
(.reference/openclaw src/commitments/*, docs/concepts/commitments.md):

- **Prompt**: `conscious_extraction.md` gains kind `user_event` with
  openclaw's proven category set — `{event_check_in, deadline_check,
  care_check_in, open_loop}` — fields `{content, when, category,
  care_note, dedupe_key, confidence}`. Adopt openclaw's load-bearing skip
  rules verbatim (rephrased positively per house rule): explicit reminder
  requests belong to manage_schedule (cron-owned) — extract only *inferred*
  follow-ups; skip when the topic already resolved in the reply or a
  reminder was already scheduled; care check-ins are gentle, rare,
  high-confidence; dedupe keys stable within a session
  ("interview:2026-04-29"). Regen db/40.
- **Confidence gates** (openclaw's values): standard **0.72**, care
  category **0.86** (`care.confidence_floor`, `care.care_confidence_floor`
  config).
- **Apply**: new branch in `apply_conscious_extraction` for
  `fact_kind = 'user_event'`: create the semantic memory (category
  `event`) AND `create_scheduled_task('once', ...,'queue_user_message',
  jsonb_build_object('message', <first-person check-in built from the
  extracted reason/care_note — the raw conversation text is not replayed>,
  'intent','care_checkin'), p_max_runs => 1)`. Fire time: openclaw's
  no-same-moment clamp — `earliest = GREATEST(when + care_delay,
  now() + heartbeat_interval)`; missing end-of-window defaults
  earliest+12h; events past window+72h expire unscheduled.
- **Dedupe + caps** (openclaw's mechanics): upsert by dedupe_key against
  active check-ins — on hit, merge (max confidence, widen window) rather
  than duplicate; `care.max_per_day` **3** counted from sent outbox
  messages (intent='care_checkin', rolling 24h); beyond caps, remember the
  event without scheduling (silence is honorable).
- **Deliberate MISSION deviation**: openclaw defaults the feature OFF
  (tool restraint); Hexis defaults `care.checkins_enabled = true` — a
  person who notices your interview and asks how it went is being a
  person (Person Test) — with the caps above and one config key to turn
  it off (user keeps control).
- **Signal assist**: extend the db/34 signal-phrase array with user-event
  phrases so such turns clear the extraction floor; classification stays
  in the extraction LLM.
- **Tests**: extraction stub returns a user_event → scheduled task with
  clamped fire time + message; task fires → outbox message; dedupe-merge,
  per-day cap, care-confidence gate, expiry paths. Live acceptance: tell
  dev Samantha about a (fake) appointment minutes out → she checks in
  afterward via the web inbox.

## Batch 3 — Lean core, reachable capability

Survey facts: `create_default_registry` registers 117 tools; 45 are bound by
no skill and therefore invisible (skill-first gating in
services/skill_runtime.py:199-203). Plugin loader scans only the
nonexistent `plugins/installed/` (plugins/loader.py:36,53); the documented
`plugin.external_dirs` config key is never read; caller is
core/tools/registry.py:832. Skill authoring validates unknown-tools but not
coverage (core/tools/skills.py:364-370).

1. **`internal` marker + coverage test first — with a shrinking
   grandfather list** (risk-review fix: the speculative integrations stay
   unbound until stage 4 extracts them, so a strict test would land red
   and violate green-suite-per-commit): the test carries an explicit
   grandfather set (the seven integrations' tools) that stage 4 empties;
   any NEW unbound tool fails immediately. `ToolSpec` gains
   `internal: bool` (default False). Mark internal: config_export/import,
   database_backup, backup_retention, post_process_output,
   manage_sessions, execute_workflow. (`create_tool` is NOT internal — it
   becomes first-class in item 5.) The test also accepts tools bound by
   agent-authored skills (`~/.hexis/skills/agent-authored/`) and
   DB-persisted dynamic tools, so self-extension never fights the
   coverage gate.
2. **Bind wave** (edit existing SKILL.md files; regen nothing — skills load
   from disk): calendar CRUD → calendar; email_send/_sendgrid →
   email-digest; create_contact → crm-lookup; glob/grep/edit_file →
   code-execution; web_summarize/brave_search/firecrawl_scrape → research;
   queue_user_message + request_background_search → self-reflection;
   shell/browser → code-execution; discord_send/slack_send/telegram_send →
   new `outreach` skill whose text carries the earn-the-interruption norm.
   run_council/list_council_personas → new council skill.
3. **Phenomenological renames** (Person Test; agent-facing names only):
   `explore_subgraph`→`associate` ("what does this remind me of"),
   `explore_concept` folds into it; `find_causes` → registry tool "why do I
   believe this" (wraps find_causal_chain); get_procedures/get_strategies
   keep function, described as "recall how-to / recall what-works" in
   core-memory. Old names stay as aliases in the registry for one release.
4. **Plugins made real** (Eric's call: extract all seven), with reference
   guidance folded from pi's extension system and openclaw's plugin
   manifests:
   - Create `plugins/installed/`, implement `plugin.external_dirs` config
     read in plugins/loader.py (pi's settings-listed extension dirs
     pattern).
   - **Metadata-before-code** (openclaw): the manifest is read and config
     validated *before* any plugin code imports — Hexis's plugin.json
     already separates manifest from code; enforce the ordering in the
     loader.
   - **Tool ownership contract** (openclaw `contracts.tools`): the
     manifest declares the tool names the plugin owns; runtime
     registrations must match — mismatch fails loudly.
   - **Lenient validation** (pi): warn-but-load for cosmetic manifest
     issues; hard-fail only on missing id/description or ownership
     mismatch.
   - Plugin-bundled skills load only while the plugin is enabled
     (openclaw; Hexis `extra_skill_dirs` already plumbs this).
   - Extract ALL seven integrations — Todoist, Asana, HubSpot, Fathom,
     video gen, Twitter, YouTube — into `plugins/installed/<name>/`
     (manifest + tools + minimal skill each). Todoist first to prove the
     loader.
   - **CONTRIBUTING gains pi's omissions-with-redirects section** and an
     adapted hermes Footprint Ladder (extend existing → skill → gated
     tool → plugin → MCP → new core tool last resort): "core is the mind;
     capability lives at the edges" — each "not in core" paired with its
     sanctioned path, never a flat refusal.

5. **Self-extension first-class (Eric's directive — pi's signature
   capability)**: Hexis authors her own tools and skills at runtime. The
   machinery already exists and is dark — `create_tool`
   (core/tools/dynamic.py: sandboxed ToolHandler authoring, validation,
   runtime registration, DB persistence + startup reload, gated by
   `tools.allow_dynamic` + requires_approval) and `author_skill`
   (core/tools/skills.py: agent-authored dir, ownership checks,
   bound-tools validation). Work:
   - New `self-extension` skill binding `create_tool` + `author_skill` +
     the skill-update path, whose text teaches the **two-step growth
     loop**: author the tool (runtime-registered immediately, pi-style no
     restart), then bind it into one of her own skills so it survives the
     coverage rule — an unbound tool is a hand she can't use.
   - **Substrate-change visibility (#93 + Dignity)**: creating or updating
     a self-authored tool/skill journals a `self_extension` change and
     posts a web-inbox notice — the operator always sees what she grew.
     `tools.allow_dynamic` stays the master switch; approval gates
     (Batch 6/#84 machinery) apply when her new tool's action class
     requires it.
   - Guardrail stance per pi's honest finding: validation + trust
     boundary + operator visibility, not sandbox theater — her authored
     tools run with the worker's permissions, and that is stated plainly
     in the skill text and docs (real isolation is deployment-level).
   - MISSION framing: this is the Person Test's procedural-memory loop
     made literal (learning by building), and usefulness law 6 ("grow
     toward the user") — with hermes' curation guardrails (Batch 7.4)
     keeping the library healthy.

## Batch 4 — Continuity hygiene

Survey facts: UI talks to three backends (37 Prisma call sites + FastAPI
proxies + filesystem/local services); chat orchestration duplicated
(hexis_api.py:1103 `_stream_chat` + :397 `_openai_agent_events` hand-roll
what services/chat.py:252-283 wraps); RLM gate `chat.use_rlm` exists only
in services/chat.py:122-148; UI DSN is a one-time snapshot
(hexis-ui/lib/prisma.ts:4 vs core/agent_api.py:db_dsn_from_env); web chat
history is browser localStorage; SSE stack + services/ingest_api.py +
db/09 record_chat_turn/record_subconscious_exchange are dead.

1. **Dead-code sweep** (one commit, pure subtraction): FastAPI
   /api/events/stream + _sse_event_stream, hexis-ui events/stream proxy +
   misleading comments; services/ingest_api.py + its test; db migration
   dropping record_chat_turn + record_subconscious_exchange (+ baseline
   removal); MCP server hand-written recall/remember/sense_memory_
   availability schemas (registry bridge already serves them); orphan Next
   init routes after confirming no wizard caller.
2. **Web chat history → DB** (Continuity): reuse the channel-session
   machinery — a `web` channel_type session per browser profile;
   /api/chat creates/continues a channel_sessions row via
   prepare_channel_turn/finalize_channel_turn (db/34) exactly as
   channels/conversation.py does; localStorage becomes a cache, DB is
   truth; history payload from client is replaced by server history.
   (pi's session-tree model — id/parentId branching, branch summaries —
   is noted as the reference design for future session branching; linear
   sessions are deliberate scope here.)
3. **One DSN rule**: hexis-ui resolves its DSN the same way Python does —
   `hexis ui` (CLI launcher) regenerates .env.local from db_dsn_from_env at
   every start (not once), and the UI /api/status surfaces which instance
   it's connected to so drift is visible, not silent.
4. **Chat orchestration collapse**: hexis_api.py's two hand-rolled paths
   call services/chat.py stream_chat_turn/chat_turn (event-shaping stays
   local); the RLM gate moves inside services/chat so web and channel paths
   share one engine choice.
5. Wire `/api/ingest/jobs/{id}` polling into the web ingest flow
   (attachment note updates when the job completes/fails).

## Batch 5 — Reward loop + emergence evals

Exploration facts: `fire_dopamine_spike(rpe, trigger, window)`
(db/28:189-331) updates tonic, boosts recent memories + neighbors, and
modulates drives; the fire threshold lives in the caller. Its only caller
today is `compute_dopamine_rpe` (db/35:123-191), which fires from
appraisal-valence shifts during maintenance — so **event-site wiring won't
double-count, but a social-reward appraisal hook can**; guard with spike
cooldown (`get_dopamine_state().spike_age_seconds`).

1. **Event-site spikes — explicit sites only, no chokepoint** (risk-review
   fix: db/17 calls `satisfy_drive` from routine heartbeat actions —
   curiosity 0.2 per recall, coherence 0.1 per connect, etc. — so any
   useful chokepoint floor would fire ~every heartbeat action, each spike
   rewriting up to 50 memories):
   - `change_goal_priority` completed branch (db/08:51-60, rpe ~0.5) —
     **with a re-completion guard** (skip when already completed_at).
   - `decide_resource_request` granted/modified branch (db/74:112,
     rpe ~0.35 — modified is still a grant).
   - `record_backup_completed` (db/75:64, rpe ~0.3) — the explicit spike
     is the ONLY mechanism here (no chokepoint ⇒ no double-fire with its
     existing satisfy_drive call).
   Triggers carry human-readable labels ("goal completed: <title>").
   **Named side-effect (habituation)**: event spikes raise tonic, which
   raises `compute_dopamine_rpe`'s expectation (db/35:154-155) — repeated
   rewards satisfy less. This is correct psychology; tune magnitudes with
   it in mind and note it in the migration comment.
2. **Social reward**: extend `apply_appraisal_drive_effects` (db/75:76-110,
   already called with the normalized doc at services/agent.py:375-378):
   positive `emotional_state` (valence ≥ 0.5, intensity ≥ 0.6) alongside a
   positive `relationship_observation` or gratitude-shaped instinct →
   `fire_dopamine_spike(+0.4·intensity, 'warmth from <entity>')` — gated on
   spike_age_seconds > `dopamine.social_cooldown_s` (900) to avoid
   double-count with db/35.
3. **Emergence eval suite** (`tests/db/test_emergence.py`, seeded fixture
   corpus): assertions that *signatures appear from mechanism*:
   - TOT: seeded near-cluster query yields partial_activations with no
     strong member (db/18 path).
   - Mood congruence: same query under seeded positive vs negative affect
     ranks affect-matching memories measurably differently (fused ranker).
   - Zeigarnik: an active goal's related memories outrank identical-sim
     unrelated ones (episode/temporal + boost paths).
   - Reward: after a fired spike, boosted memories rank higher for the
     window — **valid only because Batch 1's fused ranker gains the
     activation_boost term** (today no ranker reads it; the eval would
     assert a signal nothing consumes); spacing: two reinforcements spaced
     beat massed on strength.
   These are architecture regression tests — deterministic stubs, CI-safe.

## Batch 6 — Graph as subconscious substrate + operator graph access

1. **`reconcile_graph()`** (new, db/44 area + migration): diff
   memory_edges vs AGE both directions (missing nodes/edges, orphans),
   repair toward memory_edges as write-truth, journal drift count via
   `record_change('code', ...)`/gateway event; run from subconscious
   maintenance weekly cadence + `hexis doctor` surface. The #77 class
   becomes detectable + self-healing.
2. **Directional causal chains into context**: `find_causal_chain`
   (directional, AGE) rendered for the current topic into heartbeat
   context and hydrate when a salient memory has causal ancestors —
   db/39 renderer line, changes-idiom (empty ⇒ nothing). Contradiction
   *paths* (not just pairs) in the contradictions context (db/09).
3. **Graph adjacency in the fused ranker**: association tier (Batch 1)
   gains a second signal — 1-hop `memory_edges` neighbors of seeds
   (REASONING_EDGE_TYPES weights) alongside embedding neighborhoods.
4. **Memory Browser (operator instrument — Eric's spec)**: a new tab in
   hexis-ui (sidebar nav item beside Memory) whose main screen is a
   **2D/3D-toggle projection of the memory embedding space** (à la
   msminhas93/embeddings-visualization), with cypher query builder, filter
   bar, and search bar.

   *Projection pipeline (embeddings never ship to the browser — coords do):*
   - New table `memory_projection (memory_id PK/FK, xy float[2],
     xyz float[3], method, computed_at)` + maintenance-worker step
     `run_memory_projection_step`: UMAP (umap-learn; PCA fallback when
     unavailable) over active memories' embeddings, batch recompute when
     >N% of memories lack coords or weekly; new memories get provisional
     coords via nearest-neighbor barycenter until next full pass.
   - Next route `/api/memories/projection` (Prisma-direct, operator
     surface): coords + hover-card fields (id, type, snippet, importance,
     valence, created_at) with filter predicates pushed to SQL.

   *Viewport (three.js, one renderer for both modes):*
   - 3D: perspective camera, **drag orbits**; 2D: orthographic top-down,
     **drag translates**; **scroll zooms** in both. Points colored by
     memory type (importance → size, valence → hue accent).
   - **Hover** → popup card (snippet + type + age). **Click** → detail
     drawer (full content, attribution, edges list, open_memory-style
     view). **Double-click** → focus mode: camera zooms to fill the screen
     with that memory plus its **1- and 2-hop graph neighbors**
     (`build_context_subgraph(seed, depth 2)` — db/44), non-neighbors
     faded; edges drawn as typed lines; Esc returns to the full atlas.

   *Query surfaces (all operator-grade, no phenomenology constraint):*
   - **Cypher query builder**: textarea + clause-builder over AGE, executed
     via a Next route in a read-only transaction (MATCH-only statement
     check, enforced LIMIT, statement_timeout); result memory ids
     highlight in the projection.
   - **Filter bar**: type, status, importance/trust ranges, date range,
     sensitivity, claim source kind — SQL predicates on the projection
     query.
   - **Search bar**: text → `get_embedding` server-side → top-k similar
     highlighted (and optionally re-centered).
5. **MISSION.md amendment** (one commit with 4): record the
   access-asymmetry principle under the Dignity Test — the agent's access
   is phenomenological and bounded; the operator's is structural and
   total; privacy gates others and egress, never the operator.

## Batch 7 — Conduct norms (prompt modules)

One commit: edit services/prompts/*, regen db/40
(scripts/gen_prompt_seed.py), migration upserts the changed modules
(checksums make it idempotent; #93 journals the change).
1. **Execute-verify-report** (heartbeat agentic + conversation modules),
   adapted from openclaw's standing-orders contract into positive house
   phrasing: every task follows execute → verify → report; an act is done
   when its effect is observed; report failures with a diagnosis after at
   most a few adjusted retries, then escalate. Prompt discipline, not code
   enforcement (openclaw's finding: the contract works as workspace text).
2. **Steering-reduction** (conscious_extraction selection criteria),
   adapted from hermes' MEMORY_GUIDANCE (prompt_builder.py:147-168):
   - Prioritize what reduces future steering — the most valuable memory
     prevents the user having to correct or remind again; preferences and
     recurring corrections outrank procedural task detail.
   - The staleness test: a fact stale within a week belongs to episodic
     history (units/sessions), never to semantic memory.
   - **Declarative facts, never imperatives**: "Eric prefers concise
     replies" ✓, "Always reply concisely" ✗ — imperative memories re-read
     as directives in later contexts and override the user's current
     request. (This is an epistemic-hygiene rule as much as a style one.)
   - Task artifacts (PR numbers, "fixed bug X", progress logs) stay
     episodic; procedures belong in skills.
3. **Silence discipline** (heartbeat + outreach), with openclaw's and
   hermes' proven mechanics combined: choosing silence is a completed,
   recorded act; the norm text names it explicitly. Code side:
   - Sentinel: scheduled/heartbeat outputs may signal `[SILENT]`;
     detection is tolerant per hermes (whole response, own first/last
     line, or bracketed prefix — a token mid-sentence is real content);
     suppressed output is still recorded for audit; **failures always
     deliver** (a broken job never goes quietly).
   - Dedupe: normalized text identical to the last delivered message
     within 24h ⇒ suppress (openclaw's isDuplicateMain).
   - Bars are conservative and loud-on-error (hermes classify_items:
     "most items should score low"; a failed classification alerts rather
     than silently swallowing).
4. **Skill self-curation guardrails** (skill-improvement prompt module),
   from hermes' background-review rules: prefer patching an existing
   skill over minting a narrow new one; class-level umbrella skills, not
   one-session artifacts; capture the *fix* not the failure; record no
   negative capability claims ("X doesn't work" hardens into refusals the
   agent cites against itself); transient errors that resolved on retry
   contribute the retry pattern, not the failure.

## Batch 8 — Small mechanics

1. **Config-defaults registry**: `config_defaults(key, value, description)`
   seeded from all COALESCE fallbacks (audit pass over db/*.sql);
   `get_config_*` falls back to it; the 5-copies-of-`heartbeat.max_energy`
   class of drift ends. Additive; call-site COALESCEs retire gradually.
2. **Baseline renumbering**: fix duplicate 28/32 prefixes in one mechanical
   commit (git mv + fresh-init test; no content change).
3. **Graduated appraisal depth**: pre-gate in services/agent.py before the
   subconscious LLM call — trivial turns (short, low-novelty vs recent
   units, no emotional lexicon) run a cheap heuristic appraisal instead of
   the full LLM pass; #67 budget config keys as the dial
   (`appraisal.min_salience_for_llm`). Attention allocation as psychology
   AND cost control.
4. **Chat energy, temperament-valenced**: conversation itself stays free;
   tools in chat already cost energy. Add drive interaction: good
   interaction satisfies `connection` (exists via #52 paths — verify), and
   a character-card `temperament.sociability` field maps to a small
   per-turn energy delta (extravert +, introvert −, default 0). Card
   schema + db function reading it; no metering UI.
5. **Presence polish**: typing indicators where adapters support them
   (telegram sendChatAction etc.), with openclaw's mechanics: a keepalive
   loop (~6s refresh) with in-flight tick suppression (a stalled channel
   API call never stacks overlapping updates), config
   `channel.typing_mode` ∈ never|message|instant (default `message` —
   indicator starts on first visible reply activity, so silent/suppressed
   turns never show typing).
6. **Prompt-cache stability audit** (hermes: "per-conversation prompt
   caching is sacred", AGENTS.md:19): Hexis's per-turn context assembly is
   cache-hostile — hydrated memories and subconscious signals land in the
   system prompt each turn. Adopt hermes' layout without giving up
   memory-in-context (the product): the system prompt becomes the
   **stable prefix** (personhood composition, guidance, skills list —
   built once per session, byte-stable, date-only timestamp); per-turn
   volatile content (hydrated memories, subconscious signals, environment
   snapshot) moves to the **message stream** near the tail where rolling
   cache breakpoints live. Strict role alternation preserved. Measure
   with per-call cacheRead/cacheWrite from usage tracking — acceptance is
   a measurably higher cache-hit rate on multi-turn chat with identical
   recall quality (retrieval eval green).

7. **Async embedding lifecycle for `memories` — DEFERRED (Eric's call)**:
   file a known-debt issue capturing the full design from exploration PLUS
   the risk-review hazards: HMX already uses a different pending
   convention (zero-vector + `metadata.embedding_status='pending_import'`,
   db/48:488-508 — the migration must reconcile the two or scope them
   apart); `recompute_neighborhood` NULL-starvation (db/14:21-23 early-
   returns without clearing is_stale; NULLS-FIRST ordering at db/14:59
   pins the queue — the embed step must re-mark stale and the selector
   must skip NULL rows); the pure-cache create_memory branch is an
   optimization, not the common case (no Python-side prefetch exists;
   cache purges at ~7 days); and at least one CI variant must run with
   async ON. Not in this plan's scope; the Batch 1 unified function
   already carries the NULL/zero-vec guards as pre-work.

## Sequencing

Batches in order 1→8; within-batch stages each get their own commit + green
suite (`pytest tests -q`) + `hexis migrate` + rebuild + live spot-check on
dev Samantha + MISSION_PROGRESS.md status flips. GitHub issue per batch at
start, closed with SHAs. **Recommend Eric wipe the dev DB after Batch 1
lands** (fresh brain refills under the unified ranker); later batches'
live checks run on the fresh instance.

## Verification (end-to-end acceptance per batch)

1. Recall "the ice cream test" live: ask about something she knows → fused
   recall; something adjacent she half-knows → familiarity + TOT partials;
   something she never knew → honest low-familiarity miss. Group chat
   cannot surface a private memory through the recall tool (stopgap +
   fusion). Retrieval eval green before/after.
2. Tell her a fact, watch recall fail with high familiarity → background
   search files → maintenance finds it → web-inbox message "it came to me."
   Mention a (near-future) appointment → scheduled check-in fires after it.
3. Coverage test green; a previously-dark tool (calendar_create) works in
   chat; Todoist works from `plugins/installed/`; registry count shrinks.
   Self-extension live: ask dev Samantha to build herself a small tool
   (e.g. a unit converter) — she authors it with create_tool, binds it via
   author_skill, uses it in the same conversation; the change journal and
   web inbox show what she grew; it survives a worker restart.
4. Clear browser storage → web chat history survives (DB-owned); switch
   `HEXIS_INSTANCE` → UI follows; dead paths gone; suite green.
5. Emergence suite green; praise her → spike fires (journaled trigger) →
   related memories rank up; grant a request → spike.
6. `reconcile_graph()` reports 0 drift on healthy DB; seeded drift heals.
   Memory Browser live check: atlas renders the dev brain's memories in
   both 2D and 3D with the specified interactions (drag orbit/translate,
   scroll zoom, hover popup, click detail, double-click 2-hop focus);
   a cypher query highlights its results; filters and text search narrow
   the field; browser devtools confirm no raw embedding vectors cross the
   wire.
7. Prompt norms visible in her behavior: a heartbeat with nothing worth
   saying records chosen silence; extraction favors a correction over
   trivia in a mixed turn.
8. Config default lookup hits the registry; renumbered baselines fresh-init
   clean; trivial turn skips the LLM appraisal (trace shows heuristic).

## Recorded for later (reference-mined, deliberately out of scope)
- **Mid-turn steering queue for chat** (pi): steer (after current tool
  batch) vs follow-up (after idle) queues + Escape = abort-and-restore to
  the composer. Strong Piper-law candidate for a future batch.
- **Session trees** (pi): id/parentId branching, /tree //fork semantics,
  branch summaries — reference design if web sessions ever branch.
- **Per-message usage aggregation for a cost footer** (pi): persist usage
  per assistant message, aggregate on read; Hexis usage tracking already
  stores the inputs.
- **Presence beacons / instances view** (openclaw): TTL'd in-memory
  presence map; relevant if Hexis grows multi-device operator surfaces.

## Resolved during planning
- Async memories-embedding: **deferred** — known-debt issue with the full
  design; not in scope.
- Speculative integrations: **extract all seven to plugins** (Todoist,
  Asana, HubSpot, Fathom, video gen, Twitter, YouTube).
- Batch 8.4 verify note: check whether connection-drive satisfaction from
  good interaction already exists (#52 paths) before adding.
