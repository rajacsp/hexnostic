-- 0105: derive connector capabilities and OAuth scopes from DB manifests.
SET search_path = public, ag_catalog, "$user";

UPDATE integration_connectors
SET capability_manifest = '{
      "read": {
        "label": "Read messages",
        "scope_kind": "read",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.readonly"]
      },
      "search": {
        "label": "Search messages",
        "scope_kind": "read",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.readonly"]
      },
      "ingest": {
        "label": "Remember what is read",
        "scope_kind": "local",
        "status": "available",
        "scopes": []
      },
      "label": {
        "label": "Apply/remove labels",
        "scope_kind": "modify",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.modify"]
      },
      "spam_triage": {
        "label": "Triage spam and inbox labels",
        "scope_kind": "modify",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.modify"]
      },
      "send": {
        "label": "Send new messages",
        "scope_kind": "send",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.send"]
      },
      "reply": {
        "label": "Reply in existing threads",
        "scope_kind": "send",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.send"]
      },
      "delete": {
        "label": "Delete messages",
        "scope_kind": "destructive",
        "status": "available",
        "scopes": ["https://www.googleapis.com/auth/gmail.modify"]
      }
    }'::jsonb,
    setup_manifest = setup_manifest || '{
      "default_capabilities": ["read", "search"],
      "capability_order": ["read", "search", "ingest", "label", "spam_triage", "send", "reply", "delete"],
      "required_scopes": ["https://www.googleapis.com/auth/userinfo.email"],
      "scope_order": [
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
      ],
      "capability_aliases": {
        "email": "read",
        "emails": "read",
        "mail": "read",
        "gmail": "read",
        "learn": "ingest",
        "memory": "ingest",
        "remember": "ingest",
        "retain": "ingest",
        "store": "ingest",
        "filter": "spam_triage",
        "filter_spam": "spam_triage",
        "spam": "spam_triage",
        "modify": "label",
        "labels": "label",
        "write": "send",
        "respond": "reply"
      }
    }'::jsonb,
    metadata = metadata || '{"capability_scope_derivation": "db"}'::jsonb,
    updated_at = CURRENT_TIMESTAMP
WHERE id = 'gmail';

CREATE OR REPLACE FUNCTION prepare_connection_attempt(
    p_connector_id TEXT,
    p_requested_capabilities JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    row_connector integration_connectors%ROWTYPE;
    raw_requested JSONB := COALESCE(p_requested_capabilities, 'null'::jsonb);
    requested JSONB := '[]'::jsonb;
    capabilities JSONB := '[]'::jsonb;
    requested_scopes JSONB := '[]'::jsonb;
    unsupported TEXT;
    unavailable TEXT;
BEGIN
    SELECT *
    INTO row_connector
    FROM integration_connectors
    WHERE id = p_connector_id;

    IF NOT FOUND OR row_connector.status <> 'available' THEN
        RAISE EXCEPTION 'integration connector % is not available', p_connector_id;
    END IF;

    IF raw_requested = 'null'::jsonb THEN
        requested := COALESCE(row_connector.setup_manifest->'default_capabilities', '[]'::jsonb);
    ELSIF jsonb_typeof(raw_requested) = 'array' THEN
        requested := raw_requested;
    ELSIF jsonb_typeof(raw_requested) = 'string' THEN
        SELECT COALESCE(jsonb_agg(part), '[]'::jsonb)
        INTO requested
        FROM regexp_split_to_table(raw_requested #>> '{}', '[,[:space:]]+') AS part
        WHERE btrim(part) <> '';
    ELSE
        requested := jsonb_build_array(raw_requested #>> '{}');
    END IF;

    IF jsonb_array_length(requested) = 0 THEN
        requested := COALESCE(row_connector.setup_manifest->'default_capabilities', '[]'::jsonb);
    END IF;

    WITH raw AS (
        SELECT value AS original, ord
        FROM jsonb_array_elements_text(requested) WITH ORDINALITY AS item(value, ord)
        WHERE btrim(value) <> ''
    ),
    normalized AS (
        SELECT
            original,
            COALESCE(
                row_connector.setup_manifest #>> ARRAY[
                    'capability_aliases',
                    lower(replace(btrim(original), '-', '_'))
                ],
                lower(replace(btrim(original), '-', '_'))
            ) AS capability,
            min(ord) AS first_seen
        FROM raw
        GROUP BY original, capability
    )
    SELECT string_agg(DISTINCT original, ', ' ORDER BY original)
    INTO unsupported
    FROM normalized
    WHERE NOT row_connector.capability_manifest ? capability;

    IF unsupported IS NOT NULL THEN
        RAISE EXCEPTION 'unsupported % capability: %', p_connector_id, unsupported;
    END IF;

    WITH raw AS (
        SELECT value AS original, ord
        FROM jsonb_array_elements_text(requested) WITH ORDINALITY AS item(value, ord)
        WHERE btrim(value) <> ''
    ),
    normalized AS (
        SELECT
            COALESCE(
                row_connector.setup_manifest #>> ARRAY[
                    'capability_aliases',
                    lower(replace(btrim(original), '-', '_'))
                ],
                lower(replace(btrim(original), '-', '_'))
            ) AS capability,
            min(ord) AS first_seen
        FROM raw
        GROUP BY capability
    )
    SELECT string_agg(
        capability || ' (' || COALESCE(row_connector.capability_manifest->capability->>'status', 'available') || ')',
        ', '
        ORDER BY capability
    )
    INTO unavailable
    FROM normalized
    WHERE COALESCE(row_connector.capability_manifest->capability->>'status', 'available') <> 'available';

    IF unavailable IS NOT NULL THEN
        RAISE EXCEPTION '% capability is not available: %', p_connector_id, unavailable;
    END IF;

    WITH raw AS (
        SELECT value AS original, ord
        FROM jsonb_array_elements_text(requested) WITH ORDINALITY AS item(value, ord)
        WHERE btrim(value) <> ''
    ),
    normalized AS (
        SELECT
            COALESCE(
                row_connector.setup_manifest #>> ARRAY[
                    'capability_aliases',
                    lower(replace(btrim(original), '-', '_'))
                ],
                lower(replace(btrim(original), '-', '_'))
            ) AS capability,
            min(ord) AS first_seen
        FROM raw
        GROUP BY capability
    ),
    ordered AS (
        SELECT
            n.capability,
            COALESCE(o.ord, 100000 + n.first_seen) AS sort_order
        FROM normalized n
        LEFT JOIN LATERAL (
            SELECT ord
            FROM jsonb_array_elements_text(
                COALESCE(row_connector.setup_manifest->'capability_order', '[]'::jsonb)
            ) WITH ORDINALITY AS item(value, ord)
            WHERE value = n.capability
            LIMIT 1
        ) o ON TRUE
    )
    SELECT COALESCE(jsonb_agg(capability ORDER BY sort_order, capability), '[]'::jsonb)
    INTO capabilities
    FROM ordered;

    WITH selected_caps AS (
        SELECT value AS capability
        FROM jsonb_array_elements_text(capabilities) AS item(value)
    ),
    all_scopes AS (
        SELECT value AS scope
        FROM jsonb_array_elements_text(
            COALESCE(row_connector.setup_manifest->'required_scopes', '[]'::jsonb)
        ) AS item(value)
        UNION
        SELECT scope.value AS scope
        FROM selected_caps cap
        CROSS JOIN LATERAL jsonb_array_elements_text(
            COALESCE(row_connector.capability_manifest->cap.capability->'scopes', '[]'::jsonb)
        ) AS scope(value)
    ),
    ordered_scopes AS (
        SELECT
            scope,
            COALESCE(o.ord, 100000) AS sort_order
        FROM all_scopes s
        LEFT JOIN LATERAL (
            SELECT ord
            FROM jsonb_array_elements_text(
                COALESCE(row_connector.setup_manifest->'scope_order', '[]'::jsonb)
            ) WITH ORDINALITY AS item(value, ord)
            WHERE value = s.scope
            LIMIT 1
        ) o ON TRUE
    )
    SELECT COALESCE(jsonb_agg(scope ORDER BY sort_order, scope), '[]'::jsonb)
    INTO requested_scopes
    FROM ordered_scopes;

    RETURN jsonb_build_object(
        'connector_id', row_connector.id,
        'display_name', row_connector.display_name,
        'auth_type', row_connector.auth_type,
        'capabilities', capabilities,
        'requested_capabilities', capabilities,
        'requested_scopes', requested_scopes,
        'scope_count', jsonb_array_length(requested_scopes),
        'setup_manifest', row_connector.setup_manifest,
        'docs_url', row_connector.docs_url
    );
END;
$$;

CREATE OR REPLACE FUNCTION start_connection_attempt(
    p_connector_id TEXT,
    p_requested_capabilities JSONB DEFAULT '[]'::jsonb,
    p_requested_scopes TEXT[] DEFAULT ARRAY[]::TEXT[],
    p_flow_state JSONB DEFAULT '{}'::jsonb,
    p_authorization_url TEXT DEFAULT NULL,
    p_user_next_step TEXT DEFAULT NULL,
    p_source_channel TEXT DEFAULT NULL,
    p_source_session_id TEXT DEFAULT NULL,
    p_expires_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_attempt connection_attempts%ROWTYPE;
    prepared JSONB;
    derived_scopes TEXT[];
BEGIN
    prepared := prepare_connection_attempt(p_connector_id, p_requested_capabilities);
    SELECT COALESCE(array_agg(value ORDER BY ord), ARRAY[]::TEXT[])
    INTO derived_scopes
    FROM jsonb_array_elements_text(prepared->'requested_scopes') WITH ORDINALITY AS item(value, ord);

    INSERT INTO connection_attempts (
        connector_id,
        requested_capabilities,
        requested_scopes,
        flow_state,
        authorization_url,
        user_next_step,
        source_channel,
        source_session_id,
        expires_at
    )
    VALUES (
        p_connector_id,
        prepared->'requested_capabilities',
        derived_scopes,
        COALESCE(p_flow_state, '{}'::jsonb),
        NULLIF(p_authorization_url, ''),
        NULLIF(p_user_next_step, ''),
        NULLIF(p_source_channel, ''),
        NULLIF(p_source_session_id, ''),
        p_expires_at
    )
    RETURNING * INTO row_attempt;

    RETURN jsonb_build_object(
        'attempt_id', row_attempt.id::text,
        'connector_id', row_attempt.connector_id,
        'status', row_attempt.status,
        'requested_capabilities', row_attempt.requested_capabilities,
        'requested_scopes', to_jsonb(row_attempt.requested_scopes),
        'authorization_url', row_attempt.authorization_url,
        'user_next_step', row_attempt.user_next_step,
        'source_channel', row_attempt.source_channel,
        'source_session_id', row_attempt.source_session_id,
        'expires_at', row_attempt.expires_at,
        'created_at', row_attempt.created_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION complete_connection_attempt(
    p_attempt_id UUID,
    p_account_key TEXT,
    p_display_name TEXT DEFAULT NULL,
    p_credential_ref TEXT DEFAULT NULL,
    p_granted_scopes TEXT[] DEFAULT ARRAY[]::TEXT[],
    p_capabilities JSONB DEFAULT '[]'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_attempt connection_attempts%ROWTYPE;
    row_connection integration_connections%ROWTYPE;
    normalized_account TEXT := NULLIF(btrim(COALESCE(p_account_key, '')), '');
    capability_input JSONB;
    prepared JSONB;
BEGIN
    IF normalized_account IS NULL THEN
        RAISE EXCEPTION 'account_key is required';
    END IF;

    SELECT * INTO row_attempt
    FROM connection_attempts
    WHERE id = p_attempt_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'connection attempt % not found', p_attempt_id;
    END IF;

    IF p_capabilities IS NULL
       OR p_capabilities = 'null'::jsonb
       OR (jsonb_typeof(p_capabilities) = 'array' AND jsonb_array_length(p_capabilities) = 0) THEN
        capability_input := row_attempt.requested_capabilities;
    ELSE
        capability_input := p_capabilities;
    END IF;
    prepared := prepare_connection_attempt(row_attempt.connector_id, capability_input);

    INSERT INTO integration_connections (
        connector_id,
        account_key,
        display_name,
        status,
        credential_ref,
        granted_scopes,
        capabilities,
        source_channel,
        source_session_id,
        metadata,
        connected_at,
        last_verified_at,
        revoked_at,
        last_error
    )
    VALUES (
        row_attempt.connector_id,
        normalized_account,
        NULLIF(btrim(COALESCE(p_display_name, '')), ''),
        'connected',
        NULLIF(btrim(COALESCE(p_credential_ref, '')), ''),
        COALESCE(p_granted_scopes, ARRAY[]::TEXT[]),
        prepared->'capabilities',
        row_attempt.source_channel,
        row_attempt.source_session_id,
        COALESCE(p_metadata, '{}'::jsonb),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        NULL,
        NULL
    )
    ON CONFLICT (connector_id, account_key) DO UPDATE SET
        display_name = COALESCE(EXCLUDED.display_name, integration_connections.display_name),
        status = 'connected',
        credential_ref = COALESCE(EXCLUDED.credential_ref, integration_connections.credential_ref),
        granted_scopes = EXCLUDED.granted_scopes,
        capabilities = EXCLUDED.capabilities,
        source_channel = COALESCE(EXCLUDED.source_channel, integration_connections.source_channel),
        source_session_id = COALESCE(EXCLUDED.source_session_id, integration_connections.source_session_id),
        metadata = integration_connections.metadata || EXCLUDED.metadata,
        connected_at = COALESCE(integration_connections.connected_at, CURRENT_TIMESTAMP),
        last_verified_at = CURRENT_TIMESTAMP,
        revoked_at = NULL,
        last_error = NULL,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_connection;

    UPDATE connection_attempts
    SET account_key = normalized_account,
        status = 'complete',
        credential_ref = p_credential_ref,
        error = NULL,
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_attempt_id;

    RETURN jsonb_build_object(
        'attempt_id', row_attempt.id::text,
        'connector_id', row_connection.connector_id,
        'connection_id', row_connection.id::text,
        'account_key', row_connection.account_key,
        'display_name', row_connection.display_name,
        'status', row_connection.status,
        'credential_ref', row_connection.credential_ref,
        'granted_scopes', to_jsonb(row_connection.granted_scopes),
        'capabilities', row_connection.capabilities,
        'connected_at', row_connection.connected_at
    );
END;
$$;
