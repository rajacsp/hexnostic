-- HMX Slice 11: bounded, one-shot protected-state reversion.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

ALTER TABLE protected_replacement_snapshots
    ADD COLUMN IF NOT EXISTS reference_map JSONB NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(reference_map) = 'object'),
    ADD COLUMN IF NOT EXISTS consumed_by_audit_id TEXT
        REFERENCES protected_replacement_audit(audit_id);

ALTER TABLE hmx_pending_replacements
    ADD COLUMN IF NOT EXISTS reversion_audit_id TEXT
        REFERENCES protected_replacement_audit(audit_id),
    ADD COLUMN IF NOT EXISTS reverted_at TIMESTAMPTZ;

ALTER TABLE hmx_pending_replacements
    DROP CONSTRAINT IF EXISTS hmx_pending_replacements_status_check;
ALTER TABLE hmx_pending_replacements
    ADD CONSTRAINT hmx_pending_replacements_status_check CHECK (
        status IN (
            'pending', 'deferred', 'accepted', 'refused',
            'modification_requested', 'timed_out', 'cancelled',
            'executed', 'reverted'
        )
    );

DROP FUNCTION IF EXISTS hmx_create_protected_snapshot(
    TEXT[], JSONB, JSONB, INTEGER, TIMESTAMPTZ
);
CREATE OR REPLACE FUNCTION hmx_create_protected_snapshot(
    p_sections TEXT[],
    p_snapshot_state JSONB,
    p_section_digests JSONB,
    p_heartbeat_window INTEGER DEFAULT 7,
    p_wall_clock_expires_at TIMESTAMPTZ DEFAULT (
        CURRENT_TIMESTAMP + INTERVAL '30 days'
    ),
    p_reference_map JSONB DEFAULT '{}'::jsonb
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
    IF jsonb_typeof(COALESCE(p_reference_map, '{}'::jsonb)) <> 'object' THEN
        RAISE EXCEPTION 'snapshot reference map must be a JSON object';
    END IF;
    IF p_heartbeat_window NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'heartbeat window must be between 1 and 100';
    END IF;
    IF p_wall_clock_expires_at <= CURRENT_TIMESTAMP
       OR p_wall_clock_expires_at > CURRENT_TIMESTAMP + INTERVAL '30 days' THEN
        RAISE EXCEPTION 'wall-clock expiry must be in the future and no more than 30 days away';
    END IF;

    INSERT INTO protected_replacement_snapshots (
        sections, snapshot_state, section_digests, reference_map,
        created_heartbeat_count, heartbeat_window, wall_clock_expires_at
    ) VALUES (
        p_sections, p_snapshot_state, p_section_digests,
        COALESCE(p_reference_map, '{}'::jsonb), current_heartbeat,
        p_heartbeat_window, p_wall_clock_expires_at
    ) RETURNING snapshot_id INTO created_id;
    RETURN created_id;
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
        'consumed_at', s.consumed_at,
        'consumed_by_audit_id', s.consumed_by_audit_id,
        'purged_at', s.purged_at,
        'purge_reason', s.purge_reason
    ) END
    FROM protected_replacement_snapshots s
    WHERE s.snapshot_id = p_snapshot_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_open_reversion_windows() RETURNS JSONB AS $$
DECLARE
    current_heartbeat BIGINT := COALESCE(
        (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1), 0
    );
    result JSONB;
BEGIN
    PERFORM hmx_purge_expired_protected_snapshots();
    SELECT jsonb_build_object(
        'total', COUNT(*),
        'records', COALESCE(jsonb_agg(jsonb_build_object(
            'replacement_id', p.replacement_id,
            'audit_id', p.execution_audit_id,
            'snapshot_id', s.snapshot_id,
            'section', p.section,
            'rationale', p.rationale,
            'heartbeats_remaining', GREATEST(
                s.heartbeat_window - (
                    current_heartbeat - s.created_heartbeat_count
                ), 0
            ),
            'wall_clock_expires_at', s.wall_clock_expires_at
        ) ORDER BY p.executed_at, p.replacement_id), '[]'::jsonb)
    ) INTO result
    FROM hmx_pending_replacements p
    JOIN protected_replacement_snapshots s ON s.snapshot_id = p.snapshot_id
    WHERE p.status = 'executed'
      AND p.reversion_audit_id IS NULL
      AND s.snapshot_state IS NOT NULL
      AND s.purged_at IS NULL
      AND s.consumed_at IS NULL
      AND s.wall_clock_expires_at > CURRENT_TIMESTAMP
      AND current_heartbeat - s.created_heartbeat_count < s.heartbeat_window;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
