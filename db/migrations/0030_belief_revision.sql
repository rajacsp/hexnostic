-- 0030: Belief revision (#35/#36) — calibrated, audited confidence updates.
-- belief_revision_audit table, residual_v1 policy (revise_memory_confidence),
-- add_memory_evidence (source + edge + revision), and a protected-memory
-- guard in sync_memory_trust so pinned-trust memories keep their seed value.
-- Baseline mirrors: db/59_belief_revision.sql, db/05_functions_provenance_trust.sql.
SET search_path = public, ag_catalog, "$user";

-- Belief revision (#35/#36): a DB-owned, calibrated, audited evidence policy.
-- revise_memory_confidence applies the 'residual_v1' formula: independent
-- supporting evidence closes a fraction of the *remaining* doubt, independent
-- contradicting evidence removes a fraction of *current* confidence, and
-- non-independent evidence (same ref/label/content_hash as a known source)
-- changes nothing. Every call writes a belief_revision_audit row, so a
-- confidence change is always explainable: prior, posterior, evidence, reason.
-- add_memory_evidence composes revision with source bookkeeping and a
-- SUPPORTS/CONTRADICTS graph edge.

CREATE TABLE IF NOT EXISTS belief_revision_audit (
    audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_id UUID NOT NULL,  -- no FK: audit history outlives deleted memories
    stance TEXT NOT NULL CHECK (stance IN ('supports', 'contradicts')),
    evidence JSONB NOT NULL,
    prior_confidence FLOAT NOT NULL,
    posterior_confidence FLOAT NOT NULL,
    prior_trust FLOAT,
    posterior_trust FLOAT,
    applied BOOLEAN NOT NULL,
    reason TEXT NOT NULL,
    policy TEXT NOT NULL DEFAULT 'residual_v1',
    policy_context TEXT,
    record JSONB NOT NULL,
    record_digest_v1 TEXT NOT NULL CHECK (record_digest_v1 ~ '^[0-9a-f]{64}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_belief_revision_audit_memory
    ON belief_revision_audit (memory_id, created_at);

INSERT INTO config (key, value, description) VALUES
    ('belief.revision_enabled', 'true'::jsonb,
     'Apply calibrated confidence revision when evidence corroborates or contradicts a semantic memory'),
    ('belief.support_rate', '0.35'::jsonb,
     'Fraction of remaining doubt closed by one independent supporting source at trust 1.0'),
    ('belief.contradict_rate', '0.35'::jsonb,
     'Fraction of current confidence removed by one independent contradicting source at trust 1.0'),
    ('belief.confidence_floor', '0.05'::jsonb,
     'Confidence never drops below this: beliefs are eroded, never silently zeroed'),
    ('belief.confidence_ceiling', '0.99'::jsonb,
     'Confidence never reaches certainty regardless of evidence volume')
ON CONFLICT (key) DO NOTHING;

-- The dedupe identity of a source, matching dedupe_source_references (db/05):
-- ref, else label, else content digest of the normalized object.
CREATE OR REPLACE FUNCTION _source_dedupe_key(p_source JSONB)
RETURNS TEXT AS $$
    SELECT COALESCE(
        NULLIF(p_source->>'ref', ''),
        NULLIF(p_source->>'label', ''),
        md5(p_source::text)
    );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION revise_memory_confidence(
    p_memory_id UUID,
    p_evidence JSONB,
    p_stance TEXT,
    p_policy_context TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    mem memories%ROWTYPE;
    normalized JSONB;
    evidence_trust FLOAT;
    prior FLOAT;
    posterior FLOAT;
    prior_trust FLOAT;
    posterior_trust FLOAT;
    applied BOOLEAN := FALSE;
    independent BOOLEAN := FALSE;
    reason TEXT;
    enabled BOOLEAN;
    is_protected BOOLEAN;
    support_rate FLOAT := COALESCE(get_config_float('belief.support_rate'), 0.35);
    contradict_rate FLOAT := COALESCE(get_config_float('belief.contradict_rate'), 0.35);
    conf_floor FLOAT := COALESCE(get_config_float('belief.confidence_floor'), 0.05);
    conf_ceiling FLOAT := COALESCE(get_config_float('belief.confidence_ceiling'), 0.99);
    key TEXT;
    audit_record JSONB;
    result JSONB;
BEGIN
    IF p_stance NOT IN ('supports', 'contradicts') THEN
        RAISE EXCEPTION 'invalid stance: % (expected supports|contradicts)', p_stance;
    END IF;

    SELECT * INTO mem FROM memories WHERE id = p_memory_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('memory_id', p_memory_id::text, 'stance', p_stance,
                                  'applied', FALSE, 'reason', 'not_found');
    END IF;

    prior := LEAST(1.0, GREATEST(0.0, COALESCE((mem.metadata->>'confidence')::float, 0.5)));
    prior_trust := mem.trust_level;
    posterior := prior;
    posterior_trust := prior_trust;
    normalized := normalize_source_reference(p_evidence);
    evidence_trust := LEAST(1.0, GREATEST(0.0, COALESCE((normalized->>'trust')::float, 0.5)));
    is_protected := COALESCE((mem.metadata->>'protected')::boolean, FALSE);
    enabled := COALESCE(get_config_bool('belief.revision_enabled'), TRUE);

    IF mem.type <> 'semantic' THEN
        reason := 'not_semantic';
    ELSIF normalized = '{}'::jsonb THEN
        reason := 'invalid_evidence';
    ELSE
        -- Independence: an evidence source already known (as support or as
        -- contradiction, by ref/label key or identical content_hash) adds no
        -- new information and never moves confidence.
        key := _source_dedupe_key(normalized);
        independent := NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
                COALESCE(mem.metadata->'source_references', '[]'::jsonb)
                || COALESCE(mem.metadata->'contradicting_sources', '[]'::jsonb)
            ) existing(src)
            WHERE _source_dedupe_key(existing.src) = key
               OR (normalized->>'content_hash' IS NOT NULL
                   AND existing.src->>'content_hash' = normalized->>'content_hash')
        );

        IF NOT independent THEN
            reason := 'duplicate_source';
        ELSIF NOT enabled THEN
            reason := 'disabled';
        ELSIF is_protected AND p_stance = 'contradicts' THEN
            -- Protected (e.g. origin) memories can be questioned, never
            -- silently rewritten: the contradiction is recorded and flagged,
            -- confidence stays put.
            reason := 'protected';
        ELSE
            IF p_stance = 'supports' THEN
                posterior := LEAST(conf_ceiling, prior + (1.0 - prior) * support_rate * evidence_trust);
            ELSE
                posterior := GREATEST(conf_floor, prior * (1.0 - contradict_rate * evidence_trust));
            END IF;
            applied := TRUE;
            reason := 'applied';
        END IF;

        -- Source bookkeeping happens for every valid evidence object, applied
        -- or not: duplicates refresh observed_at, contradictions stay visible.
        IF applied THEN
            UPDATE memories
            SET metadata = jsonb_set(mem.metadata, '{confidence}', to_jsonb(posterior))
            WHERE id = p_memory_id;
        END IF;
        IF p_stance = 'supports' THEN
            PERFORM add_semantic_source_reference(p_memory_id, normalized);
        ELSE
            UPDATE memories
            SET metadata = jsonb_set(
                    jsonb_set(
                        metadata,
                        '{contradicting_sources}',
                        dedupe_source_references(
                            COALESCE(metadata->'contradicting_sources', '[]'::jsonb)
                            || jsonb_build_array(normalized)
                        )
                    ),
                    '{last_validated}', to_jsonb(CURRENT_TIMESTAMP)
                )
            WHERE id = p_memory_id AND type = 'semantic';
            PERFORM sync_memory_trust(p_memory_id);
        END IF;
        SELECT trust_level INTO posterior_trust FROM memories WHERE id = p_memory_id;
    END IF;

    result := jsonb_build_object(
        'memory_id', p_memory_id::text,
        'stance', p_stance,
        'prior', prior,
        'posterior', posterior,
        'prior_trust', prior_trust,
        'posterior_trust', posterior_trust,
        'applied', applied,
        'reason', reason,
        'independent', independent
    );

    audit_record := result || jsonb_build_object(
        'evidence', normalized,
        'policy', 'residual_v1',
        'policy_context', p_policy_context,
        'at', CURRENT_TIMESTAMP
    );
    INSERT INTO belief_revision_audit (
        memory_id, stance, evidence, prior_confidence, posterior_confidence,
        prior_trust, posterior_trust, applied, reason, policy, policy_context,
        record, record_digest_v1
    ) VALUES (
        p_memory_id, p_stance, COALESCE(normalized, '{}'::jsonb), prior, posterior,
        prior_trust, posterior_trust, applied, reason, 'residual_v1', p_policy_context,
        audit_record, encode(digest(audit_record::text, 'sha256'), 'hex')
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Attach evidence to an existing belief: revise confidence via the policy,
-- record the source, and create a SUPPORTS/CONTRADICTS edge from an evidence
-- node (an existing memory, or a lightweight episodic observation built from
-- p_note). Returns the revision result plus evidence_memory_id, so callers
-- can report "confidence 0.55 -> 0.66" honestly.
CREATE OR REPLACE FUNCTION add_memory_evidence(
    p_memory_id UUID,
    p_stance TEXT,
    p_source JSONB,
    p_note TEXT DEFAULT NULL,
    p_evidence_memory_id UUID DEFAULT NULL,
    p_context TEXT DEFAULT 'add_evidence'
) RETURNS JSONB AS $$
DECLARE
    revision JSONB;
    evidence_id UUID := p_evidence_memory_id;
    edge_confidence FLOAT;
BEGIN
    revision := revise_memory_confidence(p_memory_id, p_source, p_stance, p_context);
    IF revision->>'reason' IN ('not_found', 'invalid_evidence', 'not_semantic') THEN
        RETURN revision;
    END IF;

    IF evidence_id IS NULL AND NULLIF(btrim(COALESCE(p_note, '')), '') IS NOT NULL THEN
        evidence_id := create_episodic_memory(
            p_note,
            NULL,
            jsonb_build_object('type', 'evidence_observation', 'context', p_context),
            NULL,
            0.0,
            CURRENT_TIMESTAMP,
            0.3,
            p_source,
            NULL
        );
    END IF;

    IF evidence_id IS NOT NULL THEN
        edge_confidence := LEAST(1.0, GREATEST(0.0,
            COALESCE((normalize_source_reference(p_source)->>'trust')::float, 0.5)));
        PERFORM discover_relationship(
            evidence_id,
            p_memory_id,
            upper(p_stance)::graph_edge_type,
            edge_confidence,
            p_context,
            NULL,
            left(COALESCE(p_note, ''), 500)
        );
    END IF;

    RETURN revision || jsonb_strip_nulls(jsonb_build_object(
        'evidence_memory_id', evidence_id::text
    ));
END;
$$ LANGUAGE plpgsql;

-- sync_memory_trust gains the metadata.protected early-return guard.
CREATE OR REPLACE FUNCTION sync_memory_trust(p_memory_id UUID)
RETURNS VOID AS $$
DECLARE
    mtype memory_type;
    conf FLOAT;
    sources JSONB;
    alignment FLOAT;
    computed FLOAT;
    mem_metadata JSONB;
BEGIN
    SELECT type, metadata INTO mtype, mem_metadata FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF mtype <> 'semantic' THEN
        RETURN;
    END IF;
    -- Protected memories (e.g. origin documents) keep their seeded trust:
    -- confidence may still be revised, but derived trust is pinned.
    IF COALESCE((mem_metadata->>'protected')::boolean, FALSE) THEN
        RETURN;
    END IF;
    conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
    sources := mem_metadata->'source_references';

    sources := dedupe_source_references(sources);
    alignment := compute_worldview_alignment(p_memory_id);
    computed := compute_semantic_trust(conf, sources, alignment);

    UPDATE memories
    SET trust_level = computed,
        trust_updated_at = CURRENT_TIMESTAMP,
        source_attribution = CASE
            WHEN (source_attribution = '{}'::jsonb OR source_attribution IS NULL)
                 AND jsonb_typeof(sources) = 'array'
                 AND jsonb_array_length(sources) > 0
            THEN normalize_source_reference(sources->0)
            ELSE source_attribution
        END
    WHERE id = p_memory_id;
END;
$$ LANGUAGE plpgsql;
