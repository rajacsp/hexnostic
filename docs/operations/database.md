<!--
title: Database
summary: Schema management, bouncing the DB, resetting
read_when:
  - "You need to apply schema changes"
  - "You want to reset the database"
  - "You want to understand database management"
section: operations
-->

# Database

PostgreSQL is the agent's brain. This page covers schema management, applying changes, and resetting.

## Quick Start

```bash
hexis doctor    # check DB health
hexis reset     # wipe and re-initialize (interactive confirmation)
```

## Schema Management

Schema files live in `db/*.sql` and are applied on fresh database initialization. They are **baked into the Docker image at build time** (not bind-mounted).

### Applying Schema Changes

Editing SQL files on disk does NOT automatically affect the running container. To apply changes:

```bash
docker compose down -v          # stop + remove data volume
docker compose build db         # rebuild image with new SQL
docker compose up -d            # start with new schema
```

Note: `down -v` destroys all data. Export anything you need first.

### Resetting the Database

```bash
hexis reset          # interactive confirmation
hexis reset --yes    # skip confirmation (CI/scripts)
```

This removes the data volume and re-initializes from `db/*.sql`.

### Verifying Schema Changes

```bash
# Check if a function exists
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "\df function_name"

# Check config keys
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT key, value FROM config WHERE key LIKE 'rlm.%'"

# Check table columns
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT column_name FROM information_schema.columns WHERE table_name = 'memories' ORDER BY ordinal_position"
```

## Service Names

| Name | Context |
|------|---------|
| `db` | Docker Compose service name (use with `docker compose`) |
| `hexis_brain` | Docker container name (use with `docker exec`) |

```bash
docker compose build db                    # correct
docker exec hexis_brain psql -U hexis_user -d hexis_memory   # correct
```

## Connection Details

| Parameter | Default |
|-----------|---------|
| Host | `127.0.0.1` |
| Port | `43815` (mapped to internal `5432`) |
| Database | `hexis_memory` |
| User | `hexis_user` |
| Password | `hexis_password` |

DSN: `postgresql://hexis_user:hexis_password@127.0.0.1:43815/hexis_memory`

## Extensions

PostgreSQL extensions used by Hexis:

| Extension | Purpose |
|-----------|---------|
| `pgvector` | Vector similarity search for embeddings |
| `age` (Apache AGE) | Graph database for memory relationships |
| `btree_gist` | GiST index support for range types |
| `pg_trgm` | Trigram text similarity for fuzzy search |

## Direct SQL Access

```bash
# Interactive psql
docker exec -it hexis_brain psql -U hexis_user -d hexis_memory

# Run a query
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT * FROM memory_health"
```

## Related

- [Database API](../reference/database-api.md) -- SQL function reference
- [Database Schema](../reference/database-schema.md) -- table reference
- [Environment Variables](environment-variables.md) -- DB connection config
- [Troubleshooting](troubleshooting.md) -- database connection issues
