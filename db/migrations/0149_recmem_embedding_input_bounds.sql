-- RecMem embedding inputs are bounded search surrogates; full units stay stored.
-- This prevents long chat turns / desk chunks from permanently failing against
-- local embedders with strict token limits, and fixes UTF-8 hashing for text
-- that contains bytea-looking backslashes.

SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description)
VALUES (
    'memory.recmem_embedding_input_chars',
    '1800'::jsonb,
    'Maximum characters from a RecMem unit sent to the embedding service; full content remains stored for reading'
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

CREATE OR REPLACE FUNCTION recmem_embedding_input(
    p_content TEXT
) RETURNS TEXT AS $$
DECLARE
    source_text TEXT := COALESCE(p_content, '');
    max_chars INT := GREATEST(COALESCE(get_config_int('memory.recmem_embedding_input_chars'), 1800), 500);
    omitted_marker TEXT := E'\n\n[... full RecMem unit remains stored; embedding input was shortened ...]\n\n';
    available_chars INT;
    head_chars INT;
    tail_chars INT;
BEGIN
    IF length(source_text) <= max_chars THEN
        RETURN source_text;
    END IF;

    available_chars := max_chars - length(omitted_marker);
    IF available_chars < 100 THEN
        RETURN left(source_text, max_chars);
    END IF;

    head_chars := CEIL(available_chars * 0.7)::INT;
    tail_chars := available_chars - head_chars;
    RETURN left(source_text, head_chars) || omitted_marker || right(source_text, tail_chars);
END;
$$ LANGUAGE plpgsql STABLE;

DO $$
DECLARE
    fn_def TEXT;
BEGIN
    SELECT pg_get_functiondef('public.get_embedding(text[])'::regprocedure)
    INTO fn_def;

    fn_def := replace(
        fn_def,
        'v_content_hash := encode(sha256(text_contents[i]::bytea), ''hex'');',
        'v_content_hash := encode(sha256(convert_to(COALESCE(text_contents[i], ''''), ''UTF8'')), ''hex'');'
    );
    fn_def := replace(
        fn_def,
        'v_alt_hash := encode(sha256(stripped_text::bytea), ''hex'');',
        'v_alt_hash := encode(sha256(convert_to(COALESCE(stripped_text, ''''), ''UTF8'')), ''hex'');'
    );

    EXECUTE fn_def;
END;
$$;

DO $$
DECLARE
    fn_def TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.claim_recmem_unembedded_batch(integer, integer)'::regprocedure
    )
    INTO fn_def;

    fn_def := replace(
        fn_def,
        'RETURNING u.id, u.content, u.embedding_attempts',
        'RETURNING
            u.id,
            u.content,
            recmem_embedding_input(u.content) AS embedding_input,
            u.embedding_attempts'
    );
    fn_def := replace(
        fn_def,
        '''content'', content,
        ''attempts'', embedding_attempts',
        '''content'', content,
        ''embedding_input'', embedding_input,
        ''embedding_input_chars'', length(embedding_input),
        ''attempts'', embedding_attempts'
    );

    EXECUTE fn_def;
END;
$$;

DO $$
DECLARE
    fn_def TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.load_source_documents_to_recmem(uuid[], text[], text[], integer, integer, integer, integer, boolean, text)'::regprocedure
    )
    INTO fn_def;

    fn_def := replace(
        fn_def,
        E'''failed'',\n            ''raw_only'',\n            ''skipped'',',
        E'''pending'',\n            ''raw_only'',\n            ''skipped'','
    );
    fn_def := replace(
        fn_def,
        E'                    ''embedding_skipped'', true,\n                    ''routing_skipped'', true,',
        E'                    ''routing_skipped'', true,'
    );
    fn_def := replace(
        fn_def,
        E'SET status = ''active'',\n            access_count = subconscious_units.access_count + 1,',
        E'SET status = ''active'',\n            embedding_status = CASE\n                WHEN subconscious_units.embedding_status = ''failed''\n                     AND COALESCE(subconscious_units.metadata#>>''{recmem,embedding_skipped}'', ''false'')::boolean\n                    THEN ''pending''\n                ELSE subconscious_units.embedding_status\n            END,\n            embedding_claimed_at = CASE\n                WHEN subconscious_units.embedding_status = ''failed''\n                     AND COALESCE(subconscious_units.metadata#>>''{recmem,embedding_skipped}'', ''false'')::boolean\n                    THEN NULL\n                ELSE subconscious_units.embedding_claimed_at\n            END,\n            access_count = subconscious_units.access_count + 1,'
    );

    EXECUTE fn_def;
END;
$$;

DO $$
DECLARE
    fn_def TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.load_source_chunks_to_recmem(uuid[], uuid, integer, integer, integer, integer, integer, boolean, text, uuid, text, text, boolean)'::regprocedure
    )
    INTO fn_def;

    fn_def := replace(
        fn_def,
        E'''failed'',\n            ''raw_only'',\n            ''skipped'',',
        E'''pending'',\n            ''raw_only'',\n            ''skipped'','
    );
    fn_def := replace(
        fn_def,
        E'                    ''embedding_skipped'', true,\n                    ''routing_skipped'', true,',
        E'                    ''routing_skipped'', true,'
    );
    fn_def := replace(
        fn_def,
        E'SET status = ''active'',\n            access_count = subconscious_units.access_count + 1,',
        E'SET status = ''active'',\n            embedding_status = CASE\n                WHEN subconscious_units.embedding_status = ''failed''\n                     AND COALESCE(subconscious_units.metadata#>>''{recmem,embedding_skipped}'', ''false'')::boolean\n                    THEN ''pending''\n                ELSE subconscious_units.embedding_status\n            END,\n            embedding_claimed_at = CASE\n                WHEN subconscious_units.embedding_status = ''failed''\n                     AND COALESCE(subconscious_units.metadata#>>''{recmem,embedding_skipped}'', ''false'')::boolean\n                    THEN NULL\n                ELSE subconscious_units.embedding_claimed_at\n            END,\n            access_count = subconscious_units.access_count + 1,'
    );

    EXECUTE fn_def;
END;
$$;

UPDATE subconscious_units
SET embedding_status = 'pending',
    embedding_claimed_at = NULL,
    embedding_attempts = 0,
    metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{recmem,embedding_retry_reset}',
        jsonb_build_object(
            'at', CURRENT_TIMESTAMP,
            'reason', 'bounded_recmem_embedding_input'
        ),
        true
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'active'
  AND embedding_status = 'failed'
  AND (
      metadata#>>'{recmem,embedding_error,error}' ILIKE '%input token count%'
      OR metadata#>>'{recmem,embedding_error,error}' ILIKE '%invalid input syntax for type bytea%'
  );
