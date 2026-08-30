-- Per-section ingestion receipts (#85/#90): record/lookup over
-- ingestion_receipts (db/32), with a legacy UNION so pre-table documents
-- still skip. The persist functions (db/66) insert receipts atomically.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_ingestion_receipt(
    p_doc_ref TEXT,
    p_section_hash TEXT,
    p_memory_id UUID DEFAULT NULL,
    p_memories_created INT DEFAULT 0,
    p_source_path TEXT DEFAULT NULL
) RETURNS VOID AS $$
    INSERT INTO ingestion_receipts (doc_ref, section_hash, memory_id, memories_created, source_path)
    VALUES (p_doc_ref, p_section_hash, p_memory_id, COALESCE(p_memories_created, 0), p_source_path)
    ON CONFLICT (doc_ref, section_hash) DO NOTHING;
$$ LANGUAGE sql;

-- Receipt lookup: the receipts table, with the legacy whole-document
-- memory-attribution fallback ONLY for documents that predate the table —
-- a new-era document always has table rows (the enc: sentinel lands with
-- the encounter), so its encounter attribution can never resurrect the
-- receipt-before-work skip (#85).
CREATE OR REPLACE FUNCTION get_ingestion_receipts(
    p_doc_ref TEXT,
    p_hashes TEXT[]
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(hash, memory_id), '{}'::jsonb) FROM (
        SELECT r.section_hash AS hash, r.memory_id
        FROM ingestion_receipts r
        WHERE r.doc_ref = p_doc_ref AND r.section_hash = ANY(p_hashes)
        UNION
        SELECT m.source_attribution->>'content_hash' AS hash, m.id AS memory_id
        FROM memories m
        WHERE NOT EXISTS (SELECT 1 FROM ingestion_receipts r WHERE r.doc_ref = p_doc_ref)
          AND m.source_attribution->>'ref' = p_doc_ref
          AND m.source_attribution->>'content_hash' = ANY(p_hashes)
    ) hits;
$$ LANGUAGE sql STABLE;
