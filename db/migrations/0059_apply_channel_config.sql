-- Channel-wizard pushdown: the per-channel setting catalog and the config
-- writes live in the database. The CLI wizard only gathers answers and hands
-- them over; unknown channels or settings fail loud instead of writing a key
-- nothing reads.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION channel_setting_names(
    p_channel TEXT
) RETURNS TEXT[] AS $$
DECLARE
    catalog JSONB := '{
        "discord":  ["bot_token", "allowed_guilds"],
        "telegram": ["bot_token", "allowed_chat_ids"],
        "slack":    ["bot_token", "app_token", "allowed_channels"],
        "signal":   ["phone_number", "api_url", "allowed_numbers"],
        "whatsapp": ["access_token", "phone_number_id", "verify_token", "webhook_port", "allowed_numbers"],
        "imessage": ["api_url", "password", "allowed_handles"],
        "matrix":   ["homeserver", "user_id", "access_token", "allowed_rooms"]
    }'::jsonb;
BEGIN
    IF NOT catalog ? COALESCE(p_channel, '') THEN
        RAISE EXCEPTION 'Unknown channel type: %; expected one of %',
            COALESCE(p_channel, '(null)'),
            (SELECT string_agg(key, ', ' ORDER BY key) FROM jsonb_object_keys(catalog) key);
    END IF;
    RETURN ARRAY(SELECT jsonb_array_elements_text(catalog->p_channel));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION apply_channel_config(
    p_channel TEXT,
    p_settings JSONB
) RETURNS JSONB AS $$
DECLARE
    known TEXT[] := channel_setting_names(p_channel);
    unknown TEXT[];
    applied TEXT[] := ARRAY[]::TEXT[];
    setting RECORD;
BEGIN
    IF jsonb_typeof(p_settings) <> 'object' OR p_settings = '{}'::jsonb THEN
        RAISE EXCEPTION 'settings must be a non-empty object of channel settings';
    END IF;
    unknown := ARRAY(
        SELECT key FROM jsonb_object_keys(p_settings) key
        WHERE key <> ALL(known) ORDER BY key);
    IF cardinality(unknown) > 0 THEN
        RAISE EXCEPTION 'Unknown % setting(s): %; expected among: %',
            p_channel, array_to_string(unknown, ', '), array_to_string(known, ', ');
    END IF;
    FOR setting IN SELECT key, value FROM jsonb_each(p_settings) LOOP
        PERFORM set_config('channel.' || p_channel || '.' || setting.key, setting.value);
        applied := array_append(applied, setting.key);
    END LOOP;
    RETURN jsonb_build_object('channel', p_channel, 'applied', to_jsonb(applied));
END;
$$ LANGUAGE plpgsql;
