<!--
title: First Conversation
summary: Start chatting with your Hexis agent
read_when:
  - "You want to talk to your agent"
  - "You want to understand how chat works"
section: start
-->

# First Conversation

Chat with your configured agent using the interactive CLI.

## Quick Start

```bash
hexis chat
```

This opens an interactive conversation loop with memory enrichment and tool access.

## How It Works

The chat loop automatically:

1. **Enriches your prompt** with relevant memories from the agent's brain (RAG-style)
2. **Gives the agent tools** via function calling -- memory operations, web search, file access, and more
3. **Forms new memories** from the conversation -- explicitly via the `remember` tool during the turn, and selectively afterward: a background sweep reviews recent turns and promotes salient facts (identity, relationships, commitments, preferences) into durable memory

## Chat Options

```bash
# Default: memory tools + extended tools (web, filesystem, shell)
hexis chat

# Specify a different LLM endpoint
hexis chat --endpoint http://localhost:8000/v1 --model local-model

# Memory tools only (no web/filesystem/shell)
hexis chat --no-extended-tools

# Quiet mode (less verbose output)
hexis chat -q
```

## What to Try

- **Ask about itself** -- "What do you know about yourself?" (tests identity retrieval)
- **Tell it something** -- "I prefer dark mode" (tests memory formation)
- **Ask a follow-up** -- "What do I prefer?" (tests memory recall)
- **Give it a goal** -- "I want you to help me learn Python" (tests goal creation)

## Understanding the Output

During chat, you may see:

- **Memory recall indicators** -- shows which memories were retrieved for context
- **Tool calls** -- shows when the agent uses tools (recall, remember, add_evidence, web_search, etc.)
- **Memory formation** -- indicates new memories being created from the conversation
- **`[Correction]` notes** -- if the agent claimed an action (stored, sent, scheduled) that no tool call actually performed, a correction is appended automatically

## Verify Memories Were Created

After chatting, check that the agent remembered:

```bash
hexis recall "what we discussed"    # search memories
hexis status                         # see memory counts
```

## Next Steps

- [Next Steps](next-steps.md) -- explore more features
