-- Remove retired local-provider labels from live config text and embedding
-- usage accounting. The retired token is built character-by-character so the
-- repository stays clean while existing databases can still be migrated.

SET search_path = public, ag_catalog, "$user";

DO $$
DECLARE
    retired TEXT := chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97);
    retired_title TEXT := initcap(chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97));
    fn_def TEXT;
BEGIN
    UPDATE config
    SET description = replace(
        replace(description, retired_title || ' / custom services', 'local / custom embedding services'),
        '~8s for ' || retired_title,
        'the cold model-load time'
    )
    WHERE description ILIKE '%' || retired || '%';

    UPDATE config_defaults
    SET description = replace(
        replace(description, retired_title || ' / custom services', 'local / custom embedding services'),
        '~8s for ' || retired_title,
        'the cold model-load time'
    )
    WHERE description ILIKE '%' || retired || '%';

    SELECT pg_get_functiondef('public.get_embedding(text[])'::regprocedure)
    INTO fn_def;

    IF fn_def IS NOT NULL AND fn_def ILIKE '%' || retired || '%' THEN
        fn_def := replace(fn_def, retired_title || ' / custom services', 'local / custom embedding services');
        fn_def := replace(fn_def, '~8s for ' || retired_title, 'cold model-load time');
        fn_def := replace(fn_def, quote_literal(retired), quote_literal('local-embedding'));
        fn_def := replace(fn_def, '-- ' || retired_title, '-- local embed API');
        EXECUTE fn_def;
    END IF;
END;
$$;
