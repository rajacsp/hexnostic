-- 0176: Gmail "ingest" is a Hexis memory policy capability, not a Google OAuth scope.
SET search_path = public, ag_catalog, "$user";

UPDATE integration_connectors
SET capability_manifest = jsonb_set(
        capability_manifest,
        '{ingest}',
        '{
          "label": "Remember what is read",
          "scope_kind": "local",
          "status": "available",
          "scopes": []
        }'::jsonb,
        true
    ),
    setup_manifest = jsonb_set(
        jsonb_set(
            jsonb_set(
                setup_manifest,
                '{capability_order}',
                '["read", "search", "ingest", "label", "spam_triage", "send", "reply", "delete"]'::jsonb,
                true
            ),
            '{capability_aliases}',
            COALESCE(setup_manifest->'capability_aliases', '{}'::jsonb)
                || '{
                  "learn": "ingest",
                  "memory": "ingest",
                  "remember": "ingest",
                  "retain": "ingest",
                  "store": "ingest"
                }'::jsonb,
            true
        ),
        '{default_capabilities}',
        COALESCE(setup_manifest->'default_capabilities', '["read", "search"]'::jsonb),
        true
    ),
    metadata = metadata || '{"gmail_ingest_capability": "local"}'::jsonb,
    updated_at = CURRENT_TIMESTAMP
WHERE id = 'gmail';
