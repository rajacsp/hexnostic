-- Gmail action tools are now real provider effect tools, not planned map rows.
SET search_path = public, ag_catalog, "$user";

INSERT INTO connector_action_tool_map (
    tool_name,
    connector_id,
    action_kind,
    target_argument,
    account_argument,
    sensitivity,
    metadata
) VALUES
    ('gmail_send', 'gmail', 'send', 'to', 'account_key', 'external_message',
     '{"tool_module": "core.tools.gmail_actions"}'::jsonb),
    ('gmail_reply', 'gmail', 'reply', 'thread_id', 'account_key', 'external_message',
     '{"tool_module": "core.tools.gmail_actions"}'::jsonb),
    ('gmail_label', 'gmail', 'label', 'message_id', 'account_key', 'provider_state_change',
     '{"tool_module": "core.tools.gmail_actions"}'::jsonb),
    ('gmail_spam_triage', 'gmail', 'spam_triage', 'message_id', 'account_key', 'provider_state_change',
     '{"tool_module": "core.tools.gmail_actions"}'::jsonb),
    ('gmail_delete', 'gmail', 'delete', 'message_id', 'account_key', 'destructive',
     '{"tool_module": "core.tools.gmail_actions"}'::jsonb)
ON CONFLICT (tool_name) DO UPDATE SET
    connector_id = EXCLUDED.connector_id,
    action_kind = EXCLUDED.action_kind,
    target_argument = EXCLUDED.target_argument,
    account_argument = EXCLUDED.account_argument,
    sensitivity = EXCLUDED.sensitivity,
    enabled = TRUE,
    metadata = (connector_action_tool_map.metadata - 'planned_tool') || EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;
