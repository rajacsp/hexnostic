-- MCP now exposes the registry-native surface by default. The old handwritten
-- tool list remains behind an explicit compatibility flag for existing clients.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('mcp.legacy_compat_enabled', 'false'::jsonb,
     'Expose the old handwritten MCP compatibility tool surface in addition to registry-native tools')
ON CONFLICT (key) DO NOTHING;
