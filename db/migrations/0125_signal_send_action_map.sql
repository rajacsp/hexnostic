-- 0125: map Signal send into the DB-owned connector action policy substrate.
SET search_path = public, ag_catalog, "$user";

INSERT INTO connector_action_tool_map (
    tool_name,
    connector_id,
    action_kind,
    target_argument,
    account_argument,
    sensitivity,
    metadata
) VALUES (
    'signal_send',
    'signal',
    'send',
    'recipient',
    NULL,
    'external_message',
    '{"tool_module": "core.tools.messaging"}'::jsonb
)
ON CONFLICT (tool_name) DO UPDATE SET
    connector_id = EXCLUDED.connector_id,
    action_kind = EXCLUDED.action_kind,
    target_argument = EXCLUDED.target_argument,
    account_argument = EXCLUDED.account_argument,
    sensitivity = EXCLUDED.sensitivity,
    enabled = TRUE,
    metadata = connector_action_tool_map.metadata || EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;
