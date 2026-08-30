-- Approved user-model claims become prompt-consumable context through
-- DB-owned selection and rendering. Pending/rejected/superseded claims stay
-- review-surface data, not prompt lore.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION get_approved_user_model_context(
    p_limit INT DEFAULT 12
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', c.id::text,
        'claim_key', c.claim_key,
        'category', c.category,
        'claim', c.claim,
        'confidence', c.confidence,
        'importance', c.importance,
        'evidence_count', c.evidence_count,
        'evidence_refs', c.evidence_refs,
        'last_evidence_at', c.last_evidence_at
    ) ORDER BY c.importance DESC, c.last_evidence_at DESC NULLS LAST, c.updated_at DESC), '[]'::jsonb)
    FROM (
        SELECT *
        FROM user_model_claims
        WHERE status = 'active'
          AND review_status = 'approved'
        ORDER BY importance DESC, last_evidence_at DESC NULLS LAST, updated_at DESC
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 50)
    ) c;
$$;

CREATE OR REPLACE FUNCTION render_user_model_context(p_claims jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    claims jsonb := CASE WHEN jsonb_typeof(p_claims) = 'array' THEN p_claims ELSE '[]'::jsonb END;
BEGIN
    IF jsonb_array_length(claims) = 0 THEN
        RETURN '';
    END IF;

    RETURN E'## User Model (approved, evidence-backed)\n' || (
        SELECT string_agg(
            '- ' || COALESCE(um->>'category', 'claim')
            || ': ' || COALESCE(um->>'claim', '')
            || CASE WHEN _pr_is_num(um->'confidence') THEN ' (confidence: ' || _pr_f((um->>'confidence')::numeric, 1) || ')' ELSE '' END
            || CASE WHEN NULLIF(um->>'evidence_count', '') IS NOT NULL THEN ' [evidence: ' || (um->>'evidence_count') || ']' ELSE '' END,
            E'\n' ORDER BY ord)
        FROM (SELECT um, ord FROM jsonb_array_elements(claims) WITH ORDINALITY AS t(um, ord)
              ORDER BY ord LIMIT 8) cu
    );
END;
$$;
