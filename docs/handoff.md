# Hexis Handoff

Last updated: 2026-07-21 (embeddinggemma.c is published; Hexis uses the
installed `embeddinggemma` binary on port 42666)

## Standing orders from Eric (do not violate)

1. **Do not touch the retired local-model app or any of its stores.** No
   commands, comparisons, blob reads, or symlinks into another app's model
   directory. Hexis uses the published `embeddinggemma` engine. (Context:
   an earlier symlink + case-insensitive filename collision let a `curl -o`
   clobber another app's model blob through the symlink — repaired and
   verified, but the lesson stands: never symlink into another app's store;
   beware macOS case-insensitive paths.)
2. **embeddinggemma.c is a true hand-port** — pure C, no C++, no dependencies
   except libcurl for the download path, no ggml, no llama.cpp linkage. Eric
   explicitly chose owning the full inference path. Do not relitigate.
3. **Use the published binary** installed by:
   `curl -fsSL https://raw.githubusercontent.com/QuixiAI/embeddinggemma.c/main/install.sh | sh`.
   Hexis resolves `embeddinggemma` from PATH or the installer default
   `~/.local/bin/embeddinggemma`; do not hard-code `~/embeddinggemma.c/build`.
4. The sidecar owns model placement and download: it uses its published cache
   path `${XDG_CACHE_HOME:-$HOME/.cache}/embeddinggemma.c/` and downloads the
   hard-coded Hugging Face URL when absent. No Hexis-side model override.
5. Re-verify machine state before acting — earlier probes go stale, and a
   duplicate package install once followed a stale "not installed" check; Eric
   called it out.

## This machine (new laptop) — environment state

- **venv**: rebuilt with uv (Python 3.12.13) after the old symlink broke in the
  laptop switch. No `pip` in it — use `uv pip install --python .venv/bin/python`.
  Shell is **fish**: `source .venv/bin/activate` fails in the Bash tool; call
  `.venv/bin/python` / `.venv/bin/pytest` / `.venv/bin/hexis` directly, or
  wrap loops in `bash -c '...'`.
- **Network**: AT&T WiFi with a content filter. apt repos (deb.debian.org,
  apt.postgresql.org) are BLOCKED (redirect to login.attwifi.com) → the db
  Docker image cannot be built locally on this network. Docker Hub, GHCR, npm,
  PyPI, and huggingface.co all work. `gh` token now has `read:packages`.
- **DB stack**: `hexis_brain` runs the prebuilt `ghcr.io/quixiai/hexis-brain:latest`
  tagged locally as `hexis-db:latest`; start with
  `docker compose up -d --no-build`. Working-tree parity comes from
  migrations (all 0001–0086 applied; **next migration number: 0087**). Rebuild
  the image from `ops/Dockerfile.db` when on an unfiltered network.
- **Agent state**: `hexis init` NOT completed — `agent.is_configured` unset,
  0 memories, embedding cache cleared. No `.env` / API keys on this machine
  (didn't transfer). `tools.allow_dynamic=true` already set in config.
- **Web UI**: deps installed via **bun** (`hexis ui` works). Gotcha: fresh
  `bun install` does not run `prisma generate` — if `/api/status` 500s with
  "Cannot find module '.prisma/client/default'", run
  `cd hexis-ui && bunx prisma generate` and restart the dev server.
- **Embeddings**: Hexis uses the published `embeddinggemma` binary, not an
  in-repo `embedding-inference/` tree and not the local source-checkout build.
  `hexis up` / `hexis ui` start it on port 42666 if that port is idle, then the
  DB reaches it through
  `EMBEDDING_SERVICE_URL=http://host.docker.internal:42666/api/embed`. Sidecar
  logs go to `~/.hexis/embeddinggemma.log`. The binary downloads the GGUF into
  its cache with libcurl if missing.
- **Init UI**: migration 0086 tightens `get_init_status()` so model setup is
  complete only when both conscious and subconscious configs have provider +
  model. The web init page no longer skips the Models screen from ambient
  stored config while DB stage is still `llm`; it pre-fills rows but waits for
  an explicit Save Models click.
- llama.cpp reference checkout: `~/llama.cpp` at commit `d77599234`, tools
  already built in `build/bin` (`llama-embedding`, `llama-tokenize`,
  `llama-gguf`). Used ONLY to generate goldens.

## Workstream A — Mission plan (MISSION_PROGRESS.md, plan at docs/plans/mission-implementation-plan.md)

- Batches 1 (#96) and 2 (#98): DONE (see git log / previous handoff).
- **Batch 3 (#99): all code complete, suite green (2457 passed / 1 skipped),
  but UNCOMMITTED** — the working tree holds:
  - `core/tools/self_extension.py` (new): `record_self_extension(pool,
    summary, notice, detail)` — journals `record_change('self_extension', …)`
    + queues a web-inbox notice via `queue_outbox_message(…,
    '{"mode":"web_inbox"}')`; advisory (log-and-continue).
  - `core/tools/dynamic.py` + `core/tools/skills.py`: call it after successful
    create_tool / author_skill (created-vs-updated distinguished).
  - Tests: `tests/core/test_dynamic_tools.py` (+2),
    `tests/core/test_skills_marketplace.py` (+1) — journal row, envelope
    `delivery == {"mode":"web_inbox"}`, first-person notice text, cleanup.
  - `CONTRIBUTING.md`: footprint ladder (extend → skill → gated tool → plugin
    → MCP → core last) + omissions-with-redirects table;
    `docs/contributing/index.md` gained Key Principle 5 linking it.
  - `apps/hexis_init.py`: **embedding-failure UX fix** (Experience Bar) —
    `_run_embedding_step(conn, step, interactive=)` shows cause + exact fix +
    "Try again?" retry-in-place (only the failed DB write reruns; answers
    kept); wraps express/character/custom write blocks, consent, and the
    non-interactive path. +3 regression tests in
    `tests/cli/test_init_noninteractive.py` (tests/cli: 50/50 green).
    The guidance now points to the published `embeddinggemma` sidecar, not
    the retired local-model app.
  - `apps/hexis_cli.py`: `hexis up` starts the installed `embeddinggemma`
    binary before the advisory embedding health probe. The old in-repo
    `embedding-inference/` directory was removed.
- **Remaining to close #99**: (1) live self-extension acceptance — blocked on
  Eric completing init + consent (needs an LLM API key; wizard at
  `hexis init` or `localhost:3477/init`): ask the agent to build a small tool
  via create_tool, bind via author_skill, use it; verify change-journal row +
  web-inbox notice + survival across worker restart; (2) flip Batch 3 rows in
  MISSION_PROGRESS.md with SHAs; (3) close #99. Commit message pattern: see
  git log; never add Co-Authored-By.
- Batches 4–8: not started. The standalone embeddinggemma.c integration has
  jumped the queue by Eric's directive; expect re-sequencing.

## Workstream B — standalone embeddinggemma.c

**Decision update**: `embedding-inference/` was removed from this repo. The
embedding engine is the published `embeddinggemma` binary from
`QuixiAI/embeddinggemma.c`, pure C with no C++ and no runtime dependency other
than libcurl for model download. Hexis must not be hard-wired to the source
checkout path.

**Serving contract**: the sidecar binds `0.0.0.0:42666` by default and serves
the DB contract already used by `get_embedding()`:
- `GET /api/tags` for health.
- `POST /api/embed` with `{"model","input":[...]}` returning
  `{"embeddings":[[768 floats]...]}`. The DB sends text prefixes itself via
  `ensure_embedding_prefix`: `search_document:`, `search_query:`,
  `clustering:`, `classification:`.

**Model** (the only one): `ggml-org/embeddinggemma-300M-qat-q4_0-GGUF`
- URL: https://huggingface.co/ggml-org/embeddinggemma-300M-qat-q4_0-GGUF/resolve/main/embeddinggemma-300M-qat-Q4_0.gguf
  (note capital `Q4_0`; lowercase 404s).
- sha256 `50d28e22432a148f6f8a86eab3700f92add5d1f54baf7790675a2a4dadbccf26`,
  277,852,192 bytes.
- The binary checks its published cache path and downloads this URL if absent.
  No Hexis-side override path.

**Project state in `~/embeddinggemma.c`**:
- `PORT_SPEC.md`, `EXTRACTION.md`, tensor manifest, token goldens, and
  embedding goldens are persisted there.
- CPU scalar engine, HTTP server, libcurl model download, accelerator backends,
  and published release binaries exist.
- Hexis integration now starts the installed binary from `hexis up` / `hexis ui`;
  init failure guidance points to `embeddinggemma`;
  `core.cli_api.embedding_service_diagnosis` labels `:42666` as the local
  sidecar and flags `:11434` as legacy configuration.

## Verification quick-reference

```bash
# suite (DB must be up)
POSTGRES_HOST=127.0.0.1 .venv/bin/pytest tests -q          # 2457 pass / 1 skip
# standalone embedding server
embeddinggemma
# Hexis integration checks
.venv/bin/python -m py_compile apps/hexis_cli.py apps/hexis_init.py core/cli_api.py
.venv/bin/pytest tests/cli/test_init_noninteractive.py -q
# regenerate goldens (only if llama.cpp bumps)
~/llama.cpp/build/bin/llama-embedding -m <gguf> -p "<s>" --pooling mean \
  --embd-normalize 2 --embd-output-format array -t 4 -ngl 0 --no-warmup
~/llama.cpp/build/bin/llama-tokenize -m <gguf> -p "<s>" --ids --no-parse-special
```

## Gotchas carried forward

- Defaulted-param SQL overloads: `DROP FUNCTION` the old signature first.
- Test fixtures: seed embeddings must embed the `ensure_embedding_prefix`
  form; `'once'` schedules need `run_at`; fixture DBs are unconfigured.
- Plugin tests use `include_bundled=False`.
- asyncpg returns JSONB as `str` (no codec registered) — `json.loads` in tests.
- macOS FS is case-insensitive: `300M-qat-Q4_0.gguf` and `300m-qat-q4_0.gguf`
  are THE SAME FILE. Never mix case variants; never symlink into app stores.
- Harness background processes get reaped between sessions — anything
  long-running (dev servers, sidecars) must be relaunched, or owned by the
  stack (`hexis up`), not by a shell.
