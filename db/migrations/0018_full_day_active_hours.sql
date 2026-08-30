SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION is_within_active_hours()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    active_hours TEXT := get_config_text('heartbeat.active_hours');
    tz TEXT := COALESCE(NULLIF(get_config_text('heartbeat.timezone'), ''), 'UTC');
    parts TEXT[];
    start_min INT;
    end_min INT;
    cur_min INT;
    local_ts TIMESTAMP;
BEGIN
    IF NULLIF(btrim(COALESCE(active_hours, '')), '') IS NULL THEN
        RETURN TRUE;
    END IF;
    BEGIN
        parts := string_to_array(active_hours, '-');
        IF array_length(parts, 1) <> 2 THEN
            RETURN TRUE;
        END IF;
        start_min := split_part(btrim(parts[1]), ':', 1)::int * 60 + split_part(btrim(parts[1]), ':', 2)::int;
        end_min := split_part(btrim(parts[2]), ':', 1)::int * 60 + split_part(btrim(parts[2]), ':', 2)::int;
        IF start_min < 0 OR start_min > 1439 OR end_min < 0 OR end_min > 1439 THEN
            RETURN TRUE;
        END IF;

        BEGIN
            local_ts := now() AT TIME ZONE tz;
        EXCEPTION WHEN OTHERS THEN
            local_ts := now() AT TIME ZONE 'UTC';
        END;
        cur_min := extract(hour FROM local_ts)::int * 60 + extract(minute FROM local_ts)::int;

        IF start_min = 0 AND end_min = 1439 THEN
            RETURN TRUE;
        END IF;
        IF start_min <= end_min THEN
            RETURN cur_min >= start_min AND cur_min < end_min;
        ELSE
            RETURN cur_min >= start_min OR cur_min < end_min;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN TRUE;
    END;
END;
$$;
