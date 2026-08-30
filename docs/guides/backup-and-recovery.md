<!--
title: Backup and Recovery
summary: Database backup, retention policies, and config export/import
read_when:
  - "You want to back up your agent's brain"
  - "You want to export/import configuration"
section: guides
-->

# Backup and Recovery

Back up the agent's database, manage retention, and export/import configuration.

## Quick Start

The agent has built-in backup tools accessible via chat or heartbeat:

| Tool | Energy | Description |
|------|--------|-------------|
| `database_backup` | 3 | Create a database snapshot |
| `backup_retention` | 1 | Manage backup retention policies |
| `config_export` | 1 | Export configuration to JSON |
| `config_import` | 2 | Import configuration from JSON |

## Database Backup

### Via Docker

```bash
# Create a pg_dump backup
docker exec hexis_brain pg_dump -U hexis_user hexis_memory > backup_$(date +%Y%m%d).sql

# Restore from backup
docker exec -i hexis_brain psql -U hexis_user hexis_memory < backup_20260214.sql
```

### Via Agent Tools

The agent can create backups autonomously via the `database_backup` tool during heartbeats or in chat.

### Original Source Artifacts

Ingested originals up to `ingest.artifact_max_db_bytes` (25 MB default) are
stored in the database as `source_artifacts` rows, so they ride every
`pg_dump`/`hexis backup` automatically. Larger originals live in the managed
artifact directory (`$HEXIS_ARTIFACT_DIR`, default `~/.hexis/artifacts`);
`hexis backup` tars that directory as a side-car next to the dump
(`<backup>.dump.artifacts.tar`) and `hexis restore` unpacks it again —
content-addressed files are never overwritten on restore.

## Config Export/Import

Export the agent's configuration (identity, tools, goals) for portability:

```bash
# These are agent tools, used via chat:
# "Export my configuration" -> uses config_export
# "Import this configuration" -> uses config_import
```

Configuration export captures:
- Agent identity and personality
- Tool configuration (enabled/disabled, API key references, costs)
- Goal state
- Scheduled tasks

## Retention

The `backup_retention` tool manages how long backups are kept. Configure retention policies to automatically clean up old backups.

## Full Database Reset

If you need to start fresh:

```bash
hexis reset          # interactive confirmation, then wipes and re-initializes
hexis reset --yes    # skip confirmation (CI/scripts)
```

This removes all data and re-initializes the schema from `db/*.sql`.

## Related

- [Database](../operations/database.md) -- schema management and DB operations
- [Multi-Instance](multi-instance.md) -- cloning instances as backups
