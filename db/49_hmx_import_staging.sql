-- HMX deliberative import staging. Staged records are not active memories.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS hmx_import_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    export_id TEXT NOT NULL,
    export_intent TEXT NOT NULL,
    strategy TEXT NOT NULL DEFAULT 'deliberative',
    source JSONB NOT NULL DEFAULT '{}'::jsonb,
    privacy JSONB NOT NULL DEFAULT '{}'::jsonb,
    envelope JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'reviewed', 'closed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS hmx_import_staging (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES hmx_import_batches(id) ON DELETE CASCADE,
    section TEXT NOT NULL,
    source_ref TEXT,
    record JSONB NOT NULL,
    conflicts JSONB NOT NULL DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'accepted', 'rejected', 'quoted', 'demoted')),
    modification_kind TEXT,
    decision_rationale TEXT,
    local_ref TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS hmx_import_ref_map (
    batch_id UUID NOT NULL REFERENCES hmx_import_batches(id) ON DELETE CASCADE,
    source_ref TEXT NOT NULL,
    local_ref TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (batch_id, source_ref)
);

CREATE INDEX IF NOT EXISTS idx_hmx_import_staging_pending
    ON hmx_import_staging (created_at, id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_hmx_import_staging_batch
    ON hmx_import_staging (batch_id, section, status);

CREATE OR REPLACE FUNCTION hmx_pending_review() RETURNS JSONB AS $$
DECLARE
    records JSONB;
    grouped JSONB;
    total_count INT;
BEGIN
    SELECT COUNT(*) INTO total_count
    FROM hmx_import_staging WHERE status = 'pending';

    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at, q.id), '[]'::jsonb)
    INTO records
    FROM (
        SELECT s.id, s.batch_id, s.section, s.source_ref, s.record,
               s.conflicts, s.metadata, s.created_at,
               b.export_id, b.export_intent, b.source
        FROM hmx_import_staging s
        JOIN hmx_import_batches b ON b.id = s.batch_id
        WHERE s.status = 'pending'
        ORDER BY s.created_at, s.id
        LIMIT 100
    ) q;

    SELECT COALESCE(jsonb_object_agg(code, count), '{}'::jsonb)
    INTO grouped
    FROM (
        SELECT COALESCE(conflict->>'code', 'none') AS code, COUNT(*) AS count
        FROM hmx_import_staging s
        LEFT JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_array_length(s.conflicts) = 0
                 THEN '[{}]'::jsonb ELSE s.conflicts END
        ) conflict ON TRUE
        WHERE s.status = 'pending'
        GROUP BY COALESCE(conflict->>'code', 'none')
    ) counts;

    RETURN jsonb_build_object(
        'total', total_count,
        'by_conflict', grouped,
        'records', records
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION hmx_pending_review_summary() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'count', COALESCE(SUM(count), 0),
        'by_section', COALESCE(jsonb_object_agg(section, count), '{}'::jsonb)
    )
    FROM (
        SELECT section, COUNT(*) AS count
        FROM hmx_import_staging
        WHERE status = 'pending'
        GROUP BY section
    ) q;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_attach_pending_review(p_context JSONB) RETURNS JSONB AS $$
    SELECT COALESCE(p_context, '{}'::jsonb)
        || jsonb_build_object('pending_import_review', hmx_pending_review_summary());
$$ LANGUAGE sql STABLE;
