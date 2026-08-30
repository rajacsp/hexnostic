-- Propagate invalid-precedent corrections to linked raw RecMem units and make
-- raw vector recall label them instead of returning a naked bad transcript.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_memory_correction(
    p_memory_id UUID,
    p_correction TEXT,
    p_scope TEXT DEFAULT 'behavior',
    p_source JSONB DEFAULT '{}'::jsonb,
    p_invalid_precedent BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
    normalized_source JSONB := normalize_source_reference(COALESCE(p_source, '{}'::jsonb));
    correction_text TEXT := NULLIF(btrim(COALESCE(p_correction, '')), '');
    scope_text TEXT := COALESCE(NULLIF(btrim(COALESCE(p_scope, '')), ''), 'behavior');
    correction JSONB;
    updated memories%ROWTYPE;
BEGIN
    IF p_memory_id IS NULL THEN
        RAISE EXCEPTION 'memory_id is required';
    END IF;
    IF correction_text IS NULL THEN
        RAISE EXCEPTION 'correction is required';
    END IF;

    correction := jsonb_build_object(
        'correction', correction_text,
        'scope', scope_text,
        'invalid_precedent', COALESCE(p_invalid_precedent, FALSE),
        'recorded_at', CURRENT_TIMESTAMP,
        'source', normalized_source
    );

    UPDATE memories
    SET metadata = jsonb_set(
            jsonb_set(
                jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{corrections}',
                    COALESCE(metadata->'corrections', '[]'::jsonb) || jsonb_build_array(correction),
                    true
                ),
                '{latest_correction}',
                correction,
                true
            ),
            '{invalid_precedent}',
            to_jsonb(COALESCE((metadata->>'invalid_precedent')::boolean, FALSE) OR COALESCE(p_invalid_precedent, FALSE)),
            true
        ),
        updated_at = CURRENT_TIMESTAMP,
        last_reinforced = CURRENT_TIMESTAMP,
        reinforcement_count = COALESCE(reinforcement_count, 0) + 1
    WHERE id = p_memory_id
      AND status = 'active'
    RETURNING * INTO updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'memory % not found', p_memory_id;
    END IF;

    IF COALESCE(p_invalid_precedent, FALSE) THEN
        UPDATE subconscious_units s
        SET metadata = jsonb_set(
                jsonb_set(
                    COALESCE(s.metadata, '{}'::jsonb),
                    '{latest_correction}',
                    correction,
                    true
                ),
                '{invalid_precedent}',
                'true'::jsonb,
                true
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE EXISTS (
            SELECT 1
            FROM memory_source_units msu
            WHERE msu.memory_id = p_memory_id
              AND msu.subconscious_unit_id = s.id
        );
    END IF;

    PERFORM sync_memory_trust(p_memory_id);

    RETURN jsonb_build_object(
        'memory_id', updated.id::text,
        'status', 'corrected',
        'invalid_precedent', COALESCE((updated.metadata->>'invalid_precedent')::boolean, FALSE),
        'latest_correction', updated.metadata->'latest_correction'
    );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    fn_def TEXT;
    old_text TEXT;
    new_text TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.recmem_subconscious_vector_hits(vector, integer, boolean, vector)'::regprocedure
    )
    INTO fn_def;

    old_text := '            s.created_at,
            s.trust_level,
            ''chunk_vector''::text AS retrieval_source';
    new_text := '            s.created_at,
            s.trust_level,
            s.metadata,
            ''chunk_vector''::text AS retrieval_source';
    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0164 could not locate chunk metadata marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    old_text := '            s.created_at,
            s.trust_level,
            ''vector''::text AS retrieval_source';
    new_text := '            s.created_at,
            s.trust_level,
            s.metadata,
            ''vector''::text AS retrieval_source';
    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0164 could not locate parent metadata marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    old_text := '            candidate_rows.created_at,
            candidate_rows.trust_level,
            candidate_rows.retrieval_source';
    new_text := '            candidate_rows.created_at,
            candidate_rows.trust_level,
            candidate_rows.metadata,
            candidate_rows.retrieval_source';
    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0164 could not locate best metadata marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    old_text := '        b.content,
        NULL::text AS memory_type,
        b.score,';
    new_text := '        CASE
            WHEN b.metadata->>''invalid_precedent'' = ''true'' THEN
                ''[INVALID PRECEDENT - do not imitate''
                || CASE WHEN NULLIF(b.metadata#>>''{latest_correction,correction}'', '''') IS NOT NULL
                        THEN ''; correction: '' || (b.metadata#>>''{latest_correction,correction}'')
                        ELSE '''' END
                || ''] ''
                || b.content
            ELSE b.content
        END AS content,
        NULL::text AS memory_type,
        GREATEST(
            0.001,
            b.score - CASE WHEN b.metadata->>''invalid_precedent'' = ''true'' THEN 0.35 ELSE 0.0 END
        )::float AS score,';
    IF position(old_text IN fn_def) = 0 THEN
        RAISE EXCEPTION '0164 could not locate final content marker';
    END IF;
    fn_def := replace(fn_def, old_text, new_text);

    EXECUTE fn_def;
END;
$$;

UPDATE subconscious_units s
SET metadata = jsonb_set(
        jsonb_set(
            COALESCE(s.metadata, '{}'::jsonb),
            '{latest_correction}',
            COALESCE(m.metadata->'latest_correction', '{}'::jsonb),
            true
        ),
        '{invalid_precedent}',
        'true'::jsonb,
        true
    ),
    updated_at = CURRENT_TIMESTAMP
FROM memory_source_units msu
JOIN memories m ON m.id = msu.memory_id
WHERE s.id = msu.subconscious_unit_id
  AND m.metadata->>'invalid_precedent' = 'true';
