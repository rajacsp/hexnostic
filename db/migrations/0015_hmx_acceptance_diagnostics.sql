-- HMX acceptance audit: report protected history from the unified audit ledger.
-- Baseline mirror: db/48_functions_memory_exchange.sql
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION hexis_instance_is_empty() RETURNS JSONB AS $$
DECLARE
    blockers JSONB := '[]'::jsonb;
    details JSONB;
    row_count BIGINT;
    graph_count BIGINT := 0;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'kind', 'protected_memory',
        'id', m.id,
        'type', m.type,
        'acquisition_mode', COALESCE(m.metadata#>>'{provenance,acquisition_mode}', 'missing')
    )), '[]'::jsonb)
    INTO details
    FROM memories m
    WHERE m.type IN ('worldview', 'goal')
      AND COALESCE(m.metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
    blockers := blockers || details;

    SELECT count(*) INTO row_count
    FROM emotional_triggers
    WHERE COALESCE(metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
    IF row_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'emotional_triggers', 'count', row_count,
            'reason', 'emotional trigger provenance is not bootstrap'
        ));
    END IF;

    SELECT count(*) INTO row_count
    FROM drives
    WHERE COALESCE(metadata#>>'{provenance,acquisition_mode}', 'missing') <> 'bootstrap';
    IF row_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'experienced_drive_state', 'count', row_count
        ));
    END IF;

    BEGIN
        SELECT replace(n::text, '"', '')::bigint INTO graph_count
        FROM ag_catalog.cypher('memory_graph', $q$
            MATCH (n)
            WHERE n:SelfNode OR n:LifeChapterNode OR n:TurningPointNode
               OR n:NarrativeThreadNode OR n:ValueConflictNode
            RETURN count(n)
        $q$) AS (n ag_catalog.agtype);
    EXCEPTION WHEN OTHERS THEN
        graph_count := 0;
    END;
    IF graph_count > 0 THEN
        blockers := blockers || jsonb_build_array(jsonb_build_object(
            'kind', 'identity_or_narrative_graph', 'count', graph_count
        ));
    END IF;

    IF to_regclass('public.protected_replacement_audit') IS NOT NULL THEN
        EXECUTE $query$
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'kind', 'protected_audit',
                'event_type', event_type,
                'foreign_diagnostic', is_foreign_diagnostic,
                'count', count
            ) ORDER BY event_type, is_foreign_diagnostic), '[]'::jsonb)
            FROM (
                SELECT event_type, is_foreign_diagnostic, count(*) AS count
                FROM protected_replacement_audit
                GROUP BY event_type, is_foreign_diagnostic
            ) audit_counts
        $query$ INTO details;
        blockers := blockers || details;
    END IF;

    IF to_regclass('public.hmx_consent') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM hmx_consent' INTO row_count;
        IF row_count > 0 THEN
            blockers := blockers || jsonb_build_array(jsonb_build_object(
                'kind', 'protected_consent', 'count', row_count
            ));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'is_empty', jsonb_array_length(blockers) = 0,
        'state', CASE WHEN jsonb_array_length(blockers) = 0 THEN 'empty' ELSE 'active' END,
        'blockers', blockers
    );
END;
$$ LANGUAGE plpgsql STABLE;

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
