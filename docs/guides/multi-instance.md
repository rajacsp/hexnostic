<!--
title: Multi-Instance
summary: Run multiple independent agents with separate brains
read_when:
  - "You want to run multiple agents"
  - "You want per-user brain isolation"
section: guides
-->

# Multi-Instance

Run multiple independent Hexis instances, each with its own database, identity, memories, and configuration.

## Quick Start

```bash
# Create instances
hexis instance create alice --description "Alice's assistant"
hexis instance create bob --description "Bob's assistant"

# Switch between them
hexis instance use alice
hexis chat    # conversations go to Alice's brain

hexis instance use bob
hexis chat    # conversations go to Bob's brain
```

## Use Cases

- Multiple agents with distinct personalities and purposes
- Isolated development/testing environments
- Per-user brain separation with strong isolation

## CLI Commands

```bash
# Create
hexis instance create <name> --description "..."

# List
hexis instance list
hexis instance list --json

# Switch active instance
hexis instance use <name>

# Show current
hexis instance current

# Clone (copies all data)
hexis instance clone alice bob --description "Bob's assistant"

# Import existing database
hexis instance import legacy --database hexis_old_db

# Delete (requires confirmation)
hexis instance delete <name>
hexis instance delete <name> --force

# Target specific instance for any command
hexis --instance alice status
hexis -i alice init
hexis -i alice chat
```

## Instance Registry

Configuration is stored in `~/.hexis/instances.json`. Each instance tracks:

- Database connection details (host, port, database name, user)
- Password environment variable name (not the value itself)
- Description and creation timestamp

## Environment Variable Override

Set `HEXIS_INSTANCE` to target a specific instance:

```bash
export HEXIS_INSTANCE=alice
hexis status                    # uses alice instance
hexis-worker --mode heartbeat   # runs heartbeat for alice
```

## Workers for Multiple Instances

Run separate workers per instance using Docker Compose overrides:

```yaml
# docker-compose.override.yml
services:
  worker_alice:
    extends:
      service: heartbeat_worker
    environment:
      HEXIS_INSTANCE: alice

  worker_bob:
    extends:
      service: heartbeat_worker
    environment:
      HEXIS_INSTANCE: bob
```

## Backward Compatibility

On first use of any instance command, Hexis auto-imports your existing `hexis_memory` database as the "default" instance. Existing single-instance setups continue to work without changes.

## Related

- [Installation](../start/installation.md) -- initial setup
- [Docker Compose](../operations/docker-compose.md) -- profiles and overrides
