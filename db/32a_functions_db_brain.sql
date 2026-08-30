-- Hexis DB-brain migration guardrails.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION assert_db_brain_ready(
    p_strict BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    required_extensions TEXT[] := ARRAY[
        'vector',
        'age',
        'btree_gist',
        'pg_trgm',
        'http',
        'pgcrypto'
    ];
    planned_extensions TEXT[] := ARRAY[
        'pg_cron',
        'pg_jsonschema'
    ];
    installed_extensions TEXT[];
    available_extensions TEXT[];
    missing_required TEXT[];
    planned_not_installed TEXT[];
    planned_not_available TEXT[];
    result JSONB;
BEGIN
    SELECT COALESCE(array_agg(extname ORDER BY extname), ARRAY[]::TEXT[])
    INTO installed_extensions
    FROM pg_extension
    WHERE extname = ANY(required_extensions || planned_extensions);

    SELECT COALESCE(array_agg(name ORDER BY name), ARRAY[]::TEXT[])
    INTO available_extensions
    FROM pg_available_extensions
    WHERE name = ANY(required_extensions || planned_extensions);

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO missing_required
    FROM unnest(required_extensions) AS ext
    WHERE NOT (ext = ANY(installed_extensions));

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO planned_not_installed
    FROM unnest(planned_extensions) AS ext
    WHERE NOT (ext = ANY(installed_extensions));

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO planned_not_available
    FROM unnest(planned_extensions) AS ext
    WHERE NOT (ext = ANY(available_extensions));

    result := jsonb_build_object(
        'ready', COALESCE(array_length(missing_required, 1), 0) = 0,
        'strict', p_strict,
        'required_extensions', to_jsonb(required_extensions),
        'planned_extensions', to_jsonb(planned_extensions),
        'installed_extensions', to_jsonb(installed_extensions),
        'available_extensions', to_jsonb(available_extensions),
        'missing_required_extensions', to_jsonb(missing_required),
        'planned_extensions_not_installed', to_jsonb(planned_not_installed),
        'planned_extensions_not_available', to_jsonb(planned_not_available),
        'note', 'Slice 0 readiness is advisory for planned extensions; later slices install and require them.'
    );

    IF p_strict AND COALESCE(array_length(missing_required, 1), 0) > 0 THEN
        RAISE EXCEPTION 'Hexis DB-brain required extensions missing: %', array_to_string(missing_required, ', ')
            USING DETAIL = result::TEXT;
    END IF;

    RETURN result;
END;
$$;
