-- 0114: Preserve source-document handles through provenance normalization.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION normalize_source_reference(p_source JSONB)
RETURNS JSONB AS $$
DECLARE
    kind TEXT;
    ref TEXT;
    label TEXT;
    author TEXT;
    observed_at TIMESTAMPTZ;
    trust FLOAT;
    content_hash TEXT;
    source_document_id TEXT;
    document_id TEXT;
    sensitivity TEXT;
BEGIN
    IF p_source IS NULL OR jsonb_typeof(p_source) <> 'object' THEN
        RETURN '{}'::jsonb;
    END IF;

    kind := NULLIF(p_source->>'kind', '');
    ref := COALESCE(NULLIF(p_source->>'ref', ''), NULLIF(p_source->>'uri', ''));
    label := NULLIF(p_source->>'label', '');
    author := NULLIF(p_source->>'author', '');
    content_hash := NULLIF(p_source->>'content_hash', '');
    source_document_id := COALESCE(NULLIF(p_source->>'source_document_id', ''), NULLIF(p_source->>'document_id', ''));
    document_id := COALESCE(NULLIF(p_source->>'document_id', ''), source_document_id);
    sensitivity := CASE WHEN p_source->>'sensitivity' = 'private' THEN 'private' END;

    BEGIN
        observed_at := (p_source->>'observed_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        observed_at := CURRENT_TIMESTAMP;
    END;
    IF observed_at IS NULL THEN
        observed_at := CURRENT_TIMESTAMP;
    END IF;

    trust := COALESCE(NULLIF(p_source->>'trust', '')::float, 0.5);
    trust := LEAST(1.0, GREATEST(0.0, trust));

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'kind', kind,
            'ref', ref,
            'label', label,
            'author', author,
            'observed_at', observed_at,
            'trust', trust,
            'content_hash', content_hash,
            'source_document_id', source_document_id,
            'document_id', document_id,
            'sensitivity', sensitivity
        )
    );
    END;
$$ LANGUAGE plpgsql STABLE;
