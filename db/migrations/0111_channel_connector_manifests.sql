-- First-class Slack, Telegram, Signal, and Twitter/X connector manifests.
SET search_path = public, ag_catalog, "$user";

INSERT INTO integration_connectors (
    id,
    display_name,
    category,
    auth_type,
    status,
    capability_manifest,
    setup_manifest,
    docs_url,
    metadata
) VALUES
(
    'slack',
    'Slack',
    'communication',
    'api_key',
    'available',
    '{
      "live_chat": {"label": "Receive live Slack messages", "status": "available", "scopes": ["app_mentions:read", "channels:history"]},
      "send": {"label": "Send Slack messages", "status": "available", "scopes": ["chat:write"]},
      "ingest_live": {"label": "Preserve and ingest live Slack messages", "status": "available", "scopes": ["app_mentions:read", "channels:history"]},
      "media": {"label": "Read Slack file metadata from live events", "status": "available", "scopes": ["files:read"]},
      "backfill": {"label": "Import historical Slack messages", "status": "planned", "scopes": ["channels:history", "groups:history", "im:history", "mpim:history"]},
      "admin": {"label": "Administer Slack workspace settings", "status": "planned", "scopes": []}
    }'::jsonb,
    '{
      "flow": "manual_channel_token_config",
      "secret_storage": "environment",
      "supported_surfaces": ["chat", "cli", "web", "channels"],
      "default_capabilities": ["live_chat", "send", "ingest_live"],
      "capability_order": ["live_chat", "send", "ingest_live", "media", "backfill", "admin"],
      "required_scopes": [],
      "scope_order": ["app_mentions:read", "channels:history", "chat:write", "files:read", "groups:history", "im:history", "mpim:history"],
      "config_keys": ["channel.slack.bot_token", "channel.slack.app_token", "channel.slack.allowed_channels"],
      "env_vars": ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"],
      "capability_aliases": {
        "read": "live_chat",
        "receive": "live_chat",
        "listen": "live_chat",
        "message": "send",
        "messages": "live_chat",
        "write": "send",
        "history": "backfill",
        "ingest": "ingest_live"
      },
      "user_next_step": "Create or choose a Slack app, enable Socket Mode, set SLACK_BOT_TOKEN to a bot token env var and SLACK_APP_TOKEN to an app-level token env var, then verify this connector. The channel worker starts Slack when those values resolve.",
      "notes": [
        "Store token values in environment variables, not in chat or Postgres.",
        "Use channel.slack.allowed_channels to restrict where Hexis listens."
      ]
    }'::jsonb,
    'https://api.slack.com/start/quickstart',
    '{"provider": "slack", "seeded_by": "db/migrations/0111_channel_connector_manifests.sql"}'::jsonb
),
(
    'telegram',
    'Telegram',
    'communication',
    'api_key',
    'available',
    '{
      "live_chat": {"label": "Receive live Telegram messages", "status": "available", "scopes": []},
      "send": {"label": "Send Telegram messages", "status": "available", "scopes": []},
      "ingest_live": {"label": "Preserve and ingest live Telegram messages", "status": "available", "scopes": []},
      "media": {"label": "Read Telegram attachment metadata from live events", "status": "available", "scopes": []},
      "backfill": {"label": "Import historical Telegram messages", "status": "planned", "scopes": []}
    }'::jsonb,
    '{
      "flow": "manual_channel_token_config",
      "secret_storage": "environment",
      "supported_surfaces": ["chat", "cli", "web", "channels"],
      "default_capabilities": ["live_chat", "send", "ingest_live"],
      "capability_order": ["live_chat", "send", "ingest_live", "media", "backfill"],
      "required_scopes": [],
      "scope_order": [],
      "config_keys": ["channel.telegram.bot_token", "channel.telegram.allowed_chat_ids"],
      "env_vars": ["TELEGRAM_BOT_TOKEN"],
      "capability_aliases": {
        "read": "live_chat",
        "receive": "live_chat",
        "listen": "live_chat",
        "message": "send",
        "messages": "live_chat",
        "write": "send",
        "history": "backfill",
        "ingest": "ingest_live"
      },
      "user_next_step": "Create a Telegram bot with BotFather, store the bot token in TELEGRAM_BOT_TOKEN or another env var, set channel.telegram.bot_token to that env var name if needed, then verify this connector. The channel worker starts Telegram when the token resolves.",
      "notes": [
        "Store bot token values in environment variables, not in chat or Postgres.",
        "Use channel.telegram.allowed_chat_ids to restrict where Hexis listens."
      ]
    }'::jsonb,
    'https://core.telegram.org/bots/tutorial',
    '{"provider": "telegram", "seeded_by": "db/migrations/0111_channel_connector_manifests.sql"}'::jsonb
),
(
    'signal',
    'Signal',
    'communication',
    'pairing',
    'available',
    '{
      "live_chat": {"label": "Receive live Signal messages", "status": "available", "scopes": []},
      "send": {"label": "Send Signal messages", "status": "available", "scopes": []},
      "ingest_live": {"label": "Preserve and ingest live Signal messages", "status": "available", "scopes": []},
      "media": {"label": "Read Signal attachment metadata from live events", "status": "available", "scopes": []},
      "backfill": {"label": "Import historical Signal messages", "status": "planned", "scopes": []}
    }'::jsonb,
    '{
      "flow": "signal_cli_rest_sidecar",
      "secret_storage": "environment",
      "supported_surfaces": ["chat", "cli", "web", "channels"],
      "default_capabilities": ["live_chat", "send", "ingest_live"],
      "capability_order": ["live_chat", "send", "ingest_live", "media", "backfill"],
      "required_scopes": [],
      "scope_order": [],
      "config_keys": ["channel.signal.phone_number", "channel.signal.api_url", "channel.signal.allowed_numbers"],
      "env_vars": ["SIGNAL_PHONE_NUMBER", "SIGNAL_API_URL"],
      "capability_aliases": {
        "read": "live_chat",
        "receive": "live_chat",
        "listen": "live_chat",
        "message": "send",
        "messages": "live_chat",
        "write": "send",
        "history": "backfill",
        "ingest": "ingest_live"
      },
      "user_next_step": "Run or connect a signal-cli-rest-api sidecar, register/link the Signal phone number, set SIGNAL_PHONE_NUMBER and optionally SIGNAL_API_URL, then verify this connector. The channel worker starts Signal when the phone number resolves.",
      "notes": [
        "Signal protocol state lives in the sidecar, not in Postgres.",
        "Use channel.signal.allowed_numbers to restrict who Hexis listens to."
      ]
    }'::jsonb,
    'https://github.com/bbernhard/signal-cli-rest-api',
    '{"provider": "signal", "seeded_by": "db/migrations/0111_channel_connector_manifests.sql"}'::jsonb
),
(
    'twitter_x',
    'Twitter/X',
    'communication',
    'oauth2',
    'planned',
    '{
      "read": {"label": "Read timeline, mentions, and DMs", "status": "planned", "scopes": ["tweet.read", "users.read", "dm.read"]},
      "search": {"label": "Search posts", "status": "planned", "scopes": ["tweet.read", "users.read"]},
      "ingest": {"label": "Import historical posts and DMs", "status": "planned", "scopes": ["tweet.read", "users.read", "dm.read"]},
      "send": {"label": "Post or send DMs", "status": "planned", "scopes": ["tweet.write", "dm.write"]}
    }'::jsonb,
    '{
      "flow": "oauth2_planned",
      "supported_surfaces": ["chat", "cli", "web", "channels"],
      "default_capabilities": ["read", "search", "ingest"],
      "capability_order": ["read", "search", "ingest", "send"],
      "required_scopes": [],
      "scope_order": ["tweet.read", "users.read", "dm.read", "tweet.write", "dm.write"],
      "capability_aliases": {"x": "read", "twitter": "read", "posts": "read", "dm": "send", "dms": "read"},
      "user_next_step": "Twitter/X is listed in the connector catalog but the provider adapter is not implemented yet."
    }'::jsonb,
    'https://developer.x.com/en/docs',
    '{"provider": "twitter_x", "seeded_by": "db/migrations/0111_channel_connector_manifests.sql"}'::jsonb
)
ON CONFLICT (id) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    category = EXCLUDED.category,
    auth_type = EXCLUDED.auth_type,
    status = EXCLUDED.status,
    capability_manifest = EXCLUDED.capability_manifest,
    setup_manifest = EXCLUDED.setup_manifest,
    docs_url = EXCLUDED.docs_url,
    metadata = integration_connectors.metadata || EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;
