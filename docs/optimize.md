# Optimizing Apache AGE — A Practical Handbook

A production-oriented handbook for making Apache AGE (a graph extension for
PostgreSQL) fast and keeping it fast. It covers the storage model, server and
session configuration, data modeling, indexing, query writing, diagnostics,
bulk loading, maintenance, concurrency, and the anti-patterns that cause most
AGE performance fires.

**The one mental model to keep:** AGE is *not* a separate engine bolted onto
Postgres. Each graph is a PostgreSQL schema; every vertex label and edge label
is an ordinary heap table; properties are stored in a single `agtype` column;
and a Cypher query is *compiled into a normal SQL plan* over those tables. So
almost every PostgreSQL tuning technique — indexes, `EXPLAIN`, `work_mem`,
`VACUUM`, planner statistics — applies directly. The AGE-specific parts are
(1) how `agtype` interacts with indexes and (2) how Cypher chooses its starting
points. Get those two right and the rest is Postgres. ([Apache AGE][1])

---

## Contents

- **Part I — Foundations**: [1. How AGE stores a graph](#1-how-age-stores-a-graph) · [2. Session & server setup](#2-session--server-setup)
- **Part II — Server tuning**: [3. Memory & planner settings](#3-memory--planner-settings-that-matter-for-age) · [4. The JIT gotcha & agtype execution](#4-the-jit-gotcha-and-agtype-execution)
- **Part III — Modeling**: [5. Model the graph for performance](#5-model-the-graph-for-performance)
- **Part IV — Indexing**: [6. Find the real label tables](#6-find-the-real-label-tables) · [7. Structural indexes first](#7-structural-indexes-first) · [8. Property indexes by access pattern](#8-property-indexes-by-access-pattern)
- **Part V — Query optimization**: [9. Write Cypher so the index can matter](#9-write-cypher-so-the-index-can-matter) · [10. Bound variable-length paths](#10-bound-variable-length-paths) · [11. Parameterize Cypher calls](#11-parameterize-cypher-calls) · [12. The SQL ↔ Cypher boundary](#12-the-sql--cypher-boundary)
- **Part VI — Diagnostics**: [13. Always verify with EXPLAIN](#13-always-verify-with-explain) · [14. Statistics, slow-query capture & supernode hunting](#14-statistics-slow-query-capture--supernode-hunting)
- **Part VII — Writes**: [15. Bulk loading & write performance](#15-bulk-loading--write-performance)
- **Part VIII — Ops**: [16. Maintenance: VACUUM, ANALYZE, bloat, reindex](#16-maintenance-vacuum-analyze-bloat-reindex) · [17. Concurrency, locking & supernodes](#17-concurrency-locking--supernodes)
- **Part IX — Anti-patterns**: [18. Anti-pattern cheat sheet](#18-anti-pattern-cheat-sheet)
- **Part X — Playbooks**: [19. Index recipe](#19-index-recipe) · [20. Tuning checklist](#20-tuning-checklist) · [21. Worked example: Hexis `memory_graph`](#21-worked-example-hexis-memory_graph)
- [References](#references)

---

# Part I — Foundations

## 1. How AGE stores a graph

Understanding the physical layout tells you exactly what to index and what
`EXPLAIN` will show.

- **A graph is a schema.** `SELECT create_graph('my_graph');` creates a
  PostgreSQL schema named `my_graph` plus catalog rows. Metadata lives in
  `ag_catalog.ag_graph` (one row per graph) and `ag_catalog.ag_label` (one row
  per vertex/edge label). ([Apache AGE][1])
- **Each label is a table.** A vertex label `Person` becomes the heap table
  `my_graph."Person"`; an edge label `WORKS_AT` becomes `my_graph."WORKS_AT"`.
  Cypher can create these implicitly on first write, or you can pre-create them
  with `create_vlabel` / `create_elabel`. ([Apache AGE][1])
- **Vertex tables** have columns `id graphid` (a 64-bit label-tagged entity id,
  usually the table's primary key) and `properties agtype`.
- **Edge tables** have `id graphid`, `start_id graphid`, `end_id graphid`, and
  `properties agtype`. `start_id`/`end_id` are the join keys to vertex `id`s —
  they are the backbone of every traversal.
- **`agtype`** is AGE's JSON-superset property type (numbers, strings, bools,
  lists, maps, plus graph values). Property access in Cypher (`n.email`) is
  compiled to `ag_catalog.agtype_access_operator(properties, '"email"'::agtype)`,
  which is the single most important expression to remember for indexing.
- **Cypher compiles to SQL.** The `cypher('g', $$ ... $$)` call is planned into
  an ordinary query tree of scans and joins over the label tables. That is why
  `EXPLAIN` on a Cypher call shows `Seq Scan` / `Index Scan` on
  `my_graph."Person"` and nested loops across edge tables — you tune it exactly
  like any relational query.

**Consequence:** "optimizing AGE" = making the compiled SQL touch fewer rows and
use indexes. Everything below is a way to do that.

## 2. Session & server setup

AGE needs to be loaded and on the search path. Two levels:

**Per session** (or per connection pool init):

```sql
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
```

**Server-wide** (recommended for services so every backend has it without a
`LOAD`): add AGE to `shared_preload_libraries` in `postgresql.conf` and restart:

```
shared_preload_libraries = 'age'      -- plus 'vector', 'pg_stat_statements', etc.
```

Notes:

- Put `ag_catalog` on `search_path` so unqualified `cypher()`,
  `agtype_access_operator`, `create_graph`, etc. resolve. If you *don't*, fully
  qualify them (`ag_catalog.cypher(...)`).
- Make graph creation idempotent in migrations:

  ```sql
  DO $$ BEGIN
      PERFORM create_graph('my_graph');
  EXCEPTION WHEN duplicate_object THEN NULL; END $$;
  ```

- Pin your **AGE version to your PostgreSQL major version** — AGE ships a build
  per PG major, and `agtype`/planner behavior evolves between AGE releases. When
  you read advice (including this doc), confirm it against your version; several
  optimizations below depend on planner-integration fixes present in recent AGE.

---

# Part II — Server & configuration tuning

## 3. Memory & planner settings that matter for AGE

AGE workloads are join-heavy (traversals) and produce wide `agtype` rows, so a
handful of Postgres knobs move the needle. Set globally in `postgresql.conf`, or
per-session for a heavy analytical query. ([PostgreSQL][10])

| Setting | Why it matters for AGE | Rough guidance |
| --- | --- | --- |
| `shared_buffers` | Keeps hot label/index pages in RAM; traversals re-touch the same edge/vertex pages. | ~25% of RAM to start. |
| `effective_cache_size` | Tells the planner how much data is cachable → favors index scans over seq scans for traversals. | ~50–75% of RAM. |
| `work_mem` | Sorts/hashes over `agtype` (ORDER BY, DISTINCT, hash joins, aggregation) spill to disk when too small; `agtype` values are bulky. | Raise per-session for heavy queries (e.g. `SET work_mem='256MB'`) rather than globally huge. |
| `maintenance_work_mem` | Speeds `CREATE INDEX` and `VACUUM` on big label tables. | 512MB–2GB during bulk index builds. |
| `random_page_cost` | On SSD/NVMe the default (4) discourages index scans; lower it so the planner picks endpoint indexes for traversals. | 1.1 on SSD. |
| `effective_io_concurrency` | Helps bitmap heap scans (common when a GIN/expression index returns many rows). | 100–200 on SSD. |
| `max_parallel_workers_per_gather` | Large label-table scans/aggregations parallelize like any relation. | 2–4; verify it actually helps via `EXPLAIN`. |

Rule of thumb: **`effective_cache_size` high + `random_page_cost` low** is what
convinces the planner to use your endpoint and property indexes instead of
sequential-scanning a giant label table.

## 4. The JIT gotcha and `agtype` execution

**Disable JIT for `agtype`-heavy queries.** A Cypher query compiles into many
per-row expressions over `agtype` (property access, casts, comparisons).
PostgreSQL's JIT will often spend more time *compiling* those expressions than
it saves, so JIT-on can make AGE queries dramatically slower — especially short
OLTP-style traversals. Two options: ([PostgreSQL][11])

```sql
-- Per session (safest place to start):
SET jit = off;

-- Or globally in postgresql.conf, then reload:
-- jit = off
```

If you want to keep JIT for the rest of your database, raise its thresholds so
it only triggers on genuinely huge queries (`jit_above_cost`,
`jit_inline_above_cost`, `jit_optimize_above_cost`), or toggle `jit=off` only
around AGE calls.

Other `agtype` execution facts worth knowing:

- **Casting costs.** Comparing `properties.x` to a scalar involves an `agtype`
  cast (`'"active"'::agtype`, `(n.age)::int`). Keep filter values in the same
  form the index was built on (see §8) or the index won't match.
- **No index-only scans for properties.** Because a property lookup goes through
  a function over `agtype`, the index typically locates the row and Postgres
  still heap-fetches to return `properties`. Don't expect index-only scans for
  `RETURN n.email`.

---

# Part III — Data modeling

## 5. Model the graph for performance

The cheapest optimization is a model that doesn't force expensive queries.

- **Give traversals a selective anchor.** Every hot query should be able to
  *start* from a small set of vertices reachable by an indexed property (an
  `email`, `external_id`, `memory_id`). If a query has no selective start, no
  index can save it.
- **Prefer many specific labels over one giant label + a `type` property.**
  `MATCH (:Person)` scans only the `Person` table; `MATCH (n) WHERE n.type =
  'person'` scans *everything*. Labels are essentially free partitioning.
- **Direction is information.** Model edges in the direction you traverse most,
  and always specify direction in queries (`-[:X]->`). An undirected `-[:X]-`
  match must consider both endpoints.
- **Beware supernodes.** A vertex with millions of edges (a "celebrity",
  a global root, a shared tag) turns bounded traversals into scans of its whole
  edge fan-out. Mitigations: split hot edge types into their own label, cap
  degree, add time/type predicates to the edge, or precompute/denormalize the
  aggregate you actually need. (See §17.)
- **Keep bulk/opaque data off the graph.** Large blobs, embeddings, and free
  text bloat `agtype` and slow every scan. Store them in a relational table (or
  `pgvector` column) keyed by the same business id, and keep only lookup keys +
  small attributes as graph properties. Join back in SQL when needed.
- **Not everything is a graph.** Use AGE for multi-hop relationship traversal
  and pattern matching. For flat filtering, top-N, and heavy aggregation, plain
  relational tables (or SQL over the label tables) are usually faster — see §12.

---

# Part IV — Indexing

AGE creates the label tables; **you** create the indexes that make queries fast.
AGE does *not* auto-index `start_id`/`end_id` or your hot properties.

## 6. Find the real label tables

```sql
SELECT name, kind, relation
FROM ag_catalog.ag_label
WHERE graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = 'my_graph');
```

`kind` is `v` (vertex) or `e` (edge); `relation` is the actual table oid. You
will index concrete tables like `my_graph."Person"`, `my_graph."Company"`,
`my_graph."WORKS_AT"`. Check what already exists before adding more:

```sql
SELECT indexrelid::regclass AS index, indrelid::regclass AS table
FROM pg_index
WHERE indrelid = ANY (
  SELECT relation FROM ag_catalog.ag_label
  WHERE graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = 'my_graph')
);
```

Vertex/edge tables usually already have a **primary-key index on `id`** — don't
add a redundant one. The gaps are almost always `start_id`/`end_id` and
properties.

## 7. Structural indexes first

For traversal, **edge endpoint indexes are the biggest single win.** Add B-tree
indexes on the join keys: ([Microsoft Learn][2])

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS works_at_start_idx
  ON my_graph."WORKS_AT" USING btree (start_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS works_at_end_idx
  ON my_graph."WORKS_AT" USING btree (end_id);
```

Traversing `(a)-[:WORKS_AT]->(b)` joins `a.id = start_id` and `b.id = end_id`;
without these, each hop can seq-scan the whole edge table. For bidirectional
traversal patterns, a composite `(start_id, end_id)` (and/or the reverse) can
turn nested loops into index-only lookups on the edge table.

Vertex `id` is typically covered by the PK; add one only if `\d my_graph."Person"`
shows none. Use `CONCURRENTLY` on live systems to avoid locking writes (it can't
run inside a transaction block, and needs a follow-up if it fails — check
`pg_index.indisvalid`).

## 8. Property indexes by access pattern

This is where most people index the *wrong* thing. There are two distinct
property-query shapes and they need **different** indexes.

**The single most important — and most misunderstood — rule in AGE indexing:**
*the query form decides the index type, and the two common forms want different
indexes.* Confirm the form with `EXPLAIN` before you build anything.

| You write | Compiles to | Index that serves it |
| --- | --- | --- |
| `MATCH (n:L {k: v})` — **inline anchor** (idiomatic Cypher) | `properties @> '{"k": v}'` (containment) | **GIN** on `properties` (§8b) |
| `MATCH (n:L) WHERE n.k = v` — explicit predicate | `agtype_access_operator(...) = v` | **B-tree** expression index (§8a) |

They **do not cross-serve**: a B-tree expression index will *not* be used by an
inline anchor, and a GIN index will *not* be used by `WHERE n.k = v`. This is the
#1 cause of "I added an index and the plan still says `Seq Scan`." (Behavior is
planner/version-dependent — the table above is verified on AGE for PG16; always
re-confirm on yours.)

### 8a. `WHERE n.k = v` and ranges → expression B-tree

`WHERE p.email = 'a@x'` compiles to
`agtype_access_operator(properties, '"email"'::agtype) = '"a@x"'::agtype`. A
**B-tree expression index on that exact expression** serves it — and, uniquely,
also serves range comparisons and `ORDER BY n.k`: ([Microsoft Learn][2])

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_email_idx
  ON my_graph."Person" USING btree (
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"email"'::ag_catalog.agtype])
  );
```

Reach for this when you filter with `WHERE n.k = v`, do range comparisons
(`n.created_at > ...`), or sort by a property. One index per hot property.

### 8b. Inline anchor maps `{k: v}` and containment → GIN

The idiomatic anchor `MATCH (p:Person {email:'a@x'})` does **not** use
`agtype_access_operator`; it compiles to the containment test
`properties @> '{"email":"a@x"}'`, which only a **GIN index on `properties`**
serves. The same GIN index serves explicit `WHERE properties @> '{...}'` and
key-existence (`?`) — and covers *every* key on the label with one index:
([PostgreSQL][3])

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_props_gin_idx
  ON my_graph."Person" USING gin (properties);
-- serves BOTH: MATCH (p:Person {email:'a@x'})  and  WHERE properties @> '{"role":"admin"}'
```

**If your code anchors with inline maps (most codebases do), GIN is your primary
property index.** Verify the win with `EXPLAIN`: a served inline anchor shows
`Bitmap Index Scan on <gin_index>` with `Index Cond: properties @> '{...}'`
instead of `Seq Scan ... Filter: properties @> '{...}'`. Add per-key B-trees
(§8a) *in addition* only for the properties you also filter by `WHERE`/range/sort.
GIN is larger and slower to update than a single-key B-tree, so don't add it to
labels you never anchor by property.

### 8c. Partial & unique variants

**Partial** indexes shrink the index and its write cost for lifecycle/tenant
graphs — but only apply when the query predicate *implies* the index predicate:
([PostgreSQL][9])

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS active_person_email_idx
  ON my_graph."Person" USING btree (
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"email"'::ag_catalog.agtype])
  )
  WHERE ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"status"'::ag_catalog.agtype])
        = '"active"'::ag_catalog.agtype;
```

**Unique** expression indexes enforce business keys and give the planner a
`=`-returns-one-row guarantee:

```sql
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS person_external_id_uq
  ON my_graph."Person" (
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"external_id"'::ag_catalog.agtype])
  );
```

### 8d. Always ANALYZE after creating an index

New expression indexes have no statistics until analyzed, so the planner may
ignore them. Run `ANALYZE` (or wait for autovacuum) after creating indexes and
after big loads: ([PostgreSQL][4])

```sql
ANALYZE my_graph."Person";
ANALYZE my_graph."WORKS_AT";
```

---

# Part V — Query optimization

## 9. Write Cypher so the index can matter

**Start selective and labeled.** The planner can only use `person_email_idx` if
the query anchors on `Person` by `email`:

```sql
SELECT * FROM cypher('my_graph', $$
  MATCH (p:Person {email:'a@example.com'})-[:WORKS_AT]->(c:Company)
  RETURN p, c
$$) AS (p agtype, c agtype);
```

Avoid unlabeled/broad starts — they force a full scan and defeat every index:

```sql
-- Usually bad on large graphs:
MATCH (p)-[]->(c) WHERE p.email = 'a@example.com' RETURN p, c
```

**Keep predicates with the `MATCH` they constrain.** In Cypher, `WHERE` is part
of pattern matching, not just a post-filter; the engine may apply it before,
during, or after matching, so co-locating it with the pattern it restricts helps
selectivity. Prefer labeled, directed edges (`-[:WORKS_AT]->`) over
`--`/`-[]-`, which search a wider pattern. ([Apache AGE][5])

**Pipeline with `WITH` and push `LIMIT` early.** Reduce cardinality as soon as
possible so later hops and sorts operate on fewer rows:

```sql
MATCH (p:Person {tenant_id:'t1'})
WITH p LIMIT 500
MATCH (p)-[:WORKS_AT]->(c:Company)
RETURN c.name, count(*) ...
```

**Use `id()`/endpoint ids for joins, not property round-trips.** When you have a
vertex, traverse via its `id` (matched to `start_id`/`end_id`) rather than
re-looking-up by a property.

## 10. Bound variable-length paths

Unbounded traversal is the classic AGE outage. This can explode:

```sql
MATCH p = (a:Person {email:'a@example.com'})-[*]->(b) RETURN p;
```

Always bound the depth and cap the result:

```sql
MATCH p = (a:Person {email:'a@example.com'})-[*1..3]->(b)
RETURN p LIMIT 100;
```

AGE supports `[*2]`, `[*3..5]`, `[*..5]`, and unbounded `[*]`; unbounded forms
enumerate *all* matching paths and grow super-linearly with degree. Bound both
the hop count and the output. For reachability, prefer the smallest depth that
answers the question. ([Apache AGE][5])

## 11. Parameterize Cypher calls

Pass values through AGE's parameter argument instead of interpolating strings.
It avoids Cypher injection and keeps the query text stable (better for plan
caching and `pg_stat_statements` grouping):

```sql
-- $1 is an agtype map; inside Cypher the values are referenced as $email
SELECT * FROM cypher('my_graph', $$
  MATCH (p:Person {email:$email}) RETURN p
$$, $1) AS (p agtype);
-- bind $1 = '{"email": "a@example.com"}'::agtype
```

In PL/pgSQL, prefer this over `format()`-ing the value into the query body. Note
a current AGE constraint: the parameter argument generally must be a top-level
literal/bind rather than an arbitrary expression, so pass it as a single agtype
map from the caller.

## 12. The SQL ↔ Cypher boundary

Cypher is great for traversal and pattern matching. It is frequently **worse**
than plain SQL for heavy `GROUP BY` / `ORDER BY` / top-N aggregation over large
edge tables — there are well-documented cases of Cypher aggregation running much
slower than the equivalent SQL. Don't assume the Cypher form is fastest for
analytics. ([GitHub][7])

Mix them: put Cypher in a CTE to do the graph matching, then let PostgreSQL's
optimizer and relational operators do the aggregation. ([Apache AGE][6])

```sql
WITH matched AS (
  SELECT id_u, id_b
  FROM cypher('my_graph', $$
    MATCH (u:User)-[:HAS_INTERACTION]->(b:Book)
    RETURN id(u) AS id_u, id(b) AS id_b
  $$) AS (id_u agtype, id_b agtype)
)
SELECT id_u, count(*) AS n
FROM matched
GROUP BY id_u
ORDER BY n DESC
LIMIT 10;
```

For pure analytics you can even query the label tables **directly as SQL**
(`SELECT ... FROM my_graph."HAS_INTERACTION" GROUP BY start_id`), using B-tree
indexes on `start_id`/`end_id` — often the fastest path of all. Benchmark the
Cypher, the hybrid, and the raw-SQL versions on your data before committing.

---

# Part VI — Diagnostics

## 13. Always verify with `EXPLAIN`

Never trust that an index is used — prove it. Wrap the whole SQL call:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM cypher('my_graph', $$
  MATCH (p:Person {email:'a@example.com'}) RETURN p
$$) AS (p agtype);
```

Because Cypher compiles to SQL, the plan shows real scans and joins on the label
tables. Read it like any Postgres plan: ([PostgreSQL][8])

| Plan sign | Meaning / action |
| --- | --- |
| `Seq Scan` on a huge label table | Index not used or predicate unselective → check the index expression matches (§8a), `ANALYZE`, or make the start more selective. |
| `Index Scan` / `Index Only Scan` | Planner is using an index. Good. |
| `Bitmap Index Scan` + `Bitmap Heap Scan` | Index returns many rows; fine for medium selectivity. Raise `effective_io_concurrency`. |
| `Nested Loop` over edge table without an index | Missing `start_id`/`end_id` index (§7). |
| Row estimate wildly off actual | Stale stats → `ANALYZE`; consider extended statistics. |
| Large `Sort` / `HashAggregate` spilling (`Disk`) | Raise `work_mem`, push `LIMIT` earlier, or move aggregation to SQL (§12). |
| High `JIT` time in output | Set `jit = off` (§4). |

Look at **actual vs estimated rows** and **`Buffers: shared read=`** (heap/index
pages hit). Big `read` with a small result means the index locates rows but the
scan still touches a lot — usually a selectivity or model problem.

## 14. Statistics, slow-query capture & supernode hunting

**Capture the slow queries** with `pg_stat_statements` (add to
`shared_preload_libraries`): it aggregates by normalized query and surfaces total
time, calls, and mean time — the fastest way to find your worst offenders. Use
`auto_explain` to log plans of slow statements automatically in production.
([PostgreSQL][12])

```sql
SELECT calls, mean_exec_time, total_exec_time, query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

**Audit index usage** and drop dead weight — every index taxes writes and bloat:

```sql
SELECT relname, indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE schemaname = 'my_graph'
ORDER BY idx_scan ASC;   -- idx_scan = 0 → candidate for removal
```

**Check table access shape** (are traversals seq-scanning?):

```sql
SELECT relname, seq_scan, seq_tup_read, idx_scan
FROM pg_stat_user_tables
WHERE schemaname = 'my_graph'
ORDER BY seq_tup_read DESC;
```

**Hunt supernodes** — the high-degree vertices behind most blowups — straight
from the edge table (no Cypher needed):

```sql
SELECT start_id, count(*) AS out_degree
FROM my_graph."WORKS_AT"
GROUP BY start_id
ORDER BY out_degree DESC
LIMIT 20;
```

If the top vertices have orders-of-magnitude more edges than the median, treat
them specially (§17).

---

# Part VII — Writes

## 15. Bulk loading & write performance

Row-at-a-time Cypher `CREATE`/`MERGE` is convenient but slow at scale — each is a
separate planned statement. For large loads:

- **Prefer set-based / COPY-based loading.** Load raw rows into a staging table
  via `COPY`, then create vertices/edges in bulk. AGE also ships CSV loaders
  (`load_labels_from_file`, `load_edges_from_file`) for populating label tables
  directly — much faster than per-row `CREATE`. Pre-create labels with
  `create_vlabel`/`create_elabel` so ids/tables exist. ([PostgreSQL][13])
- **Build indexes *after* the load, not before.** Inserting into an unindexed
  table then creating indexes once (with a big `maintenance_work_mem`) is far
  cheaper than maintaining indexes per row. Same for endpoint indexes on a
  freshly loaded edge table.
- **Batch transactions.** Group thousands of writes per transaction, not one per
  row (commit overhead) and not one giant transaction (bloat/locks). A few
  thousand rows per commit is a good default.
- **`MERGE` is expensive.** Cypher `MERGE` does a match-or-create and needs an
  index on the merge key to avoid scanning, and can still conflict under
  concurrency. For idempotent bulk upserts, dedup in a staging table first, then
  insert only new rows.
- **`ANALYZE` after loading** so the planner sees the new distribution (§8d).
- During large loads you can temporarily relax durability knobs
  (`synchronous_commit = off`, larger `max_wal_size`) and turn them back after.

---

# Part VIII — Ops

## 16. Maintenance: VACUUM, ANALYZE, bloat, reindex

Label tables are ordinary heap tables, so they bloat from updates and deletes —
including **property updates** (`SET n.x = ...` rewrites the row) and `MERGE`.
Treat them like any high-churn Postgres table: ([PostgreSQL][14])

- **Autovacuum matters more on hot edge/vertex tables.** For a churny label,
  tune per-table thresholds so vacuum/analyze run often enough:

  ```sql
  ALTER TABLE my_graph."WORKS_AT"
    SET (autovacuum_vacuum_scale_factor = 0.02,
         autovacuum_analyze_scale_factor = 0.01);
  ```

- **Watch bloat** on big tables/indexes; a bloated GIN or expression index
  slows both reads and writes. `REINDEX INDEX CONCURRENTLY` to rebuild without
  long locks.
- **Keep stats fresh** after bulk changes with `ANALYZE`.
- **Prune indexes** the audit in §14 shows are unused.

## 17. Concurrency, locking & supernodes

- **MVCC applies unchanged.** Concurrent traversals are fine; the contention is
  in *writes* to the same rows/edges.
- **Supernodes are also a write/lock hotspot.** Everyone attaching an edge to
  the same hub vertex, or `MERGE`-ing against it, serializes and bloats. Beyond
  the read mitigations (§5), consider: sharding the hub into buckets, appending
  edges to a dedicated hot-edge label, or moving the "count/aggregate against the
  hub" need into a maintained counter rather than live traversal.
- **`MERGE` under concurrency** can create duplicates or deadlock without a
  unique index on the merge key — add the unique expression index (§8c) and be
  ready to retry serialization failures.
- **`CREATE INDEX CONCURRENTLY`** avoids blocking writers but takes longer and
  can leave an invalid index if it fails (`DROP` and retry).

---

# Part IX — Anti-patterns

## 18. Anti-pattern cheat sheet

| Anti-pattern | Why it hurts | Do instead |
| --- | --- | --- |
| `MATCH (n) RETURN n` / unlabeled starts | Full scan of every table | Anchor on a label + indexed property |
| One label + `type` property | Scans all rows of the label | Use distinct labels (§5) |
| Unbounded `-[*]->` | Path explosion / OOM | Bound depth `[*1..3]` + `LIMIT` (§10) |
| Wrong index for the query form | Inline `{k:v}` anchors need **GIN**; `WHERE n.k=v` needs **B-tree** — they don't cross-serve | Match index to form via `EXPLAIN` (§8) |
| Filtering value in wrong type | Index expression doesn't match → seq scan | Match the built expression/cast (§8a) |
| Per-row Cypher in a loop | N planned statements + overhead | Set-based Cypher/SQL, or CTE (§12, §15) |
| Heavy aggregation in Cypher | Cypher aggregation can be far slower | SQL over label tables or hybrid CTE (§12) |
| Blobs/embeddings as properties | Bloats `agtype`, slows every scan | Store relationally / `pgvector`, key by id (§5) |
| JIT on for short traversals | Compile time > run time | `SET jit = off` (§4) |
| Indexing every property | Write + storage + bloat cost | Index only hot keys; audit usage (§14) |
| Ignoring supernodes | Traversals scan huge fan-outs | Detect (§14) and special-case (§17) |

---

# Part X — Playbooks

## 19. Index recipe

For each major **vertex** label:

```sql
-- (id is usually the PK already — verify before adding)
-- Primary property index: serves inline anchors MATCH (n:Label {k: v})
-- (the common form) AND @> containment. Add for any label you anchor by property.
CREATE INDEX CONCURRENTLY IF NOT EXISTS label_props_gin_idx
  ON my_graph."Label" USING gin (properties);
-- Add a per-key B-tree ONLY for properties you also use in WHERE n.k = v / ranges / ORDER BY:
CREATE INDEX CONCURRENTLY IF NOT EXISTS label_hot_key_idx
  ON my_graph."Label" USING btree (
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"hot_key"'::ag_catalog.agtype])
  );
```

For each major **edge** label:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS edge_start_idx
  ON my_graph."EDGE_LABEL" USING btree (start_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS edge_end_idx
  ON my_graph."EDGE_LABEL" USING btree (end_id);
-- Optional composite for bidirectional patterns:
CREATE INDEX CONCURRENTLY IF NOT EXISTS edge_start_end_idx
  ON my_graph."EDGE_LABEL" USING btree (start_id, end_id);
```

Then:

```sql
ANALYZE my_graph."Label";
ANALYZE my_graph."EDGE_LABEL";
```

## 20. Tuning checklist

Work top-down; stop when the query is fast enough.

1. **Measure first.** Find the top offenders via `pg_stat_statements`; capture
   plans with `EXPLAIN (ANALYZE, BUFFERS)`.
2. **Config baseline.** `jit = off` for AGE; sane `shared_buffers`,
   `effective_cache_size`, `random_page_cost` (§3–§4).
3. **Selective, labeled starts** on every hot query (§9).
4. **Edge endpoint indexes** on `start_id`/`end_id` (§7).
5. **Expression B-tree indexes** for hot property equality/ranges (§8a); GIN
   only for containment (§8b).
6. **`ANALYZE`** after indexes and loads (§8d).
7. **Bound variable-length traversals**; push `LIMIT`/predicates early (§9–§10).
8. **Parameterize** Cypher calls (§11).
9. **Move heavy aggregation to SQL** (raw or hybrid CTE) and benchmark (§12).
10. **Hunt supernodes**; special-case them (§14, §17).
11. **Audit & drop unused indexes**; tune autovacuum on churny labels (§14, §16).
12. **Re-measure.** Confirm the plan changed and the numbers improved.

The biggest wins, in order, are almost always: **better starting points →
edge-endpoint indexes → targeted property indexes → bounded traversals**. Not
"index every property on every label."

## 21. Worked example: Hexis `memory_graph`

Hexis stores its knowledge graph in the AGE graph `memory_graph` (created
idempotently in `db/00_tables.sql`) with vertex labels `MemoryNode`,
`ConceptNode`, `ClusterNode`, `EpisodeNode`, `GoalNode`, `SelfNode`, … and edge
labels `SUPPORTS`, `CONTRADICTS`, `CAUSES`, `INSTANCE_OF`, `MEMBER_OF`,
`IN_EPISODE`, … An `EXPLAIN`-driven pass — this guide applied to itself — found:

- **Foundations were solid.** Every edge label already had `start_id`/`end_id`
  B-trees (§7 ✓), and there were no unbounded `[*]` traversals (§10 ✓).
- **But the property indexes were the wrong *kind* for the query form** — the
  headline finding. The schema had B-tree expression indexes
  (`agtype_access_operator(... "memory_id")`, `... "name"`, …), yet the ~60
  Cypher call sites anchor with **inline maps**
  (`MATCH (m:MemoryNode {memory_id: $id})`). Per §8, those compile to
  `properties @> {...}`, so `EXPLAIN` showed a **`Seq Scan`** on *every* anchored
  graph lookup — the B-tree indexes were dead for the real workload:

  ```
  Seq Scan on "MemoryNode" m  (Filter: properties @> '{"memory_id": 1234}')   -- before
  Bitmap Index Scan on idx_memory_graph_memorynode_props_gin                  -- after
  ```

- **Fix (additive, zero query rewrites): `GIN (properties)`** on the eight
  anchored labels (`MemoryNode`, `ConceptNode`, `ClusterNode`, `EpisodeNode`,
  `GoalNode`, `SelfNode`, `GoalsRoot`, `LifeChapterNode`) in `db/00_tables.sql`.
  The existing B-trees stay to serve the few `WHERE`-equality sites (§8a).
- **Config:** `jit=off` and `random_page_cost=1.1` added to the `db` service in
  `docker-compose.yml` (§3–§4) — JIT was on, which penalizes agtype-heavy plans.
- **Watch next:** a `ConceptNode`/`ClusterNode` membered by huge numbers of
  memories is the likely first supernode — detect it with the §14 degree query
  before it slows recall.

The lesson is §13's: the schema *looked* thoroughly indexed, but only `EXPLAIN`
revealed the indexes didn't match the query form. **Verify, don't assume** — it
even corrected an earlier draft of §8 in this very document.

---

## References

1. Apache AGE — Graphs (storage model): https://age.apache.org/age-manual/master/intro/graphs.html
2. Microsoft Learn — Apache AGE Performance Best Practices: https://learn.microsoft.com/en-us/azure/postgresql/azure-ai/generative-ai-age-performance
3. PostgreSQL — GIN Indexes: https://www.postgresql.org/docs/current/gin.html
4. PostgreSQL — CREATE INDEX (expression indexes & statistics): https://www.postgresql.org/docs/current/sql-createindex.html
5. Apache AGE — MATCH clause (patterns, WHERE, variable-length paths): https://age.apache.org/age-manual/master/clauses/match.html
6. Apache AGE — Using Cypher in a CTE / advanced: https://age.apache.org/age-manual/master/advanced/advanced.html
7. Apache AGE issue #2194 — SQL vs Cypher for aggregation/ordering: https://github.com/apache/age/issues/2194
8. PostgreSQL — Using EXPLAIN: https://www.postgresql.org/docs/current/using-explain.html
9. PostgreSQL — Partial Indexes: https://www.postgresql.org/docs/current/indexes-partial.html
10. PostgreSQL — Resource Consumption (memory/planner settings): https://www.postgresql.org/docs/current/runtime-config-resource.html
11. PostgreSQL — JIT: https://www.postgresql.org/docs/current/jit.html
12. PostgreSQL — pg_stat_statements: https://www.postgresql.org/docs/current/pgstatstatements.html
13. PostgreSQL — Populating a Database (bulk load, COPY, build indexes after): https://www.postgresql.org/docs/current/populate.html
14. PostgreSQL — Routine Vacuuming: https://www.postgresql.org/docs/current/routine-vacuuming.html
