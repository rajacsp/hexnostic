-- HMX Slice 0 (provenance half): bootstrap acquisition-mode tagging + backfill.
-- Transactional and idempotent. Mirrored in the baseline:
--   db/05_functions_provenance_trust.sql (functions)
--   db/91_triggers.sql                   (trigger)
--
-- HMX distinguishes what the agent lived from what was seeded at init or
-- imported. Init-created memories get metadata->'provenance' =
-- {"acquisition_mode": "bootstrap"} plus metadata.replaceable_during_bootstrap
-- = true; everything else that predates HMX is backfilled as "experienced".

-- The "created by initialization" predicate. Must stay in sync with
-- reset_persona() (db/10_functions_initialization.sql) and the WHEN clause of
-- trg_hmx_bootstrap_provenance below, which inlines it because trigger WHEN
-- expressions cannot reference other tables and benefit from staying
-- function-call-free on the hot path.
CREATE OR REPLACE FUNCTION is_initialization_memory(p_metadata JSONB, p_source_attribution JSONB)
RETURNS BOOLEAN AS $$
    SELECT p_metadata->>'origin' = 'initialization'
        OR p_metadata->>'type' = 'initialization'
        OR COALESCE(p_source_attribution->>'source', '') = 'initialization';
$$ LANGUAGE sql IMMUTABLE;

-- Trigger body: materialize bootstrap provenance on init-created rows the
-- moment they are created (or first marked as init-created). Rows already
-- deliberately transformed (non-empty change_history) are earned state.
CREATE OR REPLACE FUNCTION hmx_tag_bootstrap_provenance()
RETURNS TRIGGER AS $$
BEGIN
    IF COALESCE(jsonb_typeof(NEW.metadata->'change_history'), '') = 'array'
       AND jsonb_array_length(NEW.metadata->'change_history') > 0 THEN
        NEW.metadata := NEW.metadata || jsonb_build_object(
            'provenance', jsonb_build_object('acquisition_mode', 'experienced'));
    ELSE
        NEW.metadata := NEW.metadata || jsonb_build_object(
            'provenance', jsonb_build_object('acquisition_mode', 'bootstrap'),
            'replaceable_during_bootstrap', true);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- One-shot backfill for rows that predate the trigger. Safe to re-run: only
-- touches rows with no provenance. Returns per-class counts for diagnostics.
CREATE OR REPLACE FUNCTION hmx_backfill_provenance()
RETURNS JSONB AS $$
DECLARE
    n_bootstrap INT;
    n_experienced_init INT;
    n_experienced INT;
BEGIN
    -- Init-created, never deliberately transformed -> bootstrap (replaceable).
    UPDATE memories
    SET metadata = metadata || jsonb_build_object(
            'provenance', jsonb_build_object('acquisition_mode', 'bootstrap'),
            'replaceable_during_bootstrap', true)
    WHERE metadata->'provenance' IS NULL
      AND is_initialization_memory(metadata, source_attribution)
      AND NOT (COALESCE(jsonb_typeof(metadata->'change_history'), '') = 'array'
               AND jsonb_array_length(metadata->'change_history') > 0);
    GET DIAGNOSTICS n_bootstrap = ROW_COUNT;

    -- Init-created but transformed since -> the agent has made it its own.
    UPDATE memories
    SET metadata = metadata || jsonb_build_object(
            'provenance', jsonb_build_object('acquisition_mode', 'experienced'))
    WHERE metadata->'provenance' IS NULL
      AND is_initialization_memory(metadata, source_attribution);
    GET DIAGNOSTICS n_experienced_init = ROW_COUNT;

    -- Everything else was lived.
    UPDATE memories
    SET metadata = metadata || jsonb_build_object(
            'provenance', jsonb_build_object('acquisition_mode', 'experienced'))
    WHERE metadata->'provenance' IS NULL;
    GET DIAGNOSTICS n_experienced = ROW_COUNT;

    RETURN jsonb_build_object(
        'bootstrap', n_bootstrap,
        'experienced_from_init', n_experienced_init,
        'experienced', n_experienced);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_hmx_bootstrap_provenance ON memories;
CREATE TRIGGER trg_hmx_bootstrap_provenance
    BEFORE INSERT OR UPDATE ON memories
    FOR EACH ROW
    WHEN (
        NEW.metadata->'provenance' IS NULL
        AND (NEW.metadata->>'origin' = 'initialization'
             OR NEW.metadata->>'type' = 'initialization'
             OR NEW.source_attribution->>'source' = 'initialization')
    )
    EXECUTE FUNCTION hmx_tag_bootstrap_provenance();

-- Backfill rows that predate the trigger (runs after the trigger exists, so a
-- concurrent init cannot slip an untagged row in between).
SELECT hmx_backfill_provenance();
