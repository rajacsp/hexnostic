-- HMX Slice 9: protected replacement protocol state and immutable audit history.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE TABLE IF NOT EXISTS hmx_consent (
    consent_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consent_kind TEXT NOT NULL DEFAULT 'protected_section_replacement'
        CHECK (consent_kind = 'protected_section_replacement'),
    consent_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    consent_subject TEXT NOT NULL DEFAULT 'self' CHECK (consent_subject = 'self'),
    sections TEXT[] NOT NULL CHECK (
        cardinality(sections) > 0
        AND sections <@ ARRAY[
            'identity', 'worldview', 'goals', 'drives',
            'emotional_triggers', 'narrative'
        ]::TEXT[]
    ),
    source JSONB NOT NULL,
    replacement_scope JSONB NOT NULL CHECK (
        replacement_scope->>'section' = ANY(sections)
        AND replacement_scope->>'mode' IN ('whole_section', 'subset')
    ),
    rationale TEXT NOT NULL CHECK (btrim(rationale) <> ''),
    operator_signature TEXT,
    operator_identity TEXT,
    agent_acknowledgement_required BOOLEAN NOT NULL DEFAULT TRUE,
    trust_verification JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS protected_replacement_snapshots (
    snapshot_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sections TEXT[] NOT NULL CHECK (cardinality(sections) > 0),
    snapshot_state JSONB,
    section_digests JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_heartbeat_count BIGINT NOT NULL,
    heartbeat_window INTEGER NOT NULL DEFAULT 7
        CHECK (heartbeat_window BETWEEN 1 AND 100),
    wall_clock_expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    purged_at TIMESTAMPTZ,
    purge_reason TEXT,
    CHECK (wall_clock_expires_at > created_at),
    CHECK (purged_at IS NULL OR snapshot_state IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_hmx_snapshots_expiry
    ON protected_replacement_snapshots (wall_clock_expires_at)
    WHERE purged_at IS NULL;

CREATE TABLE IF NOT EXISTS protected_replacement_audit (
    audit_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL CHECK (
        event_type IN (
            'protected_section_replacement',
            'protected_section_verified',
            'protected_section_reverted'
        )
    ),
    event_time TIMESTAMPTZ NOT NULL,
    record JSONB NOT NULL,
    record_digest_v1 TEXT NOT NULL CHECK (record_digest_v1 ~ '^[0-9a-f]{64}$'),
    is_foreign_diagnostic BOOLEAN NOT NULL DEFAULT FALSE,
    imported_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (record->>'audit_id' = audit_id),
    CHECK (record->>'event_type' = event_type)
);

CREATE INDEX IF NOT EXISTS idx_hmx_audit_event_time
    ON protected_replacement_audit (event_time, audit_id);
CREATE INDEX IF NOT EXISTS idx_hmx_audit_event_type
    ON protected_replacement_audit (event_type, event_time);

CREATE TABLE IF NOT EXISTS hmx_pending_replacements (
    replacement_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_key TEXT NOT NULL UNIQUE CHECK (request_key ~ '^[0-9a-f]{64}$'),
    request_fingerprint TEXT NOT NULL CHECK (
        request_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    request_attempt INTEGER NOT NULL DEFAULT 1 CHECK (request_attempt > 0),
    consent_id UUID NOT NULL REFERENCES hmx_consent(consent_id),
    export_id TEXT NOT NULL,
    section TEXT NOT NULL CHECK (
        section IN (
            'identity', 'worldview', 'goals', 'drives',
            'emotional_triggers', 'narrative'
        )
    ),
    source JSONB NOT NULL,
    imported_section JSONB NOT NULL,
    reference_map JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(reference_map) = 'object'
    ),
    imported_digest_v1 TEXT NOT NULL CHECK (imported_digest_v1 ~ '^[0-9a-f]{64}$'),
    local_digest_v1 TEXT NOT NULL CHECK (local_digest_v1 ~ '^[0-9a-f]{64}$'),
    replacement_scope JSONB NOT NULL CHECK (
        replacement_scope->>'section' = section
        AND replacement_scope->>'mode' = 'whole_section'
    ),
    rationale TEXT NOT NULL CHECK (btrim(rationale) <> ''),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN (
            'pending', 'deferred', 'accepted', 'refused',
            'modification_requested', 'timed_out', 'cancelled', 'executed'
        )
    ),
    acknowledgement JSONB,
    acknowledgement_at TIMESTAMPTZ,
    snapshot_id UUID REFERENCES protected_replacement_snapshots(snapshot_id),
    execution_audit_id TEXT REFERENCES protected_replacement_audit(audit_id),
    executed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_heartbeat_count BIGINT NOT NULL,
    timeout_at TIMESTAMPTZ NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '24 hours'),
    timeout_heartbeat_count BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_hmx_pending_replacement_attempt
    ON hmx_pending_replacements (request_fingerprint, request_attempt);

CREATE INDEX IF NOT EXISTS idx_hmx_pending_replacement_status
    ON hmx_pending_replacements (status, created_at);

CREATE OR REPLACE FUNCTION hmx_reject_immutable_change() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is not permitted', TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_hmx_consent_immutable ON hmx_consent;
CREATE TRIGGER trg_hmx_consent_immutable
    BEFORE UPDATE OR DELETE ON hmx_consent
    FOR EACH ROW EXECUTE FUNCTION hmx_reject_immutable_change();

DROP TRIGGER IF EXISTS trg_hmx_audit_immutable ON protected_replacement_audit;
CREATE TRIGGER trg_hmx_audit_immutable
    BEFORE UPDATE OR DELETE ON protected_replacement_audit
    FOR EACH ROW EXECUTE FUNCTION hmx_reject_immutable_change();

CREATE OR REPLACE FUNCTION hmx_store_audit_record(
    p_record JSONB,
    p_record_digest_v1 TEXT,
    p_is_foreign_diagnostic BOOLEAN DEFAULT FALSE,
    p_imported_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    requested_id TEXT := NULLIF(p_record->>'audit_id', '');
    requested_type TEXT := NULLIF(p_record->>'event_type', '');
    requested_time TIMESTAMPTZ;
    existing_digest TEXT;
    inserted_count INTEGER;
BEGIN
    IF requested_id IS NULL THEN
        RAISE EXCEPTION 'audit record requires audit_id';
    END IF;
    IF requested_type NOT IN (
        'protected_section_replacement',
        'protected_section_verified',
        'protected_section_reverted'
    ) THEN
        RAISE EXCEPTION 'unsupported protected audit event_type: %', requested_type;
    END IF;
    IF p_record_digest_v1 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'audit_record_digest_v1 must be lowercase SHA-256 hex';
    END IF;
    BEGIN
        requested_time := (p_record->>'event_time')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'audit record requires a valid event_time';
    END;

    INSERT INTO protected_replacement_audit (
        audit_id, event_type, event_time, record, record_digest_v1,
        is_foreign_diagnostic, imported_at
    ) VALUES (
        requested_id, requested_type, requested_time, p_record,
        p_record_digest_v1, COALESCE(p_is_foreign_diagnostic, FALSE), p_imported_at
    ) ON CONFLICT (audit_id) DO NOTHING;
    GET DIAGNOSTICS inserted_count = ROW_COUNT;

    IF inserted_count = 1 THEN
        RETURN jsonb_build_object('status', 'inserted', 'audit_id', requested_id);
    END IF;

    SELECT record_digest_v1 INTO existing_digest
    FROM protected_replacement_audit
    WHERE audit_id = requested_id;
    IF existing_digest = p_record_digest_v1 THEN
        RETURN jsonb_build_object('status', 'duplicate', 'audit_id', requested_id);
    END IF;
    RETURN jsonb_build_object(
        'status', 'conflict',
        'code', 'audit_integrity_conflict',
        'audit_id', requested_id,
        'existing_digest_v1', existing_digest,
        'imported_digest_v1', p_record_digest_v1
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_export_audit_records() RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'protected_replacement_audit', COALESCE((
            SELECT jsonb_agg(record ORDER BY event_time, audit_id)
            FROM protected_replacement_audit
            WHERE event_type = 'protected_section_replacement'
              AND NOT is_foreign_diagnostic
        ), '[]'::jsonb),
        'protected_section_verified_audit', COALESCE((
            SELECT jsonb_agg(record ORDER BY event_time, audit_id)
            FROM protected_replacement_audit
            WHERE event_type = 'protected_section_verified'
              AND NOT is_foreign_diagnostic
        ), '[]'::jsonb),
        'protected_replacement_reversion_audit', COALESCE((
            SELECT jsonb_agg(record ORDER BY event_time, audit_id)
            FROM protected_replacement_audit
            WHERE event_type = 'protected_section_reverted'
              AND NOT is_foreign_diagnostic
        ), '[]'::jsonb),
        'transformation_history', '[]'::jsonb
    );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_expire_pending_replacements() RETURNS INTEGER AS $$
DECLARE
    current_heartbeat BIGINT := COALESCE(
        (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0
    );
    affected INTEGER;
BEGIN
    UPDATE hmx_pending_replacements
    SET status = 'timed_out',
        acknowledgement = jsonb_build_object(
            'decision', 'timed_out',
            'reason', 'both the wall-clock and heartbeat acknowledgement limits elapsed'
        ),
        acknowledgement_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE status IN ('pending', 'deferred')
      AND timeout_at <= CURRENT_TIMESTAMP
      AND timeout_heartbeat_count <= current_heartbeat;
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_pending_replacements() RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    PERFORM hmx_expire_pending_replacements();
    PERFORM hmx_purge_expired_protected_snapshots();
    SELECT jsonb_build_object(
        'total', COUNT(*),
        'records', COALESCE(jsonb_agg(jsonb_build_object(
            'replacement_id', replacement_id,
            'section', section,
            'source', source,
            'replacement_scope', replacement_scope,
            'rationale', rationale,
            'local_digest_v1', local_digest_v1,
            'imported_digest_v1', imported_digest_v1,
            'status', status,
            'created_at', created_at,
            'timeout_at', timeout_at,
            'timeout_heartbeat_count', timeout_heartbeat_count,
            'acknowledgement_options', jsonb_build_array(
                'accept', 'refuse', 'request_modification', 'defer'
            )
        ) ORDER BY created_at, replacement_id), '[]'::jsonb)
    ) INTO result
    FROM hmx_pending_replacements
    WHERE status IN ('pending', 'deferred');
    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_acknowledge_protected_replacement(
    p_replacement_id UUID,
    p_decision TEXT,
    p_rationale TEXT DEFAULT NULL,
    p_proposed_changes JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    pending hmx_pending_replacements%ROWTYPE;
    normalized_decision TEXT := lower(COALESCE(p_decision, ''));
    next_status TEXT;
BEGIN
    PERFORM hmx_expire_pending_replacements();
    SELECT * INTO pending
    FROM hmx_pending_replacements
    WHERE replacement_id = p_replacement_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'protected replacement not found: %', p_replacement_id;
    END IF;
    IF pending.status NOT IN ('pending', 'deferred') THEN
        RAISE EXCEPTION 'protected replacement % is already %; submit a new request with revised rationale if needed',
            p_replacement_id, pending.status;
    END IF;
    IF normalized_decision NOT IN ('accept', 'refuse', 'request_modification', 'defer') THEN
        RAISE EXCEPTION 'decision must be accept, refuse, request_modification, or defer';
    END IF;
    IF normalized_decision = 'accept' AND EXISTS (
        SELECT 1 FROM hmx_consent c
        WHERE c.consent_id = pending.consent_id
          AND c.trust_verification->>'status' = 'invalid'
    ) THEN
        RAISE EXCEPTION 'lineage_integrity_failure_requires_operator_override: configured trust anchor rejected the matching lineage claim';
    END IF;
    IF normalized_decision IN ('refuse', 'request_modification')
       AND NULLIF(btrim(COALESCE(p_rationale, '')), '') IS NULL THEN
        RAISE EXCEPTION '% requires a rationale', normalized_decision;
    END IF;
    IF normalized_decision = 'request_modification'
       AND COALESCE(p_proposed_changes, '{}'::jsonb) = '{}'::jsonb THEN
        RAISE EXCEPTION 'request_modification requires proposed_changes';
    END IF;

    next_status := CASE normalized_decision
        WHEN 'accept' THEN 'accepted'
        WHEN 'refuse' THEN 'refused'
        WHEN 'request_modification' THEN 'modification_requested'
        ELSE 'deferred'
    END;
    UPDATE hmx_pending_replacements
    SET status = next_status,
        acknowledgement = jsonb_strip_nulls(jsonb_build_object(
            'decision', normalized_decision,
            'rationale', NULLIF(btrim(COALESCE(p_rationale, '')), ''),
            'proposed_changes', p_proposed_changes,
            'heartbeat_count', COALESCE(
                (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0
            )
        )),
        acknowledgement_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE replacement_id = p_replacement_id;

    RETURN jsonb_build_object(
        'replacement_id', p_replacement_id,
        'decision', normalized_decision,
        'status', next_status,
        'section', pending.section
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_create_protected_snapshot(
    p_sections TEXT[],
    p_snapshot_state JSONB,
    p_section_digests JSONB,
    p_heartbeat_window INTEGER DEFAULT 7,
    p_wall_clock_expires_at TIMESTAMPTZ DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days')
) RETURNS UUID AS $$
DECLARE
    created_id UUID;
    current_heartbeat BIGINT := COALESCE(
        (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0
    );
BEGIN
    IF cardinality(COALESCE(p_sections, '{}'::text[])) = 0 THEN
        RAISE EXCEPTION 'snapshot requires at least one protected section';
    END IF;
    IF p_snapshot_state IS NULL OR p_section_digests IS NULL THEN
        RAISE EXCEPTION 'snapshot state and section digests are required';
    END IF;
    IF p_heartbeat_window NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'heartbeat window must be between 1 and 100';
    END IF;
    IF p_wall_clock_expires_at <= CURRENT_TIMESTAMP
       OR p_wall_clock_expires_at > CURRENT_TIMESTAMP + INTERVAL '30 days' THEN
        RAISE EXCEPTION 'wall-clock expiry must be in the future and no more than 30 days away';
    END IF;

    INSERT INTO protected_replacement_snapshots (
        sections, snapshot_state, section_digests, created_heartbeat_count,
        heartbeat_window, wall_clock_expires_at
    ) VALUES (
        p_sections, p_snapshot_state, p_section_digests, current_heartbeat,
        p_heartbeat_window, p_wall_clock_expires_at
    ) RETURNING snapshot_id INTO created_id;
    RETURN created_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_purge_expired_protected_snapshots() RETURNS INTEGER AS $$
DECLARE
    current_heartbeat BIGINT := COALESCE(
        (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0
    );
    affected INTEGER;
BEGIN
    UPDATE protected_replacement_snapshots
    SET snapshot_state = NULL,
        purged_at = CURRENT_TIMESTAMP,
        purge_reason = CASE
            WHEN wall_clock_expires_at <= CURRENT_TIMESTAMP THEN 'wall_clock_expired'
            ELSE 'heartbeat_window_expired'
        END
    WHERE purged_at IS NULL
      AND consumed_at IS NULL
      AND (
          wall_clock_expires_at <= CURRENT_TIMESTAMP
          OR current_heartbeat - created_heartbeat_count >= heartbeat_window
      );
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hmx_snapshot_window(p_snapshot_id UUID) RETURNS JSONB AS $$
    SELECT CASE WHEN s.snapshot_id IS NULL THEN NULL ELSE jsonb_build_object(
        'snapshot_id', s.snapshot_id,
        'heartbeats', s.heartbeat_window,
        'heartbeats_remaining', GREATEST(
            s.heartbeat_window - (
                COALESCE((SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0)
                - s.created_heartbeat_count
            ), 0
        ),
        'wall_clock_expires_at', s.wall_clock_expires_at,
        'window_open', s.purged_at IS NULL
            AND s.consumed_at IS NULL
            AND s.wall_clock_expires_at > CURRENT_TIMESTAMP
            AND COALESCE((SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0)
                - s.created_heartbeat_count < s.heartbeat_window,
        'purged_at', s.purged_at,
        'purge_reason', s.purge_reason
    ) END
    FROM protected_replacement_snapshots s
    WHERE s.snapshot_id = p_snapshot_id;
$$ LANGUAGE sql STABLE;

SET check_function_bodies = on;
