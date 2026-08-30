-- 0047: Canonical-schema guard (#77 follow-through) — make the fossil
-- bug impossible to miss: shadow report + loud heal (also run inline by
-- the migration runner after every apply) + an event trigger rejecting
-- ag_catalog functions that would shadow public. Baseline mirror: db/64.
SET search_path = public, ag_catalog, "$user";


CREATE OR REPLACE FUNCTION schema_shadow_report()
RETURNS JSONB AS $$
DECLARE
    strays JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name', p.proname,
        'args', pg_get_function_identity_arguments(p.oid)
    ) ORDER BY p.proname), '[]'::jsonb)
    INTO strays
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'ag_catalog'
      AND EXISTS (
          SELECT 1 FROM pg_proc p2
          JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
          WHERE n2.nspname = 'public' AND p2.proname = p.proname
      );

    RETURN jsonb_build_object(
        'count', jsonb_array_length(strays),
        'strays', strays
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION heal_schema_shadows()
RETURNS JSONB AS $$
DECLARE
    stray RECORD;
    dropped INT := 0;
BEGIN
    FOR stray IN
        SELECT p.proname,
               pg_get_function_identity_arguments(p.oid) AS args,
               p.prokind
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ag_catalog'
          AND EXISTS (
              SELECT 1 FROM pg_proc p2
              JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
              WHERE n2.nspname = 'public' AND p2.proname = p.proname
          )
    LOOP
        -- No CASCADE: anything bound to a stray deserves a deliberate look.
        EXECUTE format(
            'DROP %s IF EXISTS ag_catalog.%I(%s)',
            CASE stray.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
            stray.proname,
            stray.args
        );
        RAISE WARNING 'schema guard: dropped stray ag_catalog.%(%): a public twin exists and must be the only resolution target',
            stray.proname, stray.args;
        dropped := dropped + 1;
    END LOOP;

    RETURN jsonb_build_object('dropped', dropped);
END;
$$ LANGUAGE plpgsql;

-- Reject shadow creation at the source. AGE's own internals are unaffected:
-- they have no public twins, so the collision test never fires for them.
CREATE OR REPLACE FUNCTION _reject_shadow_function()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF obj.object_type IN ('function', 'procedure')
           AND obj.schema_name = 'ag_catalog'
           AND EXISTS (
               SELECT 1 FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'public'
                 AND p.proname = btrim(
                     regexp_replace(split_part(obj.object_identity, '(', 1),
                                    '^ag_catalog\.', ''),
                     '"')
           )
        THEN
            RAISE EXCEPTION
                'refusing to create % — a public function of the same name exists, and an ag_catalog copy would shadow it for every runtime connection (the #77 fossil bug). Create Hexis functions in public: SET search_path = public, ag_catalog, "$user";',
                obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Event triggers need superuser; degrade to a loud notice where we lack it
-- (the report/heal pair still covers detection and repair).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'guard_ag_catalog_shadow') THEN
        DROP EVENT TRIGGER guard_ag_catalog_shadow;
    END IF;
    CREATE EVENT TRIGGER guard_ag_catalog_shadow
        ON ddl_command_end
        WHEN TAG IN ('CREATE FUNCTION')
        EXECUTE FUNCTION _reject_shadow_function();
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'schema guard: no superuser rights — shadow-creation trigger not installed; heal_schema_shadows() still runs after every migration';
END
$$;
