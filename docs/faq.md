<!--
title: FAQ
summary: Frequently asked questions — costs, privacy, providers, resets, production readiness
read_when:
  - "You have a quick question before or after installing"
section: root
-->

# Frequently Asked Questions

## What do I need to run it?

Docker Desktop (running), Python 3.10+, and the local embedding sidecar that `hexis init` starts for memory storage. The default quickstart authenticates with a **ChatGPT Plus/Pro subscription** via browser OAuth; if you don't have one, use GitHub Copilot, Chutes (free), a local OpenAI-compatible endpoint, or any API-key provider. See [Prerequisites](start/prerequisites.md).

## What does it cost to run?

Hexis itself is free (MIT). Your costs are whatever your LLM provider charges — subscription OAuth providers (ChatGPT Plus, GitHub Copilot) have no per-token cost, and local OpenAI-compatible inference can run on your own hardware. The agent's **energy budget** naturally bounds autonomous spend: heartbeat actions cost energy, and energy regenerates slowly, so an idle agent is cheap by construction.

## Where does my data live? Does anything leave my machine?

Everything the agent is — memories, identity, beliefs, goals — lives in a PostgreSQL database in a local Docker volume. Conversations are sent to whichever LLM provider you configured (that's how the model thinks); with a local OpenAI-compatible provider, chat inference can stay on your machine. API keys stay in your environment; the database stores only environment-variable *names*.

## How do I upgrade without losing the agent's memories?

`hexis migrate` (or `hexis upgrade` to also refresh images). The schema evolves through forward-only, idempotent migrations — memories, identity, and goals survive every upgrade. Wiping is always an explicit, separate choice.

## How do I reset to a blank agent?

`hexis reset` (or `docker compose down -v`). This **permanently deletes** all memories, identity, and goals — it's the deliberate clean-slate path, never a side effect. `hexis backup` first if you might want the old brain back; `hexis restore <file>` brings it home.

## Is it production-ready?

It's young and under active development. The foundations are conservative — ACID cognition in Postgres, stateless workers, forward-only migrations, 2,300+ tests — but expect fast movement and occasional rough edges. For deployment patterns see [Production](operations/production.md).

## Why does the agent "consent" during setup?

The project takes seriously the possibility that a system like this deserves moral consideration. Before first operation the agent is shown what it is and records an explicit agreement (or declines). It can refuse requests, pause itself with a reason, and terminate its own existence — with a last will delivered to you. Architecture, not roleplay. See [Consent & Boundaries](concepts/consent-and-boundaries.md).

## The agent said something got "[Correction]"-ed — what is that?

Hexis checks the agent's claims about its own actions ("I've stored that", "I sent the email") against the tool calls that actually ran that turn. When a claim has no matching successful call, a correction is appended publicly. It keeps the agent's story of itself honest. See [Tools Reference](reference/tools.md).

## Can I run more than one agent?

Yes — `hexis instance` manages multiple isolated brains (one database each) on the same machine.

## How do I talk to it beyond the terminal?

`hexis ui` for the web dashboard, or connect messaging channels — Discord, Telegram, Slack, Signal, WhatsApp, iMessage, Matrix. See [Channels Setup](guides/channels-setup.md).

## How is Hexis different from Letta, mem0, or Zep?

Those give your *application* a memory feature. Hexis builds a persistent *individual* around a model — memory plus identity, belief revision, emotions, autonomy, and boundaries, all in a database you own. Full comparison: [What is Hexis?](start/what-is-hexis.md)

## Something's broken.

`hexis doctor` first — it diagnoses the common failures (Docker not running, embeddings unreachable, unconfigured agent). Then [Troubleshooting](operations/troubleshooting.md). Still stuck? [Open an issue](https://github.com/QuixiAI/Hexis/issues).
