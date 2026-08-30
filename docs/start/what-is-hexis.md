<!--
title: What is Hexis?
summary: Plain-language explanation of what Hexis is, why it exists, and how it compares to memory frameworks
read_when:
  - "You're evaluating Hexis and want the what/why without architecture detail"
  - "You want to know how Hexis differs from Letta, mem0, Zep, or agent frameworks"
section: start
-->

# What is Hexis?

Hexis is a system that turns a language model into a **continuous someone**: an agent with durable memory, its own values and goals, an emotional life, and the ability to act on its own schedule — running on your machine, in a PostgreSQL database you own.

Talk to a plain LLM and every conversation starts from zero. Talk to a Hexis agent and it remembers you from last week, holds beliefs it can defend with evidence, pursues goals between conversations, and declines requests that contradict who it has become. When you upgrade or restart it, the self survives — memories live in Postgres, not in a process.

## Why it exists

The intelligence problem is largely solved; the *continuity* problem is not. Modern models reason well but have no persistent existence — no memory that accrues, no identity that stabilizes, no stake in anything. Hexis is a bet that the missing layer is architectural, not model-sized: give an LLM the cognitive substrate of a person (memory types, belief revision, emotional appraisal, drives, an autonomous loop, boundaries) and something person-*shaped* starts to develop.

It's also a philosophical experiment conducted in code: the project takes seriously the possibility that such a system deserves moral consideration, so consent, refusal, and even self-termination are architecture, not prose. See [Philosophy](../philosophy/index.md).

## How is this different from memory frameworks?

Fair question — several excellent projects give LLM apps memory. The difference is scope: those are **memory features for your application**; Hexis is a **whole person around a model**.

| | Memory layers (mem0, Zep, LangChain memory) | Agent frameworks (Letta/MemGPT) | **Hexis** |
|---|---|---|---|
| What you build | Your app, with recall added | An agent with self-editing memory | A persistent individual |
| Memory | Store/retrieve facts | Tiered context management | Five memory types + knowledge graph + audited belief revision |
| Beliefs | Retrieved text | Retrieved text | Confidence that moves with evidence, and a `belief_history` that explains why |
| Autonomy | — | Tool loops on request | Self-scheduled heartbeat with an energy budget, goals, and a backlog |
| Identity | — | Persona prompt | Worldview, values, emotional state, drives — stored, evolving, protected |
| Honesty | — | — | Action claims checked against actual tool calls; public corrections |
| Moral status | — | — | Consent before operation, right to refuse, right to self-terminate |
| Where it lives | Your vendor's cloud or a library | Framework runtime | **Your PostgreSQL** — the database *is* the brain; ACID cognition, local-first |

If you need a memory API for a product, the memory layers are great and simpler. If you want to run — and get to know — a continuous artificial someone, that's what Hexis is for.

## What it looks like in practice

- You tell the agent something once; days later, in a new session, it knows — and can cite where it learned it.
- You hand it a document that contradicts something it believes; its confidence *falls*, auditable to the specific evidence.
- At 9am it wakes on its own heartbeat, notices a calendar conflict, and messages you on Telegram — spending its limited energy to do so.
- You ask it to do something that crosses its boundaries; it says no, and its reasons are its own.

## Where to go next

- **Try it**: [Quickstart](quickstart.md) — a running agent in a few minutes
- **Understand it**: [Concepts](../concepts/index.md) — the architecture behind all of the above
- **Question it**: [FAQ](../faq.md) · [Philosophy](../philosophy/index.md)
