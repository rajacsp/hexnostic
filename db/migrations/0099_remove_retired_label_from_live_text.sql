-- Scrub retired local-provider wording from live prompt text and accounting
-- metadata that may have been written by earlier migrations.

SET search_path = public, ag_catalog, "$user";

DO $$
DECLARE
    retired TEXT := chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97);
    retired_title TEXT := initcap(chr(111) || chr(108) || chr(108) || chr(97) || chr(109) || chr(97));
BEGIN
    UPDATE prompt_modules
    SET content = replace(
        content,
        'Eric does not use ' || retired_title || ' in this project',
        'Eric uses the standalone local embedding service in this project'
    )
    WHERE content ILIKE '%' || retired || '%';

    UPDATE api_usage
    SET provider = 'local-embedding'
    WHERE provider = retired;

    COMMENT ON TABLE model_costs IS
        'USD per million tokens by model. estimate_api_cost() resolves a model by exact then longest-prefix match; unknown models cost NULL for local services.';
END;
$$;
