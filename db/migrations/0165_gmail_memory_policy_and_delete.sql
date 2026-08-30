-- Keep Gmail OAuth permissions separate from Hexis memory/ingestion policy.
-- Gmail delete is now backed by a real action tool.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    (
        'integrations.gmail.memory_policy',
        '"ask"'::jsonb,
        'Controls whether Gmail reads may feed Hexis ingestion and memory by default; ask until the user chooses remember or forget.'
    )
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = CURRENT_TIMESTAMP;

UPDATE integration_connectors
SET capability_manifest = jsonb_set(
        capability_manifest - 'ingest',
        '{delete,status}',
        '"available"'::jsonb,
        true
    ),
    setup_manifest = (
        setup_manifest
        || '{
          "default_capabilities": ["read", "search"],
          "capability_order": ["read", "search", "label", "spam_triage", "send", "reply", "delete"]
        }'::jsonb
    ) #- '{capability_aliases,ingest}',
    updated_at = CURRENT_TIMESTAMP
WHERE id = 'gmail';

UPDATE connector_action_tool_map
SET metadata = (metadata - 'planned_tool') || '{"tool_module": "core.tools.gmail_actions"}'::jsonb,
    updated_at = CURRENT_TIMESTAMP
WHERE tool_name = 'gmail_delete';
