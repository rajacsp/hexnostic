SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS hmx_import_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), export_id TEXT NOT NULL,
    export_intent TEXT NOT NULL, strategy TEXT NOT NULL DEFAULT 'deliberative',
    source JSONB NOT NULL DEFAULT '{}'::jsonb, privacy JSONB NOT NULL DEFAULT '{}'::jsonb,
    envelope JSONB NOT NULL DEFAULT '{}'::jsonb, metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','reviewed','closed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS hmx_import_staging (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES hmx_import_batches(id) ON DELETE CASCADE,
    section TEXT NOT NULL, source_ref TEXT, record JSONB NOT NULL,
    conflicts JSONB NOT NULL DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','accepted','rejected','quoted','demoted')),
    modification_kind TEXT, decision_rationale TEXT, local_ref TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS hmx_import_ref_map (
    batch_id UUID NOT NULL REFERENCES hmx_import_batches(id) ON DELETE CASCADE,
    source_ref TEXT NOT NULL, local_ref TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (batch_id, source_ref)
);
CREATE INDEX IF NOT EXISTS idx_hmx_import_staging_pending
    ON hmx_import_staging (created_at, id) WHERE status='pending';
CREATE INDEX IF NOT EXISTS idx_hmx_import_staging_batch
    ON hmx_import_staging (batch_id, section, status);

CREATE TABLE IF NOT EXISTS hmx_analysis_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), export_id TEXT NOT NULL,
    export_intent TEXT NOT NULL, source JSONB NOT NULL DEFAULT '{}'::jsonb,
    privacy JSONB NOT NULL DEFAULT '{}'::jsonb, envelope JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS hmx_analysis_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES hmx_analysis_batches(id) ON DELETE CASCADE,
    section TEXT NOT NULL, source_ref TEXT, record JSONB NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_hmx_analysis_records_batch
    ON hmx_analysis_records (batch_id, section, created_at);

CREATE OR REPLACE FUNCTION hmx_pending_review() RETURNS JSONB AS $$
DECLARE records JSONB; grouped JSONB; total_count INT;
BEGIN
    SELECT COUNT(*) INTO total_count FROM hmx_import_staging WHERE status='pending';
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at,q.id),'[]'::jsonb)
    INTO records FROM (
        SELECT s.id,s.batch_id,s.section,s.source_ref,s.record,s.conflicts,s.metadata,
               s.created_at,b.export_id,b.export_intent,b.source
        FROM hmx_import_staging s JOIN hmx_import_batches b ON b.id=s.batch_id
        WHERE s.status='pending' ORDER BY s.created_at,s.id LIMIT 100
    ) q;
    SELECT COALESCE(jsonb_object_agg(code,count),'{}'::jsonb) INTO grouped FROM (
        SELECT COALESCE(conflict->>'code','none') code,COUNT(*) count
        FROM hmx_import_staging s
        LEFT JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_array_length(s.conflicts)=0 THEN '[{}]'::jsonb ELSE s.conflicts END
        ) conflict ON TRUE WHERE s.status='pending'
        GROUP BY COALESCE(conflict->>'code','none')
    ) counts;
    RETURN jsonb_build_object('total',total_count,'by_conflict',grouped,'records',records);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION hmx_pending_review_summary() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'count',COALESCE(SUM(count),0),
        'by_section',COALESCE(jsonb_object_agg(section,count),'{}'::jsonb)
    ) FROM (
        SELECT section,COUNT(*) count FROM hmx_import_staging
        WHERE status='pending' GROUP BY section
    ) q;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_attach_pending_review(p_context JSONB) RETURNS JSONB AS $$
    SELECT COALESCE(p_context,'{}'::jsonb)
        || jsonb_build_object('pending_import_review',hmx_pending_review_summary());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_promote_to_staged(
    p_analysis_id UUID,p_rationale TEXT
) RETURNS UUID AS $$
DECLARE
    analysis_row hmx_analysis_records%ROWTYPE;
    analysis_batch hmx_analysis_batches%ROWTYPE;
    staging_batch_id UUID; staging_id UUID; prepared JSONB;
BEGIN
    IF NULLIF(btrim(COALESCE(p_rationale,'')),'') IS NULL THEN
        RAISE EXCEPTION 'promotion rationale is required';
    END IF;
    SELECT * INTO analysis_row FROM hmx_analysis_records WHERE id=p_analysis_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'analysis record not found: %',p_analysis_id; END IF;
    SELECT * INTO analysis_batch FROM hmx_analysis_batches WHERE id=analysis_row.batch_id;
    prepared := analysis_row.record || jsonb_build_object(
        'provenance',COALESCE(analysis_row.record->'provenance','{}'::jsonb)
            || jsonb_build_object('acquisition_mode','imported_staged'),
        'metadata',COALESCE(analysis_row.record->'metadata','{}'::jsonb)
            || jsonb_build_object('hmx',COALESCE(analysis_row.record->'metadata'->'hmx','{}'::jsonb)
                || jsonb_build_object('promoted_from_analysis',p_analysis_id))
    );
    INSERT INTO hmx_import_batches
        (export_id,export_intent,strategy,source,privacy,envelope,metadata)
    VALUES (analysis_batch.export_id,analysis_batch.export_intent,'deliberative',
        analysis_batch.source,analysis_batch.privacy,analysis_batch.envelope,
        jsonb_build_object('promoted_from_analysis_batch',analysis_batch.id))
    RETURNING id INTO staging_batch_id;
    INSERT INTO hmx_import_staging (batch_id,section,source_ref,record,metadata)
    VALUES (staging_batch_id,analysis_row.section,analysis_row.source_ref,prepared,
        jsonb_build_object('promoted_from_analysis',p_analysis_id,
            'promotion_rationale',p_rationale)) RETURNING id INTO staging_id;
    RETURN staging_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_demote_to_analysis(
    p_staging_id UUID,p_rationale TEXT
) RETURNS UUID AS $$
DECLARE
    staging_row hmx_import_staging%ROWTYPE;
    staging_batch hmx_import_batches%ROWTYPE;
    analysis_batch_id UUID; analysis_id UUID; prepared JSONB;
BEGIN
    IF NULLIF(btrim(COALESCE(p_rationale,'')),'') IS NULL THEN
        RAISE EXCEPTION 'demotion rationale is required';
    END IF;
    SELECT * INTO staging_row FROM hmx_import_staging WHERE id=p_staging_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'staged record not found: %',p_staging_id; END IF;
    IF staging_row.status<>'pending' THEN
        RAISE EXCEPTION 'staged record is not pending: %',p_staging_id;
    END IF;
    SELECT * INTO staging_batch FROM hmx_import_batches WHERE id=staging_row.batch_id;
    prepared := staging_row.record || jsonb_build_object(
        'provenance',COALESCE(staging_row.record->'provenance','{}'::jsonb)
            || jsonb_build_object('acquisition_mode','analysis_only'),
        'metadata',COALESCE(staging_row.record->'metadata','{}'::jsonb)
            || jsonb_build_object('hmx',COALESCE(staging_row.record->'metadata'->'hmx','{}'::jsonb)
                || jsonb_build_object('demoted_from_staging',p_staging_id))
    );
    INSERT INTO hmx_analysis_batches
        (export_id,export_intent,source,privacy,envelope,metadata)
    VALUES (staging_batch.export_id,staging_batch.export_intent,staging_batch.source,
        staging_batch.privacy,staging_batch.envelope,
        jsonb_build_object('demoted_from_staging_batch',staging_batch.id))
    RETURNING id INTO analysis_batch_id;
    INSERT INTO hmx_analysis_records (batch_id,section,source_ref,record,metadata)
    VALUES (analysis_batch_id,staging_row.section,staging_row.source_ref,prepared,
        staging_row.metadata || jsonb_build_object('demoted_from_staging',p_staging_id,
            'demotion_rationale',p_rationale)) RETURNING id INTO analysis_id;
    UPDATE hmx_import_staging SET status='demoted',decision_rationale=p_rationale,
        reviewed_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE id=p_staging_id;
    UPDATE hmx_import_batches SET status=CASE WHEN EXISTS (
        SELECT 1 FROM hmx_import_staging
        WHERE batch_id=staging_row.batch_id AND status='pending'
    ) THEN 'pending' ELSE 'reviewed' END,updated_at=CURRENT_TIMESTAMP
    WHERE id=staging_row.batch_id;
    RETURN analysis_id;
END;
$$ LANGUAGE plpgsql;
