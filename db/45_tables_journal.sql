-- The journal: Hexis's deliberate, permanent, written-down record — OUTSIDE the
-- memory substrate. Per the guiding principle (docs/memory_retention_design.md
-- §7): anything a human would *retain in their brain* lives in the graph/memory
-- substrate; anything a human would *write down* lives here, in a separate
-- relational table. Memory fades; a diary does not. This table is never joined
-- into the passive recall/context path (gather_turn_context / recmem_recall_context
-- / fast_recall) — it is reachable only via the explicit read_journal /
-- search_journal tools, so reading it is a deliberate act (which itself may form
-- a fresh, fallible memory), exactly like re-reading a diary.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS journal_entries (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    written_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- Text snapshot of the life chapter this was written in. The chapter itself
    -- stays in the AGE graph (brain-retained) per the guiding principle; the
    -- journal only records which chapter it belongs to.
    chapter     TEXT,
    title       TEXT,
    content     TEXT NOT NULL,
    mood        TEXT,
    tags        TEXT[],
    -- Optional embedding, for the deliberate search_journal tool only (never a
    -- passive recall path). Matches the default embedding dimension.
    embedding   vector(768),
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_journal_entries_written ON journal_entries (written_at DESC);
CREATE INDEX IF NOT EXISTS idx_journal_entries_chapter ON journal_entries (chapter);
CREATE INDEX IF NOT EXISTS idx_journal_entries_embedding
    ON journal_entries USING hnsw (embedding vector_cosine_ops);
