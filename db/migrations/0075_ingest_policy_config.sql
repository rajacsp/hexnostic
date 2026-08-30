-- Ingestion policy is config (#91): chunking, extraction caps, thresholds,
-- and concurrency bounds become data. The Python dataclass defaults mirror
-- these seeds; tuning any of them is set_config, never a rebuild.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config (key, value, description) VALUES
    ('ingest.deep_max_words', '2000'::jsonb,
     'Documents at or under this word count get per-section appraisal (deep mode); larger get one doc-level appraisal'),
    ('ingest.max_section_chars', '2000'::jsonb,
     'Chunk size for document sectioning'),
    ('ingest.chunk_overlap', '200'::jsonb,
     'Characters of trailing overlap carried between adjacent sections'),
    ('ingest.max_facts_per_section', '20'::jsonb,
     'Extraction cap per section'),
    ('ingest.min_confidence_threshold', '0.6'::jsonb,
     'Extractions below this confidence are dropped before routing'),
    ('ingest.max_parallel_llm', '4'::jsonb,
     'Concurrent LLM extraction/appraisal calls per document (the rate-limit stampede bound)'),
    ('ingest.max_parallel_files', '2'::jsonb,
     'Files ingested concurrently during a directory walk'),
    ('ingest.llm_json_retries', '1'::jsonb,
     'Re-asks when an ingestion completion parses to empty JSON (transient HTTP retry lives at the provider layer)')
ON CONFLICT (key) DO NOTHING;
