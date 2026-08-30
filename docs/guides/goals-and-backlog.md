<!--
title: Goals and Backlog
summary: Create and manage agent goals and task backlog
read_when:
  - "You want to give your agent goals"
  - "You want to manage the task backlog"
section: guides
-->

# Goals and Backlog

Give your agent objectives to pursue and tasks to manage.

## Quick Start

```bash
# Create a goal
hexis goals create "Learn about the user's project" --priority active

# List goals
hexis goals list

# Create from chat
# (in hexis chat, just say "I want you to help me learn Python")
```

## Goals

Goals are stored as memories of type `goal` and drive the agent's behavior during heartbeats.

### Priority Levels

| Priority | Meaning |
|----------|---------|
| `active` | Currently pursuing -- guides heartbeat decisions |
| `queued` | Next up -- will become active when capacity allows |
| `backburner` | Low priority -- pursued when nothing else is pressing |
| `completed` | Done |
| `abandoned` | No longer relevant |

### CLI Commands

```bash
# Create
hexis goals create "Help user with deployment" --priority active --description "Guide through Docker and production setup"
hexis goals create "Research ML papers" --priority queued --source curiosity

# List
hexis goals list                    # all active goals
hexis goals list --priority queued  # filter by priority
hexis goals list --json             # JSON output

# Update priority
hexis goals update <goal_id> --priority backburner --reason "User shifted focus"

# Complete
hexis goals complete <goal_id> --reason "Successfully deployed"
```

### Goal Sources

| Source | Meaning |
|--------|---------|
| `user_request` | User explicitly asked for this |
| `curiosity` | Agent's own curiosity |
| `identity` | Stems from agent's values/identity |
| `derived` | Derived from another goal |
| `external` | From external system |

## Backlog

The backlog is a task management system the agent can use to track work items via the `manage_backlog` tool.

During heartbeats, the agent can:
- Create backlog items from goals
- Update item status
- Prioritize work

## How Goals Affect Behavior

During heartbeats, the agent's active goals appear in its orientation context. The agent:

1. Reviews active goals
2. Considers available energy
3. Decides which goal to advance
4. Takes actions (recall relevant memories, reach out, reflect)
5. Records progress as episodic memories

## Related

- [Heartbeat](heartbeat.md) -- how goals drive autonomous behavior
- [Scheduling](scheduling.md) -- schedule recurring goal-related tasks
- [CLI reference](../reference/cli.md) -- full `hexis goals` syntax
