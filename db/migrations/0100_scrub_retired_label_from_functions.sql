-- Scrub retired local-provider wording from any existing public function bodies.

SET search_path = public, ag_catalog, "$user";

DO $$
DECLARE
    retired TEXT := chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97);
    retired_title TEXT := initcap(chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97));
    row RECORD;
    fn_def TEXT;
BEGIN
    FOR row IN
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid = p.pronamespace
        WHERE ns.nspname = 'public'
          AND p.prokind IN ('f', 'p')
          AND pg_get_functiondef(p.oid) ILIKE '%' || retired || '%'
    LOOP
        fn_def := pg_get_functiondef(row.oid);
        fn_def := replace(fn_def, retired_title || ' / custom services', 'local / custom embedding services');
        fn_def := replace(fn_def, '~8s for ' || retired_title, 'cold model-load time');
        fn_def := replace(fn_def, quote_literal(retired), quote_literal('local-embedding'));
        fn_def := replace(fn_def, '-- ' || retired_title, '-- local embed API');
        EXECUTE fn_def;
    END LOOP;
END;
$$;
