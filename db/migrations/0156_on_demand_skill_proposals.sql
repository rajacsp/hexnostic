-- Let the agent create reviewable skill proposals as soon as it notices a
-- reusable capability gap. Applying the proposal still requires explicit review.

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
