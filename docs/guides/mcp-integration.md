<!--
title: MCP Integration
summary: Use Hexis as an MCP server or connect external MCP servers
read_when:
  - "You want to expose Hexis memory as MCP tools"
  - "You want to connect external MCP servers"
section: guides
-->

# MCP Integration

Use Hexis as an MCP (Model Context Protocol) server to expose memory operations, or connect external MCP servers to extend the agent's capabilities.

## Hexis as MCP Server

Expose the `cognitive_memory_api` surface as MCP tools over stdio:

```bash
hexis mcp
# or: python -m apps.hexis_mcp_server
```

### Available Tools

The MCP server exposes batch-style memory tools:

| Tool | Description |
|------|-------------|
| `remember_batch` | Store multiple memories |
| `connect_batch` | Create memory connections |
| `hydrate_batch` | Build context from memories |
| `batch` | Sequential tool calls |

It also exposes enabled Hexis registry tools whose policy allows MCP context.
Legacy memory names win on collisions, so each advertised tool name is unique.
Tool failures use MCP's `isError` flag and retain an actionable text message.

### Usage with LLM Runtimes

Any MCP-capable runtime can connect to Hexis. Typical flow:

1. LLM calls `hydrate` before answering a user (retrieves relevant context)
2. LLM calls `remember_batch` after a conversation (stores new knowledge)

### Configuration

```bash
hexis mcp --dsn postgresql://hexis_user:hexis_password@localhost:43815/hexis_memory
```

## Connecting External MCP Servers

External MCP servers are **skill-gated**: skills are the agent's capability
catalog, and MCP is a transport behind them. Servers do **not** connect at
startup — a server starts the first time the agent activates a skill bound to
it (`use_skill`), and only the tools that skill's manifest names ever reach
model context.

### The recommended path: a skill manifest

Bind a server in a skill's `SKILL.md` frontmatter — no core code changes:

```yaml
---
name: github-issues
description: Search, read, create, and comment on GitHub issues.
mcp:
  server: github
  command: npx
  args: ["-y", "@modelcontextprotocol/server-github"]
  env_requires: [GITHUB_PERSONAL_ACCESS_TOKEN]   # env var NAMES only
bound_tools:
  - mcp_github_create_issue
  - mcp_github_search_issues     # or globs like mcp_github_*
---
```

- `env_requires` lists environment variable **names**; secret values stay in
  the process environment and never touch Postgres.
- `bound_tools` is the exposure boundary: server tools not listed never become
  callable, even after the server connects.
- The connection is shared process-wide and reused across activations.
- See `skills/installed/github-issues/SKILL.md` for the reference example.

If activation can't proceed, the agent gets an exact next step instead of a
dead end: `needs_setup` (missing env var — set it and retry), `unavailable`
(no server config — add one), or `connection_failed` (with the command to run
by hand to see the server's error output).

### The config path: implicit skills

Servers added to the tools config still work with zero manifest work:

```bash
hexis tools add-mcp fs-server npx \
  --args "-y" "@modelcontextprotocol/server-filesystem" "/home/user/docs"
hexis tools remove-mcp fs-server
```

Each configured server that no manifest binds appears in the catalog as an
implicit `mcp-<server>` skill exposing all of its tools (`mcp_<server>_*`).
Write a proper manifest when you want curated instructions and a bounded tool
set.

### How It Works

- Skills are the sole model-facing capability surface; `list_skills` reports
  each skill as `usable`, `needs_setup`, or `unavailable` with the exact next step
- `use_skill` lazily connects the bound server (shared, idempotent) and
  registers only the manifest-bound tools for the turn
- MCP tools are assigned energy costs like other external tools
- Server configuration is stored in the `config` table under the `tools` key

### Config switches

| Key | Default | Effect |
|-----|---------|--------|
| `mcp.skill_gated` | `true` | Servers connect lazily on skill activation. Set `false` to restore legacy eager connection at worker startup. |
| `mcp.expose_unbound` | `false` | When `true`, `mcp_*` tool schemas are visible even to turns that skip skill routing. |

## Related

- [Tools Configuration](tools-configuration.md) -- managing tools and API keys
- [Energy Model](../reference/energy-model.md) -- energy cost mechanics
