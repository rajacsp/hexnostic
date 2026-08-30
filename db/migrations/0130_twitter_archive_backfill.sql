-- Twitter/X historical import is available through user-controlled archive
-- exports. Live OAuth read/search/send remains planned.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE integration_connectors
    DROP CONSTRAINT IF EXISTS integration_connectors_auth_type_check;
ALTER TABLE integration_connectors
    ADD CONSTRAINT integration_connectors_auth_type_check
    CHECK (auth_type IN ('oauth2', 'api_key', 'device_code', 'pairing', 'manual', 'local_export'));

UPDATE integration_connectors
SET auth_type = 'local_export',
    status = 'available',
    capability_manifest = '{
      "read": {"label": "Read timeline, mentions, and DMs", "status": "planned", "scopes": ["tweet.read", "users.read", "dm.read"]},
      "search": {"label": "Search posts", "status": "planned", "scopes": ["tweet.read", "users.read"]},
      "ingest": {"label": "Import historical posts and DMs from a Twitter/X archive", "status": "available", "scopes": []},
      "send": {"label": "Post or send DMs", "status": "planned", "scopes": ["tweet.write", "dm.write"]}
    }'::jsonb,
    setup_manifest = '{
      "flow": "local_archive_import",
      "supported_surfaces": ["chat", "cli", "web", "channels"],
      "default_capabilities": ["ingest"],
      "capability_order": ["read", "search", "ingest", "send"],
      "required_scopes": [],
      "scope_order": ["tweet.read", "users.read", "dm.read", "tweet.write", "dm.write"],
      "capability_aliases": {"x": "read", "twitter": "read", "posts": "read", "dm": "send", "dms": "read"},
      "user_next_step": "Download your Twitter/X archive, extract it locally, then start a history import with an export_path pointing at the archive directory or tweet/direct-message JS file. Live OAuth read/search/send remains planned."
    }'::jsonb,
    metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'twitter_x_archive_import', true,
        'updated_by', 'db/migrations/0130_twitter_archive_backfill.sql'
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE id = 'twitter_x';

CREATE OR REPLACE FUNCTION estimate_connector_backfill(
    p_connector_id TEXT,
    p_requested_range JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    connector TEXT := lower(NULLIF(btrim(COALESCE(p_connector_id, '')), ''));
    requested JSONB := COALESCE(p_requested_range, '{}'::jsonb);
    max_messages INT;
    page_size INT;
    pages INT;
    export_path TEXT;
BEGIN
    BEGIN
        max_messages := NULLIF(requested->>'max_messages', '')::int;
    EXCEPTION WHEN OTHERS THEN
        max_messages := NULL;
    END;
    BEGIN
        page_size := NULLIF(requested->>'page_size', '')::int;
    EXCEPTION WHEN OTHERS THEN
        page_size := NULL;
    END;
    max_messages := LEAST(GREATEST(COALESCE(max_messages, 100), 1), 5000);
    page_size := LEAST(GREATEST(COALESCE(page_size, 100), 1), 500);
    pages := CEIL(max_messages::numeric / page_size::numeric)::int;
    export_path := NULLIF(btrim(COALESCE(requested->>'export_path', requested->>'import_path', '')), '');

    IF connector IN ('gmail', 'slack') THEN
        RETURN jsonb_build_object(
            'connector_id', connector,
            'provider_status', 'api_backfill_available',
            'estimated_items', max_messages,
            'page_size', page_size,
            'estimated_pages', pages,
            'cost_class', CASE WHEN max_messages <= 100 THEN 'small'
                               WHEN max_messages <= 1000 THEN 'medium'
                               ELSE 'large' END,
            'rate_limit_notes', CASE connector
                WHEN 'gmail' THEN 'Gmail API quota and query selectivity determine runtime.'
                ELSE 'Slack conversations.history pagination and workspace rate limits determine runtime.'
            END
        );
    ELSIF connector IN ('telegram', 'signal') THEN
        RETURN jsonb_build_object(
            'connector_id', connector,
            'provider_status', CASE WHEN export_path IS NULL THEN 'export_required' ELSE 'local_export_import' END,
            'estimated_items', max_messages,
            'page_size', page_size,
            'estimated_pages', pages,
            'cost_class', CASE WHEN export_path IS NULL THEN 'blocked_until_export'
                               WHEN max_messages <= 1000 THEN 'local_medium'
                               ELSE 'local_large' END,
            'requires_export_path', export_path IS NULL,
            'limitations', CASE connector
                WHEN 'telegram' THEN 'Telegram Bot API cannot retroactively read chat history; import a Telegram data export for history.'
                ELSE 'Signal runtime APIs do not expose retro-history; import a local Signal export/source artifact for history.'
            END
        );
    ELSIF connector = 'twitter_x' THEN
        RETURN jsonb_build_object(
            'connector_id', connector,
            'provider_status', CASE WHEN export_path IS NULL THEN 'archive_required' ELSE 'local_archive_import' END,
            'estimated_items', max_messages,
            'page_size', page_size,
            'estimated_pages', pages,
            'cost_class', CASE WHEN export_path IS NULL THEN 'blocked_until_archive'
                               WHEN max_messages <= 1000 THEN 'local_medium'
                               ELSE 'local_large' END,
            'requires_export_path', export_path IS NULL,
            'limitations', 'Twitter/X live OAuth history is not configured here; import a Twitter/X archive export for historical posts and DMs.'
        );
    END IF;

    RETURN jsonb_build_object(
        'connector_id', connector,
        'provider_status', 'unknown',
        'estimated_items', max_messages,
        'estimated_pages', pages,
        'cost_class', 'unknown'
    );
END;
$$;
