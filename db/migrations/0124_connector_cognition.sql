-- 0124: connector cognition substrate.
--
-- Historical connector data should not become prompt lore. Source items are
-- distilled into evidence-backed user-model claims, and high-importance items
-- are detected into a DB-owned notification/action surface.
SET search_path = public, ag_catalog, "$user";

UPDATE integration_connectors
SET capability_manifest = jsonb_set(
        capability_manifest,
        '{backfill,status}',
        '"available"'::jsonb,
        true
    ),
    metadata = metadata || '{"backfill_adapter": "services.channel_backfill.slack"}'::jsonb,
    updated_at = CURRENT_TIMESTAMP
WHERE id = 'slack';

INSERT INTO config_defaults (key, value, description) VALUES
    ('connector.user_model_synthesis_enabled', 'true'::jsonb,
     'Distill connector source items into evidence-backed user-model claims'),
    ('connector.user_model_synthesis_batch_size', '10'::jsonb,
     'Connector source items claimed per user-model synthesis pass'),
    ('connector.user_model_synthesis_claim_timeout_s', '600'::jsonb,
     'Seconds before an in-progress user-model synthesis claim can be retried'),
    ('connector.importance_detection_enabled', 'true'::jsonb,
     'Score connector source items for user-visible importance'),
    ('connector.importance_detection_batch_size', '20'::jsonb,
     'Connector source items claimed per importance detection pass'),
    ('connector.importance_detection_claim_timeout_s', '600'::jsonb,
     'Seconds before an in-progress importance detection claim can be retried'),
    ('connector.importance_notify_threshold', '0.85'::jsonb,
     'Importance score at or above which a connector item queues a web-inbox notification')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS user_model_source_progress (
    source_item_id UUID PRIMARY KEY REFERENCES connector_source_items(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'completed', 'failed')),
    attempts INT NOT NULL DEFAULT 0,
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    last_error TEXT,
    detector_version TEXT,
    result JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_model_source_progress_status
    ON user_model_source_progress (status, updated_at);

CREATE TABLE IF NOT EXISTS user_model_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_key TEXT NOT NULL UNIQUE,
    category TEXT NOT NULL DEFAULT 'preference',
    claim TEXT NOT NULL,
    memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
    confidence FLOAT NOT NULL DEFAULT 0.5 CHECK (confidence >= 0 AND confidence <= 1),
    importance FLOAT NOT NULL DEFAULT 0.5 CHECK (importance >= 0 AND importance <= 1),
    evidence_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
    evidence_count INT NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'superseded', 'rejected')),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_evidence_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_model_claims_category
    ON user_model_claims (category, updated_at DESC)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_user_model_claims_evidence
    ON user_model_claims USING GIN (evidence_refs);

CREATE TABLE IF NOT EXISTS connector_item_importance (
    source_item_id UUID PRIMARY KEY REFERENCES connector_source_items(id) ON DELETE CASCADE,
    connector_id TEXT NOT NULL,
    account_key TEXT NOT NULL,
    source_document_id UUID REFERENCES source_documents(id) ON DELETE SET NULL,
    score FLOAT NOT NULL DEFAULT 0.0 CHECK (score >= 0 AND score <= 1),
    label TEXT NOT NULL DEFAULT 'normal'
        CHECK (label IN ('low', 'normal', 'important', 'urgent')),
    reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
    recommended_actions JSONB NOT NULL DEFAULT '[]'::jsonb,
    detector_version TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'ignored', 'resolved')),
    attempts INT NOT NULL DEFAULT 0,
    claimed_at TIMESTAMPTZ,
    notification_queued_at TIMESTAMPTZ,
    last_error TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_connector_item_importance_status
    ON connector_item_importance (status, updated_at);
CREATE INDEX IF NOT EXISTS idx_connector_item_importance_score
    ON connector_item_importance (score DESC, updated_at DESC)
    WHERE status = 'completed';

CREATE OR REPLACE FUNCTION claim_user_model_source_items(
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := GREATEST(COALESCE(p_limit, get_config_int('connector.user_model_synthesis_batch_size'), 10), 1);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('connector.user_model_synthesis_claim_timeout_s'), 600);
    candidate RECORD;
    row_progress user_model_source_progress%ROWTYPE;
    item JSONB;
    result JSONB := '[]'::jsonb;
BEGIN
    FOR candidate IN
        SELECT csi.id
        FROM connector_source_items csi
        JOIN source_documents d ON d.id = csi.source_document_id AND d.status = 'active'
        LEFT JOIN user_model_source_progress p ON p.source_item_id = csi.id
        WHERE csi.status = 'active'
          AND csi.sensitivity IN ('private', 'shared')
          AND (
                p.source_item_id IS NULL
             OR p.status = 'pending'
             OR (p.status = 'failed' AND p.attempts < 3)
             OR (p.status = 'in_progress'
                 AND p.claimed_at < CURRENT_TIMESTAMP - make_interval(secs => timeout_s))
          )
        ORDER BY COALESCE(csi.item_timestamp, csi.created_at), csi.id
        LIMIT lim
        FOR UPDATE OF csi SKIP LOCKED
    LOOP
        INSERT INTO user_model_source_progress (source_item_id, status, attempts, claimed_at, last_error)
        VALUES (candidate.id, 'in_progress', 1, CURRENT_TIMESTAMP, NULL)
        ON CONFLICT (source_item_id) DO UPDATE SET
            status = 'in_progress',
            attempts = user_model_source_progress.attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            last_error = NULL,
            updated_at = CURRENT_TIMESTAMP
        RETURNING * INTO row_progress;

        SELECT jsonb_build_object(
            'source_item_id', csi.id::text,
            'connector_id', csi.connector_id,
            'account_key', csi.account_key,
            'provider_item_id', csi.provider_item_id,
            'provider_thread_id', csi.provider_thread_id,
            'source_document_id', d.id::text,
            'title', d.title,
            'path', d.path,
            'content', d.content,
            'sensitivity', csi.sensitivity,
            'item_timestamp', csi.item_timestamp,
            'attempts', row_progress.attempts
        )
        INTO item
        FROM connector_source_items csi
        JOIN source_documents d ON d.id = csi.source_document_id
        WHERE csi.id = candidate.id;

        result := result || jsonb_build_array(item);
    END LOOP;

    RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION fail_user_model_source_item(
    p_source_item_id UUID,
    p_error TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_progress user_model_source_progress%ROWTYPE;
BEGIN
    INSERT INTO user_model_source_progress (source_item_id, status, attempts, last_error)
    VALUES (p_source_item_id, 'failed', 1, COALESCE(NULLIF(p_error, ''), 'user-model synthesis failed'))
    ON CONFLICT (source_item_id) DO UPDATE SET
        status = 'failed',
        last_error = COALESCE(NULLIF(p_error, ''), 'user-model synthesis failed'),
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_progress;

    RETURN jsonb_build_object(
        'source_item_id', row_progress.source_item_id::text,
        'status', row_progress.status,
        'attempts', row_progress.attempts,
        'error', row_progress.last_error
    );
END;
$$;

CREATE OR REPLACE FUNCTION upsert_user_model_claim(
    p_claim_key TEXT,
    p_claim TEXT,
    p_category TEXT DEFAULT 'preference',
    p_confidence FLOAT DEFAULT 0.5,
    p_importance FLOAT DEFAULT 0.5,
    p_source_item_id UUID DEFAULT NULL,
    p_source_document_id UUID DEFAULT NULL,
    p_evidence JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_key TEXT := lower(NULLIF(btrim(COALESCE(p_claim_key, '')), ''));
    normalized_claim TEXT := NULLIF(btrim(COALESCE(p_claim, '')), '');
    row_claim user_model_claims%ROWTYPE;
    source_ref JSONB;
    refs JSONB;
    memory_id UUID;
    confidence_value FLOAT := LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.5)));
    importance_value FLOAT := LEAST(1.0, GREATEST(0.0, COALESCE(p_importance, 0.5)));
    inserted BOOLEAN := FALSE;
BEGIN
    IF normalized_key IS NULL THEN
        RAISE EXCEPTION 'claim_key is required';
    END IF;
    IF normalized_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    source_ref := jsonb_strip_nulls(jsonb_build_object(
        'kind', 'connector_user_model_evidence',
        'ref', CASE WHEN p_source_item_id IS NULL THEN NULL ELSE 'connector_source_item:' || p_source_item_id::text END,
        'source_item_id', CASE WHEN p_source_item_id IS NULL THEN NULL ELSE p_source_item_id::text END,
        'source_document_id', CASE WHEN p_source_document_id IS NULL THEN NULL ELSE p_source_document_id::text END,
        'label', COALESCE(p_evidence->>'label', 'connector source item'),
        'trust', COALESCE(NULLIF(p_evidence->>'trust', '')::float, 0.75),
        'observed_at', CURRENT_TIMESTAMP
    ));
    refs := dedupe_source_references(jsonb_build_array(source_ref));

    SELECT * INTO row_claim
    FROM user_model_claims
    WHERE claim_key = normalized_key
    FOR UPDATE;

    IF NOT FOUND THEN
        memory_id := create_semantic_memory(
            normalized_claim,
            confidence_value,
            ARRAY['user_model', COALESCE(NULLIF(p_category, ''), 'preference')],
            NULL,
            refs,
            importance_value,
            source_ref,
            COALESCE(NULLIF(source_ref->>'trust', '')::float, 0.75)
        );
        inserted := TRUE;

        INSERT INTO user_model_claims (
            claim_key, category, claim, memory_id, confidence, importance,
            evidence_refs, evidence_count, metadata
        )
        VALUES (
            normalized_key,
            COALESCE(NULLIF(p_category, ''), 'preference'),
            normalized_claim,
            memory_id,
            confidence_value,
            importance_value,
            refs,
            jsonb_array_length(refs),
            COALESCE(p_metadata, '{}'::jsonb)
        )
        RETURNING * INTO row_claim;

        UPDATE memories
        SET metadata = metadata || jsonb_build_object(
                'user_model_claim_id', row_claim.id::text,
                'user_model_claim_key', row_claim.claim_key,
                'user_model_category', row_claim.category
            )
        WHERE id = row_claim.memory_id;
    ELSE
        refs := dedupe_source_references(COALESCE(row_claim.evidence_refs, '[]'::jsonb) || jsonb_build_array(source_ref));
        IF row_claim.memory_id IS NOT NULL THEN
            PERFORM add_memory_evidence(
                row_claim.memory_id,
                'supports',
                source_ref,
                normalized_claim,
                NULL,
                'user_model_synthesis'
            );
            UPDATE memories
            SET importance = GREATEST(COALESCE(importance, 0.0), importance_value),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = row_claim.memory_id;
        END IF;

        UPDATE user_model_claims
        SET claim = normalized_claim,
            category = COALESCE(NULLIF(p_category, ''), category),
            confidence = GREATEST(confidence, confidence_value),
            importance = GREATEST(importance, importance_value),
            evidence_refs = refs,
            evidence_count = jsonb_array_length(refs),
            metadata = metadata || COALESCE(p_metadata, '{}'::jsonb),
            last_evidence_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = row_claim.id
        RETURNING * INTO row_claim;
    END IF;

    RETURN jsonb_build_object(
        'claim_id', row_claim.id::text,
        'claim_key', row_claim.claim_key,
        'memory_id', row_claim.memory_id::text,
        'created', inserted,
        'confidence', row_claim.confidence,
        'importance', row_claim.importance,
        'evidence_count', row_claim.evidence_count
    );
END;
$$;

CREATE OR REPLACE FUNCTION record_user_model_synthesis(
    p_source_item_id UUID,
    p_claims JSONB DEFAULT '[]'::jsonb,
    p_detector_version TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_item connector_source_items%ROWTYPE;
    claim_item JSONB;
    claim_result JSONB;
    results JSONB := '[]'::jsonb;
    claim_count INT := 0;
BEGIN
    SELECT *
    INTO row_item
    FROM connector_source_items
    WHERE id = p_source_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'connector source item not found: %', p_source_item_id;
    END IF;
    IF p_claims IS NULL OR jsonb_typeof(p_claims) <> 'array' THEN
        RAISE EXCEPTION 'claims must be a JSON array';
    END IF;

    FOR claim_item IN SELECT value FROM jsonb_array_elements(p_claims)
    LOOP
        IF jsonb_typeof(claim_item) <> 'object' THEN
            CONTINUE;
        END IF;
        IF NULLIF(btrim(COALESCE(claim_item->>'claim_key', '')), '') IS NULL
           OR NULLIF(btrim(COALESCE(claim_item->>'claim', '')), '') IS NULL THEN
            CONTINUE;
        END IF;
        claim_result := upsert_user_model_claim(
            claim_item->>'claim_key',
            claim_item->>'claim',
            COALESCE(NULLIF(claim_item->>'category', ''), 'preference'),
            COALESCE(NULLIF(claim_item->>'confidence', '')::float, 0.5),
            COALESCE(NULLIF(claim_item->>'importance', '')::float, 0.5),
            p_source_item_id,
            row_item.source_document_id,
            jsonb_build_object(
                'label', row_item.connector_id || ':' || row_item.provider_item_id,
                'trust', COALESCE(NULLIF(claim_item->>'evidence_trust', '')::float, 0.75)
            ),
            COALESCE(claim_item->'metadata', '{}'::jsonb)
                || jsonb_build_object('detector_version', p_detector_version)
        );
        results := results || jsonb_build_array(claim_result);
        claim_count := claim_count + 1;
    END LOOP;

    INSERT INTO user_model_source_progress (
        source_item_id, status, completed_at, detector_version, result
    )
    VALUES (
        p_source_item_id,
        'completed',
        CURRENT_TIMESTAMP,
        p_detector_version,
        jsonb_build_object('claim_count', claim_count, 'claims', results)
    )
    ON CONFLICT (source_item_id) DO UPDATE SET
        status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        detector_version = p_detector_version,
        result = jsonb_build_object('claim_count', claim_count, 'claims', results),
        updated_at = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object(
        'source_item_id', p_source_item_id::text,
        'claim_count', claim_count,
        'claims', results
    );
END;
$$;

CREATE OR REPLACE FUNCTION claim_connector_importance_items(
    p_limit INT DEFAULT NULL,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lim INT := GREATEST(COALESCE(p_limit, get_config_int('connector.importance_detection_batch_size'), 20), 1);
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('connector.importance_detection_claim_timeout_s'), 600);
    candidate RECORD;
    row_importance connector_item_importance%ROWTYPE;
    item JSONB;
    result JSONB := '[]'::jsonb;
BEGIN
    FOR candidate IN
        SELECT csi.id
        FROM connector_source_items csi
        JOIN source_documents d ON d.id = csi.source_document_id AND d.status = 'active'
        LEFT JOIN connector_item_importance i ON i.source_item_id = csi.id
        WHERE csi.status = 'active'
          AND (
                i.source_item_id IS NULL
             OR i.status = 'pending'
             OR (i.status = 'failed' AND i.attempts < 3)
             OR (i.status = 'in_progress'
                 AND i.claimed_at < CURRENT_TIMESTAMP - make_interval(secs => timeout_s))
          )
        ORDER BY COALESCE(csi.item_timestamp, csi.created_at), csi.id
        LIMIT lim
        FOR UPDATE OF csi SKIP LOCKED
    LOOP
        INSERT INTO connector_item_importance (
            source_item_id, connector_id, account_key, source_document_id,
            status, attempts, claimed_at, last_error
        )
        SELECT csi.id, csi.connector_id, csi.account_key, csi.source_document_id,
               'in_progress', 1, CURRENT_TIMESTAMP, NULL
        FROM connector_source_items csi
        WHERE csi.id = candidate.id
        ON CONFLICT (source_item_id) DO UPDATE SET
            status = 'in_progress',
            attempts = connector_item_importance.attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            last_error = NULL,
            updated_at = CURRENT_TIMESTAMP
        RETURNING * INTO row_importance;

        SELECT jsonb_build_object(
            'source_item_id', csi.id::text,
            'connector_id', csi.connector_id,
            'account_key', csi.account_key,
            'provider_item_id', csi.provider_item_id,
            'source_document_id', d.id::text,
            'title', d.title,
            'path', d.path,
            'content', d.content,
            'sensitivity', csi.sensitivity,
            'item_timestamp', csi.item_timestamp,
            'attempts', row_importance.attempts
        )
        INTO item
        FROM connector_source_items csi
        JOIN source_documents d ON d.id = csi.source_document_id
        WHERE csi.id = candidate.id;

        result := result || jsonb_build_array(item);
    END LOOP;

    RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION fail_connector_item_importance(
    p_source_item_id UUID,
    p_error TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_item connector_source_items%ROWTYPE;
    row_importance connector_item_importance%ROWTYPE;
BEGIN
    SELECT * INTO row_item FROM connector_source_items WHERE id = p_source_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'connector source item not found: %', p_source_item_id;
    END IF;

    INSERT INTO connector_item_importance (
        source_item_id, connector_id, account_key, source_document_id,
        status, attempts, last_error
    )
    VALUES (
        p_source_item_id, row_item.connector_id, row_item.account_key,
        row_item.source_document_id, 'failed', 1,
        COALESCE(NULLIF(p_error, ''), 'importance detection failed')
    )
    ON CONFLICT (source_item_id) DO UPDATE SET
        status = 'failed',
        last_error = COALESCE(NULLIF(p_error, ''), 'importance detection failed'),
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_importance;

    RETURN jsonb_build_object(
        'source_item_id', row_importance.source_item_id::text,
        'status', row_importance.status,
        'attempts', row_importance.attempts,
        'error', row_importance.last_error
    );
END;
$$;

CREATE OR REPLACE FUNCTION record_connector_item_importance(
    p_source_item_id UUID,
    p_score FLOAT,
    p_label TEXT DEFAULT NULL,
    p_reasons JSONB DEFAULT '[]'::jsonb,
    p_recommended_actions JSONB DEFAULT '[]'::jsonb,
    p_detector_version TEXT DEFAULT NULL,
    p_notify BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_item connector_source_items%ROWTYPE;
    row_doc source_documents%ROWTYPE;
    row_importance connector_item_importance%ROWTYPE;
    score_value FLOAT := LEAST(1.0, GREATEST(0.0, COALESCE(p_score, 0.0)));
    label_value TEXT;
    threshold FLOAT := COALESCE(get_config_float('connector.importance_notify_threshold'), 0.85);
    queued_id UUID := NULL;
BEGIN
    SELECT * INTO row_item FROM connector_source_items WHERE id = p_source_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'connector source item not found: %', p_source_item_id;
    END IF;
    SELECT * INTO row_doc FROM source_documents WHERE id = row_item.source_document_id;

    label_value := COALESCE(
        NULLIF(btrim(COALESCE(p_label, '')), ''),
        CASE
            WHEN score_value >= 0.95 THEN 'urgent'
            WHEN score_value >= threshold THEN 'important'
            WHEN score_value < 0.35 THEN 'low'
            ELSE 'normal'
        END
    );
    IF label_value NOT IN ('low', 'normal', 'important', 'urgent') THEN
        label_value := 'normal';
    END IF;

    INSERT INTO connector_item_importance (
        source_item_id, connector_id, account_key, source_document_id,
        score, label, reasons, recommended_actions, detector_version,
        status, claimed_at, last_error
    )
    VALUES (
        p_source_item_id, row_item.connector_id, row_item.account_key,
        row_item.source_document_id, score_value, label_value,
        CASE WHEN jsonb_typeof(COALESCE(p_reasons, '[]'::jsonb)) = 'array'
             THEN COALESCE(p_reasons, '[]'::jsonb) ELSE jsonb_build_array(p_reasons) END,
        CASE WHEN jsonb_typeof(COALESCE(p_recommended_actions, '[]'::jsonb)) = 'array'
             THEN COALESCE(p_recommended_actions, '[]'::jsonb) ELSE jsonb_build_array(p_recommended_actions) END,
        p_detector_version, 'completed', NULL, NULL
    )
    ON CONFLICT (source_item_id) DO UPDATE SET
        score = EXCLUDED.score,
        label = EXCLUDED.label,
        reasons = EXCLUDED.reasons,
        recommended_actions = EXCLUDED.recommended_actions,
        detector_version = EXCLUDED.detector_version,
        status = 'completed',
        claimed_at = NULL,
        last_error = NULL,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO row_importance;

    IF COALESCE(p_notify, TRUE)
       AND score_value >= threshold
       AND row_importance.notification_queued_at IS NULL THEN
        queued_id := queue_outbox_message(
            format(
                'Important %s item: %s%s%s',
                row_item.connector_id,
                COALESCE(row_doc.title, row_item.provider_item_id),
                E'\n',
                left(COALESCE(row_doc.content, ''), 600)
            ),
            'connector_importance',
            'connector_importance',
            jsonb_build_object(
                'mode', 'web_inbox',
                'source_item_id', p_source_item_id::text,
                'source_document_id', row_item.source_document_id::text,
                'connector_id', row_item.connector_id,
                'score', score_value,
                'label', label_value
            )
        );

        UPDATE connector_item_importance
        SET notification_queued_at = CURRENT_TIMESTAMP,
            metadata = metadata || jsonb_build_object('outbox_message_id', queued_id::text),
            updated_at = CURRENT_TIMESTAMP
        WHERE source_item_id = p_source_item_id
        RETURNING * INTO row_importance;
    END IF;

    RETURN jsonb_build_object(
        'source_item_id', row_importance.source_item_id::text,
        'connector_id', row_importance.connector_id,
        'score', row_importance.score,
        'label', row_importance.label,
        'status', row_importance.status,
        'notification_queued', queued_id IS NOT NULL,
        'notification_queued_at', row_importance.notification_queued_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION connector_cognition_status(
    p_connector_id TEXT DEFAULT NULL,
    p_account_key TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'user_model_progress', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'connector_id', t.connector_id,
                'account_key', t.account_key,
                'status', t.status,
                'count', t.count
            ) ORDER BY t.connector_id, t.account_key, t.status)
            FROM (
                SELECT csi.connector_id, csi.account_key, p.status, count(*)::int
                FROM user_model_source_progress p
                JOIN connector_source_items csi ON csi.id = p.source_item_id
                WHERE (p_connector_id IS NULL OR csi.connector_id = p_connector_id)
                  AND (p_account_key IS NULL OR csi.account_key = p_account_key)
                GROUP BY csi.connector_id, csi.account_key, p.status
            ) t
        ), '[]'::jsonb),
        'user_model_claims', (
            SELECT count(*)::int
            FROM user_model_claims
            WHERE status = 'active'
        ),
        'importance', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'connector_id', t.connector_id,
                'account_key', t.account_key,
                'label', t.label,
                'status', t.status,
                'count', t.count
            ) ORDER BY t.connector_id, t.account_key, t.label, t.status)
            FROM (
                SELECT connector_id, account_key, label, status, count(*)::int
                FROM connector_item_importance
                WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
                  AND (p_account_key IS NULL OR account_key = p_account_key)
                GROUP BY connector_id, account_key, label, status
            ) t
        ), '[]'::jsonb)
    );
$$;
