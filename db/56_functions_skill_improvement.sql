-- Durable, user-controlled self-improvement proposal lifecycle.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS skill_improvement_proposals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'applied', 'rejected')),
    name TEXT NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
    description TEXT NOT NULL,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'other',
    contexts TEXT[] NOT NULL DEFAULT ARRAY['chat', 'heartbeat']::TEXT[],
    bound_tools TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
    requires_tools TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
    mode TEXT NOT NULL DEFAULT 'create' CHECK (mode IN ('create', 'update')),
    rationale TEXT NOT NULL,
    confidence FLOAT NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    source_memory_ids UUID[] NOT NULL DEFAULT '{}'::UUID[],
    source_unit_ids UUID[] NOT NULL DEFAULT '{}'::UUID[],
    evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
    evidence_digest TEXT NOT NULL UNIQUE,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMPTZ,
    applied_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_skill_improvement_proposals_status_created
    ON skill_improvement_proposals (status, created_at DESC);

INSERT INTO config_defaults (key, value, description) VALUES
    ('skills.self_improvement.enabled', 'false'::jsonb, 'Opt in to background experience review that creates skill proposals; proposals are never auto-applied'),
    ('skills.self_improvement.interval_seconds', '604800'::jsonb, 'Minimum seconds between skill-improvement reviews'),
    ('skills.self_improvement.claim_timeout_seconds', '1800'::jsonb, 'Seconds before an interrupted review claim can be retried'),
    ('skills.self_improvement.lookback_days', '30'::jsonb, 'Recent experience window considered by skill-improvement review'),
    ('skills.self_improvement.evidence_limit', '30'::jsonb, 'Maximum raw conversation turns supplied to one skill-improvement review'),
    ('skills.self_improvement.min_units', '6'::jsonb, 'Minimum active raw turns required before skill-improvement review'),
    ('skills.self_improvement.min_sessions', '2'::jsonb, 'Minimum distinct sessions required before skill-improvement review'),
    ('skills.self_improvement.min_confidence', '0.8'::jsonb, 'Minimum model confidence accepted for a durable skill proposal'),
    ('llm.skill_improvement', 'null'::jsonb, 'Optional LLM override for skill-improvement review')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION claim_skill_improvement_review()
RETURNS BOOLEAN AS $$
DECLARE
    state_doc JSONB;
    last_completed TIMESTAMPTZ;
    claim_started TIMESTAMPTZ;
    interval_seconds FLOAT := COALESCE(get_config_float('skills.self_improvement.interval_seconds'), 604800);
    claim_timeout FLOAT := COALESCE(get_config_float('skills.self_improvement.claim_timeout_seconds'), 1800);
BEGIN
    IF NOT COALESCE(get_config_bool('skills.self_improvement.enabled'), FALSE)
       OR is_agent_terminated()
       OR NOT is_agent_configured()
       OR NOT is_init_complete()
       OR get_agent_consent_status() IS DISTINCT FROM 'consent'
       OR interval_seconds <= 0 THEN
        RETURN FALSE;
    END IF;

    INSERT INTO state (key, value)
    VALUES ('skill_improvement_state', '{}'::jsonb)
    ON CONFLICT (key) DO NOTHING;

    SELECT value INTO state_doc
    FROM state
    WHERE key = 'skill_improvement_state'
    FOR UPDATE;

    last_completed := NULLIF(state_doc->>'last_completed_at', '')::timestamptz;
    claim_started := NULLIF(state_doc->>'claim_started_at', '')::timestamptz;
    IF COALESCE((state_doc->>'in_progress')::boolean, FALSE)
       AND claim_started IS NOT NULL
       AND CURRENT_TIMESTAMP < claim_started + (claim_timeout || ' seconds')::interval THEN
        RETURN FALSE;
    END IF;
    IF last_completed IS NOT NULL
       AND CURRENT_TIMESTAMP < last_completed + (interval_seconds || ' seconds')::interval THEN
        RETURN FALSE;
    END IF;

    PERFORM set_state(
        'skill_improvement_state',
        state_doc || jsonb_build_object(
            'in_progress', TRUE,
            'claim_started_at', CURRENT_TIMESTAMP
        )
    );
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION load_skill_improvement_evidence()
RETURNS JSONB AS $$
DECLARE
    lookback_days INT := LEAST(GREATEST(COALESCE(get_config_int('skills.self_improvement.lookback_days'), 30), 1), 365);
    evidence_limit INT := LEAST(GREATEST(COALESCE(get_config_int('skills.self_improvement.evidence_limit'), 30), 1), 100);
    min_units INT := LEAST(GREATEST(COALESCE(get_config_int('skills.self_improvement.min_units'), 6), 2), 100);
    min_sessions INT := LEAST(GREATEST(COALESCE(get_config_int('skills.self_improvement.min_sessions'), 2), 2), 20);
    evidence JSONB;
    unit_count INT;
    session_count INT;
    memory_ids UUID[];
    unit_ids UUID[];
BEGIN
    WITH selected AS (
        SELECT s.id, s.session_id, s.turn_at,
               left(s.user_text, 1200) AS user_text,
               left(s.assistant_text, 1800) AS assistant_text,
               left(s.content, 3000) AS content
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.session_id IS NOT NULL
          AND s.turn_at >= CURRENT_TIMESTAMP - (lookback_days || ' days')::interval
        ORDER BY s.turn_at DESC, s.id
        LIMIT evidence_limit
    ), linked AS (
        SELECT COALESCE(array_agg(DISTINCT msu.memory_id ORDER BY msu.memory_id), '{}'::uuid[]) AS ids
        FROM memory_source_units msu
        WHERE msu.subconscious_unit_id IN (SELECT id FROM selected)
    )
    SELECT
        COALESCE(jsonb_agg(to_jsonb(selected) ORDER BY selected.turn_at, selected.id), '[]'::jsonb),
        count(*)::int,
        count(DISTINCT selected.session_id)::int,
        COALESCE(array_agg(selected.id ORDER BY selected.turn_at, selected.id), '{}'::uuid[]),
        (SELECT ids FROM linked)
    INTO evidence, unit_count, session_count, unit_ids, memory_ids
    FROM selected;

    RETURN jsonb_build_object(
        'eligible', unit_count >= min_units AND session_count >= min_sessions,
        'reason', CASE
            WHEN unit_count < min_units THEN 'insufficient_units'
            WHEN session_count < min_sessions THEN 'insufficient_sessions'
            ELSE 'ready'
        END,
        'unit_count', unit_count,
        'session_count', session_count,
        'source_unit_ids', to_jsonb(unit_ids),
        'source_memory_ids', to_jsonb(memory_ids),
        'turns', evidence
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION create_skill_improvement_proposal(
    p_proposal JSONB,
    p_evidence JSONB,
    p_evidence_digest TEXT
) RETURNS JSONB AS $$
DECLARE
    proposal_id UUID;
    source_units UUID[];
    source_memories UUID[];
    proposal_confidence FLOAT;
BEGIN
    IF jsonb_typeof(p_proposal) <> 'object' THEN
        RAISE EXCEPTION 'skill proposal must be a JSON object';
    END IF;
    IF COALESCE(p_proposal->>'name', '') !~ '^[a-z0-9][a-z0-9_-]{1,63}$' THEN
        RAISE EXCEPTION 'invalid skill proposal name';
    END IF;
    IF length(btrim(COALESCE(p_proposal->>'description', ''))) = 0
       OR length(btrim(COALESCE(p_proposal->>'content', ''))) < 120
       OR length(btrim(COALESCE(p_proposal->>'rationale', ''))) = 0 THEN
        RAISE EXCEPTION 'skill proposal description, substantive content, and rationale are required';
    END IF;
    proposal_confidence := NULLIF(p_proposal->>'confidence', '')::float;
    IF proposal_confidence IS NULL OR proposal_confidence < 0 OR proposal_confidence > 1 THEN
        RAISE EXCEPTION 'skill proposal confidence must be between 0 and 1';
    END IF;
    IF COALESCE(p_proposal->>'mode', 'create') NOT IN ('create', 'update') THEN
        RAISE EXCEPTION 'skill proposal mode must be create or update';
    END IF;

    SELECT COALESCE(array_agg(value::uuid), '{}'::uuid[])
    INTO source_units
    FROM jsonb_array_elements_text(COALESCE(p_evidence->'source_unit_ids', '[]'::jsonb));
    SELECT COALESCE(array_agg(value::uuid), '{}'::uuid[])
    INTO source_memories
    FROM jsonb_array_elements_text(COALESCE(p_evidence->'source_memory_ids', '[]'::jsonb));
    IF cardinality(source_units) = 0 THEN
        RAISE EXCEPTION 'skill proposal evidence must include source unit ids';
    END IF;

    INSERT INTO skill_improvement_proposals (
        name, description, content, category, contexts, bound_tools,
        requires_tools, mode, rationale, confidence, source_memory_ids,
        source_unit_ids, evidence, evidence_digest
    ) VALUES (
        p_proposal->>'name',
        p_proposal->>'description',
        p_proposal->>'content',
        COALESCE(NULLIF(p_proposal->>'category', ''), 'other'),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'contexts', '["chat", "heartbeat"]'::jsonb))),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'bound_tools', '[]'::jsonb))),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'requires_tools', p_proposal->'bound_tools', '[]'::jsonb))),
        COALESCE(p_proposal->>'mode', 'create'),
        p_proposal->>'rationale',
        proposal_confidence,
        source_memories,
        source_units,
        p_evidence,
        p_evidence_digest
    )
    ON CONFLICT (evidence_digest) DO NOTHING
    RETURNING id INTO proposal_id;

    IF proposal_id IS NULL THEN
        SELECT id INTO proposal_id
        FROM skill_improvement_proposals
        WHERE evidence_digest = p_evidence_digest;
        RETURN jsonb_build_object('created', FALSE, 'proposal_id', proposal_id, 'reason', 'duplicate_evidence');
    END IF;
    RETURN jsonb_build_object('created', TRUE, 'proposal_id', proposal_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_on_demand_skill_proposal(
    p_proposal JSONB,
    p_evidence JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    proposal_id UUID;
    source_units UUID[];
    source_memories UUID[];
    proposal_confidence FLOAT;
    evidence_doc JSONB := jsonb_build_object(
        'origin', 'on_demand',
        'kind', 'skill_proposal',
        'created_at', CURRENT_TIMESTAMP
    ) || COALESCE(p_evidence, '{}'::jsonb);
    generated_digest TEXT;
    proposal_fingerprint JSONB;
BEGIN
    IF jsonb_typeof(p_proposal) <> 'object' THEN
        RAISE EXCEPTION 'skill proposal must be a JSON object';
    END IF;
    IF COALESCE(p_proposal->>'name', '') !~ '^[a-z0-9][a-z0-9_-]{1,63}$' THEN
        RAISE EXCEPTION 'invalid skill proposal name';
    END IF;
    IF length(btrim(COALESCE(p_proposal->>'description', ''))) = 0
       OR length(btrim(COALESCE(p_proposal->>'content', ''))) < 120
       OR length(btrim(COALESCE(p_proposal->>'rationale', ''))) = 0 THEN
        RAISE EXCEPTION 'skill proposal description, substantive content, and rationale are required';
    END IF;

    proposal_confidence := COALESCE(NULLIF(p_proposal->>'confidence', '')::float, 0.75);
    IF proposal_confidence < 0 OR proposal_confidence > 1 THEN
        RAISE EXCEPTION 'skill proposal confidence must be between 0 and 1';
    END IF;
    IF COALESCE(p_proposal->>'mode', 'create') NOT IN ('create', 'update') THEN
        RAISE EXCEPTION 'skill proposal mode must be create or update';
    END IF;

    SELECT COALESCE(array_agg(value::uuid), '{}'::uuid[])
    INTO source_units
    FROM jsonb_array_elements_text(COALESCE(evidence_doc->'source_unit_ids', '[]'::jsonb));
    SELECT COALESCE(array_agg(value::uuid), '{}'::uuid[])
    INTO source_memories
    FROM jsonb_array_elements_text(COALESCE(evidence_doc->'source_memory_ids', '[]'::jsonb));

    proposal_fingerprint := jsonb_build_object(
        'origin', COALESCE(evidence_doc->>'origin', 'on_demand'),
        'need', COALESCE(evidence_doc->>'need', ''),
        'name', p_proposal->>'name',
        'mode', COALESCE(p_proposal->>'mode', 'create'),
        'description', p_proposal->>'description',
        'content_hash', encode(digest(convert_to(p_proposal->>'content', 'UTF8'), 'sha256'), 'hex')
    );
    generated_digest := COALESCE(
        NULLIF(evidence_doc->>'evidence_digest', ''),
        'on_demand:' || encode(digest(convert_to(proposal_fingerprint::text, 'UTF8'), 'sha256'), 'hex')
    );
    evidence_doc := evidence_doc || jsonb_build_object('evidence_digest', generated_digest);

    INSERT INTO skill_improvement_proposals (
        name, description, content, category, contexts, bound_tools,
        requires_tools, mode, rationale, confidence, source_memory_ids,
        source_unit_ids, evidence, evidence_digest
    ) VALUES (
        p_proposal->>'name',
        p_proposal->>'description',
        p_proposal->>'content',
        COALESCE(NULLIF(p_proposal->>'category', ''), 'other'),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'contexts', '["chat", "heartbeat"]'::jsonb))),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'bound_tools', '[]'::jsonb))),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_proposal->'requires_tools', p_proposal->'bound_tools', '[]'::jsonb))),
        COALESCE(p_proposal->>'mode', 'create'),
        p_proposal->>'rationale',
        proposal_confidence,
        source_memories,
        source_units,
        evidence_doc,
        generated_digest
    )
    ON CONFLICT (evidence_digest) DO NOTHING
    RETURNING id INTO proposal_id;

    IF proposal_id IS NULL THEN
        SELECT id INTO proposal_id
        FROM skill_improvement_proposals
        WHERE evidence_digest = generated_digest;
        RETURN jsonb_build_object('created', FALSE, 'proposal_id', proposal_id, 'reason', 'duplicate_evidence');
    END IF;
    RETURN jsonb_build_object('created', TRUE, 'proposal_id', proposal_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_skill_improvement_review(
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    merged JSONB;
BEGIN
    merged := COALESCE(get_state('skill_improvement_state'), '{}'::jsonb)
        || jsonb_build_object(
            'in_progress', FALSE,
            'claim_started_at', NULL,
            'last_completed_at', CURRENT_TIMESTAMP,
            'last_result', COALESCE(p_result, '{}'::jsonb)
        );
    PERFORM set_state('skill_improvement_state', merged);
    RETURN merged;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION transition_skill_improvement_proposal(
    p_id UUID,
    p_action TEXT,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    changed skill_improvement_proposals%ROWTYPE;
BEGIN
    IF p_action = 'apply' THEN
        UPDATE skill_improvement_proposals
        SET status = 'applied', applied_at = CURRENT_TIMESTAMP,
            reviewed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP,
            last_error = NULL
        WHERE id = p_id AND status = 'pending'
        RETURNING * INTO changed;
    ELSIF p_action = 'reject' THEN
        UPDATE skill_improvement_proposals
        SET status = 'rejected', reviewed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP, last_error = NULL
        WHERE id = p_id AND status = 'pending'
        RETURNING * INTO changed;
    ELSIF p_action = 'reopen' THEN
        UPDATE skill_improvement_proposals
        SET status = 'pending', reviewed_at = NULL,
            updated_at = CURRENT_TIMESTAMP, last_error = NULL
        WHERE id = p_id AND status = 'rejected'
        RETURNING * INTO changed;
    ELSIF p_action = 'error' THEN
        UPDATE skill_improvement_proposals
        SET last_error = NULLIF(p_error, ''), updated_at = CURRENT_TIMESTAMP
        WHERE id = p_id AND status = 'pending'
        RETURNING * INTO changed;
    ELSE
        RAISE EXCEPTION 'unknown skill proposal action: %', p_action;
    END IF;

    IF changed.id IS NULL THEN
        RAISE EXCEPTION 'skill proposal % cannot transition with action % from its current state', p_id, p_action;
    END IF;
    RETURN to_jsonb(changed);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION skill_improvement_pending_summary()
RETURNS JSONB AS $$
BEGIN
    RETURN jsonb_build_object(
        'count', (
            SELECT count(*) FROM skill_improvement_proposals WHERE status = 'pending'
        ),
        'proposals', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', p.id,
                'name', p.name,
                'description', p.description,
                'mode', p.mode,
                'confidence', p.confidence,
                'created_at', p.created_at
            ) ORDER BY p.created_at, p.id)
            FROM (
                SELECT * FROM skill_improvement_proposals
                WHERE status = 'pending'
                ORDER BY created_at, id
                LIMIT 5
            ) p
        ), '[]'::jsonb),
        'next_step', 'Use the skill-authoring skill to list_skill_proposals, then explicitly approve review_skill_proposal apply/reject.'
    );
END;
$$ LANGUAGE plpgsql STABLE;
