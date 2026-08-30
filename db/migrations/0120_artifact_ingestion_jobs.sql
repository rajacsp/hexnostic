-- 0120: Artifact ingestion jobs — binary uploads ride the durable job
-- queue by reference: payload.artifact_id points at preserved original bytes
-- in source_artifacts; the consumer re-reads them and runs the pipeline.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE ingestion_jobs DROP CONSTRAINT IF EXISTS ingestion_jobs_kind_check;
ALTER TABLE ingestion_jobs ADD CONSTRAINT ingestion_jobs_kind_check
    CHECK (kind IN ('text', 'url', 'artifact'));

CREATE OR REPLACE FUNCTION enqueue_ingestion_job(
    p_kind TEXT,
    p_payload JSONB,
    p_content TEXT DEFAULT NULL,
    p_content_hash TEXT DEFAULT NULL,
    p_max_attempts INT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    cap INT := COALESCE(get_config_int('ingest.job_max_content_chars'), 2000000);
    existing UUID;
    job_id UUID;
BEGIN
    IF p_kind NOT IN ('text', 'url', 'artifact') THEN
        RAISE EXCEPTION 'ingestion job kind must be text, url, or artifact, not %', p_kind;
    END IF;
    IF p_kind = 'text' AND NULLIF(p_content, '') IS NULL THEN
        RAISE EXCEPTION 'text ingestion jobs require content';
    END IF;
    IF p_kind = 'artifact' AND NULLIF(p_payload->>'artifact_id', '') IS NULL THEN
        RAISE EXCEPTION 'artifact ingestion jobs require payload.artifact_id';
    END IF;
    IF p_content IS NOT NULL AND length(p_content) > cap THEN
        RAISE EXCEPTION 'content is % chars; the job cap is % — use the synchronous CLI path (hexis ingest) for oversized documents',
            length(p_content), cap;
    END IF;

    -- Idempotent enqueue: an active job for the same content is THE job.
    IF p_content_hash IS NOT NULL THEN
        SELECT id INTO existing FROM ingestion_jobs
        WHERE content_hash = p_content_hash AND status IN ('pending', 'in_progress')
        LIMIT 1;
        IF existing IS NOT NULL THEN
            RETURN existing;
        END IF;
    END IF;

    INSERT INTO ingestion_jobs (kind, payload, content, content_hash, max_attempts)
    VALUES (p_kind, COALESCE(p_payload, '{}'::jsonb), p_content, p_content_hash,
            GREATEST(COALESCE(p_max_attempts, 3), 1))
    RETURNING id INTO job_id;
    RETURN job_id;
END;
$$ LANGUAGE plpgsql;
