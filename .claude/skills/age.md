# Apache AGE (Graph Database) Reference

Use this skill when modifying `db/schema.sql` with graph operations. This provides critical syntax rules for AGE (A Graph Extension) for PostgreSQL.

## Critical: AGE Does NOT Support Neo4j's ON CREATE/ON MATCH

AGE does NOT support `ON CREATE SET` or `ON MATCH SET` syntax. Instead:

```sql
-- WRONG (Neo4j syntax - will fail in AGE):
MERGE (n:Person {name: 'John'})
ON CREATE SET n.created = timestamp()
ON MATCH SET n.accessed = timestamp()

-- CORRECT (AGE approach - use separate operations):
-- First MERGE the node
MERGE (n:Person {name: 'John'})
RETURN n

-- Then update properties with a separate query if needed
MATCH (n:Person {name: 'John'})
SET n.accessed = timestamp()
RETURN n
```

## PL/pgSQL Function Pattern

When creating PL/pgSQL functions that use Cypher:

```sql
CREATE OR REPLACE FUNCTION my_graph_function(p_param UUID)
RETURNS BOOLEAN AS $$
BEGIN
    -- Use EXECUTE with format() for dynamic Cypher
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (n:MyNode {id: %L})
        RETURN n
    $q$) as (result agtype)', p_param);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
```

## Key Syntax Rules

### 1. Cypher Function Call Format
```sql
SELECT * FROM cypher('graph_name', $$
    -- Cypher query here
$$) as (column_name agtype);
```

### 2. Node Creation
```sql
-- Create node with label and properties
CREATE (n:Label {prop1: 'value', prop2: 123})

-- Create multiple nodes
CREATE (a:Person {name: 'A'}), (b:Person {name: 'B'})
```

### 3. Edge Creation (requires MATCH first)
```sql
-- Match nodes first, then create edge
MATCH (a:Person {name: 'A'})
MATCH (b:Person {name: 'B'})
CREATE (a)-[:KNOWS {since: 2020}]->(b)
RETURN a, b
```

### 4. MERGE Pattern (idempotent create)
```sql
-- MERGE ensures the pattern exists (creates if not found)
MERGE (n:Person {name: 'John'})
RETURN n

-- MERGE with edge (both nodes must exist or use CREATE for new)
MATCH (a:Person {name: 'A'})
MATCH (b:Person {name: 'B'})
MERGE (a)-[:KNOWS]->(b)
RETURN a
```

### 5. Query with RETURN
```sql
MATCH (n:Person)-[r:KNOWS]->(m:Person)
WHERE n.name = 'John'
RETURN n.name, m.name, r
```

### 6. DELETE Operations
```sql
-- Delete node (must have no edges)
MATCH (n:Person {name: 'John'})
DELETE n

-- Delete node and all its edges
MATCH (n:Person {name: 'John'})
DETACH DELETE n

-- Delete specific edge
MATCH (a)-[r:KNOWS]->(b)
WHERE a.name = 'John'
DELETE r
```

### 7. SET Properties
```sql
MATCH (n:Person {name: 'John'})
SET n.age = 30, n.city = 'NYC'
RETURN n
```

### 8. REMOVE Properties
```sql
MATCH (n:Person {name: 'John'})
REMOVE n.temporary_field
RETURN n
```

## Hexis Graph Structure

The Hexis project uses a graph called `memory_graph` with these node types:

| Node Label | Primary Key | Description |
|------------|-------------|-------------|
| `MemoryNode` | `memory_id` (UUID) | Links to memories table |
| `ConceptNode` | `name` (text) | Abstract concepts |
| `SelfNode` | singleton | Agent's self-reference |
| `GoalNode` | `goal_id` (UUID) | Links to goals table |
| `ClusterNode` | `cluster_id` (UUID) | Links to memory_clusters |
| `EpisodeNode` | `episode_id` (UUID) | Links to episodes table |
| `LifeChapterNode` | `chapter_id` | Narrative chapters |
| `TurningPointNode` | - | Significant events |
| `NarrativeThreadNode` | - | Ongoing story threads |
| `RelationshipNode` | - | Interpersonal relationships |
| `ValueConflictNode` | - | Internal value tensions |

## Edge Types (from graph_edge_type enum)

```sql
'TEMPORAL_NEXT'     -- Sequential time relationship
'CAUSES'            -- Causal relationship
'DERIVED_FROM'      -- Source/derivation
'CONTRADICTS'       -- Conflicting information
'SUPPORTS'          -- Supporting evidence
'INSTANCE_OF'       -- Concept membership
'PARENT_OF'         -- Hierarchical relationship
'ASSOCIATED'        -- General association
'ORIGINATED_FROM'   -- Goal originated from memory
'BLOCKS'            -- Blocking relationship
'EVIDENCE_FOR'      -- Evidence for goal
'SUBGOAL_OF'        -- Goal hierarchy
'CLUSTER_RELATES'   -- Cluster relationship
'CLUSTER_OVERLAPS'  -- Cluster overlap
'CLUSTER_SIMILAR'   -- Cluster similarity
'IN_EPISODE'        -- Memory in episode
'EPISODE_FOLLOWS'   -- Episode sequence
```

## Common Hexis Patterns

### Sync entity to graph (idempotent)
```sql
CREATE OR REPLACE FUNCTION sync_memory_node(p_memory_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (m:MemoryNode {memory_id: %L})
        RETURN m
    $q$) as (result agtype)', p_memory_id);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
```

### Link two nodes
```sql
CREATE OR REPLACE FUNCTION link_memories(p_from UUID, p_to UUID, p_type TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (from:MemoryNode {memory_id: %L})
        MATCH (to:MemoryNode {memory_id: %L})
        CREATE (from)-[:%s]->(to)
        RETURN from
    $q$) as (result agtype)', p_from, p_to, p_type);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
```

### Query graph relationships
```sql
CREATE OR REPLACE FUNCTION find_related(p_id UUID)
RETURNS TABLE (related_id UUID, rel_type TEXT) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (n:MemoryNode {memory_id: %L})-[r]->(m:MemoryNode)
        RETURN m.memory_id, type(r)
    $q$) as (id agtype, rtype agtype)', p_id)
    LOOP
        related_id := (rec.id::text)::uuid;
        rel_type := rec.rtype::text;
        RETURN NEXT;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;
```

## Testing AGE Queries

Test AGE queries directly in psql:
```sql
-- Load AGE extension
LOAD 'age';
SET search_path = ag_catalog, public;

-- Run a test query
SELECT * FROM cypher('memory_graph', $$
    MATCH (n)
    RETURN count(n)
$$) as (count agtype);
```

## Gotchas and Tips

1. **Always use `format()` with `%L`** for UUID/string parameters to properly escape values
2. **Edge labels are case-sensitive** - `KNOWS` != `knows`
3. **Properties in MERGE must match exactly** - partial property matches create new nodes
4. **Return types must be `agtype`** in the column definition
5. **No `ON CREATE SET`/`ON MATCH SET`** - use separate MERGE then SET queries
6. **Wrap graph operations in try/catch** to handle graph errors gracefully
7. **Use `DETACH DELETE`** when removing nodes that may have edges
