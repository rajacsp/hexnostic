-- 0126: portable-brain cleanup and cognition/retrieval v2 substrate.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

DROP FUNCTION IF EXISTS record_chat_turn(TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS record_subconscious_exchange(TEXT, JSONB);
DROP FUNCTION IF EXISTS upsert_user_model_claim(TEXT, TEXT, TEXT, FLOAT, FLOAT, UUID, UUID, JSONB, JSONB);

INSERT INTO config_defaults (key, value, description) VALUES
    ('connector.user_model_synthesis_mode', '"hybrid"'::jsonb,
     'User-model synthesis mode: rules, llm, or hybrid'),
    ('connector.user_model_review_required', 'true'::jsonb,
     'Derived user-model claims enter a review queue before being treated as operator-approved'),
    ('connector.user_model_llm_enabled', 'true'::jsonb,
     'Allow LLM-backed connector user-model synthesis when an LLM config is available'),
    ('connector.importance_llm_enabled', 'true'::jsonb,
     'Allow LLM-backed connector importance detection when an LLM config is available'),
    ('memory.recall_graph_adjacency_weight', '0.12'::jsonb,
     'How much typed memory_edges adjacency contributes to fused recall scoring'),
    ('reward.rpe_spike_threshold', '0.35'::jsonb,
     'Absolute reward-prediction error required to fire a dopamine spike'),
    ('reward.dopamine_spike_salience_threshold', '0.65'::jsonb,
     'Reward salience required to fire a dopamine spike from a generic reward event')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS review_status TEXT NOT NULL DEFAULT 'pending_review';
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS superseded_by UUID REFERENCES user_model_claims(id) ON DELETE SET NULL;
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS supersedes_claim_id UUID REFERENCES user_model_claims(id) ON DELETE SET NULL;
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS contradiction_refs JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ;
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS reviewed_by TEXT;
ALTER TABLE user_model_claims
    ADD COLUMN IF NOT EXISTS review_note TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'user_model_claims_review_status_check'
    ) THEN
        ALTER TABLE user_model_claims
            ADD CONSTRAINT user_model_claims_review_status_check
            CHECK (review_status IN ('pending_review', 'approved', 'rejected', 'superseded'));
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_user_model_claims_review
    ON user_model_claims (review_status, updated_at DESC);


CREATE TABLE IF NOT EXISTS user_model_review_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES user_model_claims(id) ON DELETE CASCADE,
    prior_status TEXT,
    prior_review_status TEXT,
    decision TEXT NOT NULL CHECK (decision IN ('approve', 'reject', 'supersede', 'restore')),
    note TEXT,
    actor TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_model_review_events_claim
    ON user_model_review_events (claim_id, created_at DESC);

CREATE OR REPLACE FUNCTION upsert_user_model_claim(
    p_claim_key TEXT,
    p_claim TEXT,
    p_category TEXT DEFAULT 'preference',
    p_confidence FLOAT DEFAULT 0.5,
    p_importance FLOAT DEFAULT 0.5,
    p_source_item_id UUID DEFAULT NULL,
    p_source_document_id UUID DEFAULT NULL,
    p_evidence JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_review_status TEXT DEFAULT NULL,
    p_supersedes_claim_key TEXT DEFAULT NULL,
    p_contradicts_claim_keys JSONB DEFAULT '[]'::jsonb
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
    review_value TEXT := COALESCE(NULLIF(btrim(COALESCE(p_review_status, '')), ''), 'pending_review');
    supersedes_id UUID := NULL;
    contradiction_ids JSONB := '[]'::jsonb;
    key_text TEXT;
    inserted BOOLEAN := FALSE;
BEGIN
    IF normalized_key IS NULL THEN
        RAISE EXCEPTION 'claim_key is required';
    END IF;
    IF normalized_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;
    IF review_value NOT IN ('pending_review', 'approved', 'rejected', 'superseded') THEN
        review_value := 'pending_review';
    END IF;

    IF NULLIF(btrim(COALESCE(p_supersedes_claim_key, '')), '') IS NOT NULL THEN
        SELECT id INTO supersedes_id
        FROM user_model_claims
        WHERE claim_key = lower(btrim(p_supersedes_claim_key));
    END IF;

    IF p_contradicts_claim_keys IS NOT NULL AND jsonb_typeof(p_contradicts_claim_keys) = 'array' THEN
        FOR key_text IN SELECT lower(btrim(value)) FROM jsonb_array_elements_text(p_contradicts_claim_keys) value
        LOOP
            IF key_text <> '' THEN
                contradiction_ids := contradiction_ids || COALESCE((
                    SELECT jsonb_build_array(jsonb_build_object(
                        'claim_id', id::text,
                        'claim_key', claim_key
                    ))
                    FROM user_model_claims
                    WHERE claim_key = key_text
                ), '[]'::jsonb);
            END IF;
        END LOOP;
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
            evidence_refs, evidence_count, review_status, supersedes_claim_id,
            contradiction_refs, metadata
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
            review_value,
            supersedes_id,
            contradiction_ids,
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
            review_status = CASE
                WHEN review_status = 'approved' AND review_value = 'pending_review' THEN review_status
                ELSE review_value
            END,
            supersedes_claim_id = COALESCE(supersedes_id, supersedes_claim_id),
            contradiction_refs = (
                SELECT COALESCE(jsonb_agg(DISTINCT elem), '[]'::jsonb)
                FROM jsonb_array_elements(
                    COALESCE(user_model_claims.contradiction_refs, '[]'::jsonb)
                    || COALESCE(contradiction_ids, '[]'::jsonb)
                ) elem
            ),
            metadata = metadata || COALESCE(p_metadata, '{}'::jsonb),
            last_evidence_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = row_claim.id
        RETURNING * INTO row_claim;
    END IF;

    IF supersedes_id IS NOT NULL AND supersedes_id <> row_claim.id THEN
        UPDATE user_model_claims
        SET status = 'superseded',
            review_status = 'superseded',
            superseded_by = row_claim.id,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = supersedes_id;

        UPDATE memories old_mem
        SET status = 'archived',
            superseded_by = row_claim.memory_id,
            updated_at = CURRENT_TIMESTAMP,
            metadata = old_mem.metadata || jsonb_build_object(
                'superseded_by_user_model_claim_id', row_claim.id::text
            )
        FROM user_model_claims old_claim
        WHERE old_claim.id = supersedes_id
          AND old_claim.memory_id = old_mem.id
          AND old_mem.status = 'active';
    END IF;

    RETURN jsonb_build_object(
        'claim_id', row_claim.id::text,
        'claim_key', row_claim.claim_key,
        'memory_id', row_claim.memory_id::text,
        'created', inserted,
        'review_status', row_claim.review_status,
        'status', row_claim.status,
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
                || jsonb_build_object('detector_version', p_detector_version),
            COALESCE(NULLIF(claim_item->>'review_status', ''), 'pending_review'),
            claim_item->>'supersedes_claim_key',
            COALESCE(claim_item->'contradicts_claim_keys', '[]'::jsonb)
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

CREATE OR REPLACE FUNCTION list_user_model_claims(
    p_status TEXT DEFAULT NULL,
    p_review_status TEXT DEFAULT NULL,
    p_category TEXT DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    WITH filtered AS (
        SELECT c.*
        FROM user_model_claims c
        WHERE (p_status IS NULL OR c.status = p_status)
          AND (p_review_status IS NULL OR c.review_status = p_review_status)
          AND (p_category IS NULL OR c.category = p_category)
    ),
    page AS (
        SELECT c.*
        FROM filtered c
        ORDER BY
            CASE c.review_status WHEN 'pending_review' THEN 0 ELSE 1 END,
            c.importance DESC,
            c.updated_at DESC
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
        OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT jsonb_build_object(
        'claims', COALESCE(jsonb_agg(jsonb_build_object(
            'id', page.id::text,
            'claim_key', page.claim_key,
            'category', page.category,
            'claim', page.claim,
            'memory_id', page.memory_id::text,
            'confidence', page.confidence,
            'importance', page.importance,
            'evidence_count', page.evidence_count,
            'evidence_refs', page.evidence_refs,
            'status', page.status,
            'review_status', page.review_status,
            'superseded_by', page.superseded_by::text,
            'supersedes_claim_id', page.supersedes_claim_id::text,
            'contradiction_refs', page.contradiction_refs,
            'metadata', page.metadata,
            'first_seen_at', page.first_seen_at,
            'last_evidence_at', page.last_evidence_at,
            'reviewed_at', page.reviewed_at,
            'reviewed_by', page.reviewed_by,
            'review_note', page.review_note
        ) ORDER BY
            CASE page.review_status WHEN 'pending_review' THEN 0 ELSE 1 END,
            page.importance DESC,
            page.updated_at DESC), '[]'::jsonb),
        'total', (SELECT count(*)::int FROM filtered),
        'limit', LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200),
        'offset', GREATEST(COALESCE(p_offset, 0), 0)
    )
    FROM page;
$$;

CREATE OR REPLACE FUNCTION review_user_model_claim(
    p_claim_id UUID,
    p_decision TEXT,
    p_note TEXT DEFAULT NULL,
    p_actor TEXT DEFAULT 'operator',
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_claim user_model_claims%ROWTYPE;
    prior_status TEXT;
    prior_review_status TEXT;
    decision_value TEXT := lower(NULLIF(btrim(COALESCE(p_decision, '')), ''));
BEGIN
    SELECT * INTO row_claim FROM user_model_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'user-model claim not found: %', p_claim_id;
    END IF;
    IF decision_value NOT IN ('approve', 'reject', 'supersede', 'restore') THEN
        RAISE EXCEPTION 'decision must be approve, reject, supersede, or restore';
    END IF;

    prior_status := row_claim.status;
    prior_review_status := row_claim.review_status;

    UPDATE user_model_claims
    SET status = CASE
            WHEN decision_value IN ('approve', 'restore') THEN 'active'
            WHEN decision_value = 'reject' THEN 'rejected'
            WHEN decision_value = 'supersede' THEN 'superseded'
            ELSE status
        END,
        review_status = CASE
            WHEN decision_value IN ('approve', 'restore') THEN 'approved'
            WHEN decision_value = 'reject' THEN 'rejected'
            WHEN decision_value = 'supersede' THEN 'superseded'
            ELSE review_status
        END,
        reviewed_at = CURRENT_TIMESTAMP,
        reviewed_by = COALESCE(NULLIF(p_actor, ''), 'operator'),
        review_note = NULLIF(p_note, ''),
        metadata = metadata || COALESCE(p_metadata, '{}'::jsonb),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_claim_id
    RETURNING * INTO row_claim;

    IF row_claim.memory_id IS NOT NULL THEN
        UPDATE memories
        SET status = CASE WHEN row_claim.status = 'active' THEN 'active'::memory_status ELSE 'archived'::memory_status END,
            updated_at = CURRENT_TIMESTAMP,
            metadata = metadata || jsonb_build_object(
                'user_model_review_status', row_claim.review_status,
                'user_model_reviewed_at', row_claim.reviewed_at
            )
        WHERE id = row_claim.memory_id;
    END IF;

    INSERT INTO user_model_review_events (
        claim_id, prior_status, prior_review_status, decision, note, actor, metadata
    )
    VALUES (
        p_claim_id, prior_status, prior_review_status, decision_value,
        NULLIF(p_note, ''), COALESCE(NULLIF(p_actor, ''), 'operator'),
        COALESCE(p_metadata, '{}'::jsonb)
    );

    RETURN jsonb_build_object(
        'claim_id', row_claim.id::text,
        'claim_key', row_claim.claim_key,
        'status', row_claim.status,
        'review_status', row_claim.review_status,
        'reviewed_at', row_claim.reviewed_at,
        'reviewed_by', row_claim.reviewed_by
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
        'user_model_review', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'review_status', review_status,
                'status', status,
                'count', count
            ) ORDER BY review_status, status)
            FROM (
                SELECT review_status, status, count(*)::int
                FROM user_model_claims
                GROUP BY review_status, status
            ) t
        ), '[]'::jsonb),
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
            'provider_status', 'planned',
            'estimated_items', 0,
            'estimated_pages', 0,
            'cost_class', 'unavailable',
            'limitations', 'Twitter/X OAuth and historical ingestion are planned but no provider adapter is available yet.'
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

CREATE OR REPLACE FUNCTION enqueue_connector_backfill_job(
    p_connector_id TEXT,
    p_account_key TEXT,
    p_cursor_key TEXT DEFAULT 'messages',
    p_requested_range JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_max_attempts INT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_connection integration_connections%ROWTYPE;
    row_job connector_backfill_jobs%ROWTYPE;
    normalized_cursor TEXT := COALESCE(NULLIF(btrim(p_cursor_key), ''), 'messages');
    existing_id UUID;
BEGIN
    row_connection := _connector_connection(p_connector_id, p_account_key);
    PERFORM ensure_connector_cursor(
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_metadata, '{}'::jsonb)
    );

    SELECT id
    INTO existing_id
    FROM connector_backfill_jobs
    WHERE connection_id = row_connection.id
      AND cursor_key = normalized_cursor
      AND status IN ('pending', 'in_progress', 'paused')
    ORDER BY created_at DESC
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
        SELECT * INTO row_job FROM connector_backfill_jobs WHERE id = existing_id;
        RETURN jsonb_build_object(
            'job_id', row_job.id::text,
            'existing', TRUE,
            'status', row_job.status,
            'connector_id', row_job.connector_id,
            'account_key', row_job.account_key,
            'cursor_key', row_job.cursor_key,
            'requested_range', row_job.requested_range,
            'estimate', estimate_connector_backfill(row_job.connector_id, row_job.requested_range),
            'progress', row_job.progress
        );
    END IF;

    INSERT INTO connector_backfill_jobs (
        connection_id,
        connector_id,
        account_key,
        cursor_key,
        requested_range,
        metadata,
        max_attempts
    )
    VALUES (
        row_connection.id,
        row_connection.connector_id,
        row_connection.account_key,
        normalized_cursor,
        COALESCE(p_requested_range, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        GREATEST(COALESCE(p_max_attempts, 3), 1)
    )
    RETURNING * INTO row_job;

    RETURN jsonb_build_object(
        'job_id', row_job.id::text,
        'existing', FALSE,
        'status', row_job.status,
        'connector_id', row_job.connector_id,
        'account_key', row_job.account_key,
        'cursor_key', row_job.cursor_key,
        'requested_range', row_job.requested_range,
        'estimate', estimate_connector_backfill(row_job.connector_id, row_job.requested_range),
        'progress', row_job.progress,
        'next_attempt_at', row_job.next_attempt_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_connector_backfill_status(
    p_connector_id TEXT DEFAULT NULL,
    p_account_key TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    cursors JSONB;
    jobs JSONB;
    item_counts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'cursor_id', id::text,
            'connection_id', connection_id::text,
            'connector_id', connector_id,
            'account_key', account_key,
            'cursor_key', cursor_key,
            'cursor_value', cursor_value,
            'high_watermark', high_watermark,
            'status', status,
            'last_started_at', last_started_at,
            'last_completed_at', last_completed_at,
            'last_error', last_error,
            'updated_at', updated_at
        )
        ORDER BY updated_at DESC, connector_id, account_key, cursor_key
    ), '[]'::jsonb)
    INTO cursors
    FROM connector_sync_cursors
    WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
      AND (p_account_key IS NULL OR account_key = p_account_key);

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'job_id', id::text,
            'connection_id', connection_id::text,
            'connector_id', connector_id,
            'account_key', account_key,
            'cursor_key', cursor_key,
            'status', status,
            'attempts', attempts,
            'max_attempts', max_attempts,
            'progress', progress,
            'result', result,
            'estimate', estimate_connector_backfill(connector_id, requested_range),
            'error', error,
            'cancel_requested', cancel_requested,
            'pause_requested', pause_requested,
            'next_attempt_at', next_attempt_at,
            'claimed_at', claimed_at,
            'completed_at', completed_at,
            'updated_at', updated_at
        )
        ORDER BY created_at DESC
    ), '[]'::jsonb)
    INTO jobs
    FROM connector_backfill_jobs
    WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
      AND (p_account_key IS NULL OR account_key = p_account_key)
      AND created_at >= CURRENT_TIMESTAMP - INTERVAL '7 days';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'connector_id', connector_id,
            'account_key', account_key,
            'item_kind', item_kind,
            'status', status,
            'count', item_count,
            'latest_item_at', latest_item_at
        )
        ORDER BY connector_id, account_key, item_kind, status
    ), '[]'::jsonb)
    INTO item_counts
    FROM (
        SELECT
            connector_id,
            account_key,
            item_kind,
            status,
            COUNT(*)::INT AS item_count,
            MAX(item_timestamp) AS latest_item_at
        FROM connector_source_items
        WHERE (p_connector_id IS NULL OR connector_id = p_connector_id)
          AND (p_account_key IS NULL OR account_key = p_account_key)
        GROUP BY connector_id, account_key, item_kind, status
    ) grouped;

    RETURN jsonb_build_object(
        'cursors', cursors,
        'jobs', jobs,
        'item_counts', item_counts
    );
END;
$$;

CREATE TABLE IF NOT EXISTS graph_reconciliation_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    repair BOOLEAN NOT NULL DEFAULT TRUE,
    dangling_edges INT NOT NULL DEFAULT 0,
    deleted_edges INT NOT NULL DEFAULT 0,
    age_backfilled_edges INT,
    result JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION reconcile_graph(
    p_repair BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    dangling_count INT := 0;
    deleted_count INT := 0;
    backfilled_count INT := NULL;
    result JSONB;
BEGIN
    SELECT count(*)::int
    INTO dangling_count
    FROM memory_edges e
    WHERE (e.src_type = 'memory' AND NOT EXISTS (
              SELECT 1 FROM memories m
              WHERE m.id = _safe_uuid(e.src_id)
                AND m.status = 'active'
                AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          ))
       OR (e.dst_type = 'memory' AND NOT EXISTS (
              SELECT 1 FROM memories m
              WHERE m.id = _safe_uuid(e.dst_id)
                AND m.status = 'active'
                AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          ));

    IF COALESCE(p_repair, TRUE) AND dangling_count > 0 THEN
        WITH deleted AS (
            DELETE FROM memory_edges e
            WHERE (e.src_type = 'memory' AND NOT EXISTS (
                      SELECT 1 FROM memories m
                      WHERE m.id = _safe_uuid(e.src_id)
                        AND m.status = 'active'
                        AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
                  ))
               OR (e.dst_type = 'memory' AND NOT EXISTS (
                      SELECT 1 FROM memories m
                      WHERE m.id = _safe_uuid(e.dst_id)
                        AND m.status = 'active'
                        AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
                  ))
            RETURNING 1
        )
        SELECT count(*)::int INTO deleted_count FROM deleted;
    END IF;

    BEGIN
        IF COALESCE(p_repair, TRUE)
           AND to_regproc('public.backfill_memory_edges') IS NOT NULL THEN
            SELECT backfill_memory_edges() INTO backfilled_count;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        backfilled_count := NULL;
    END;

    result := jsonb_build_object(
        'repair', COALESCE(p_repair, TRUE),
        'dangling_edges', dangling_count,
        'deleted_edges', deleted_count,
        'age_backfilled_edges', backfilled_count,
        'status', CASE WHEN dangling_count = 0 OR COALESCE(p_repair, TRUE) THEN 'ok' ELSE 'needs_repair' END
    );

    INSERT INTO graph_reconciliation_runs (
        repair, dangling_edges, deleted_edges, age_backfilled_edges, result
    )
    VALUES (
        COALESCE(p_repair, TRUE), dangling_count, deleted_count, backfilled_count, result
    );

    RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION memory_graph_paths(
    p_seed_id UUID,
    p_rel_types TEXT[] DEFAULT ARRAY['CAUSES','CONTRADICTS','CONTESTED_BECAUSE','SUPPORTS','SUPERSEDES'],
    p_depth INT DEFAULT 3,
    p_limit INT DEFAULT 25
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE walk AS (
        SELECT
            e.id AS edge_id,
            e.src_type,
            e.src_id,
            e.rel_type,
            e.dst_type,
            e.dst_id,
            e.weight,
            1 AS depth,
            ARRAY[e.src_type || ':' || e.src_id, e.dst_type || ':' || e.dst_id] AS visited,
            jsonb_build_array(jsonb_build_object(
                'src_type', e.src_type,
                'src_id', e.src_id,
                'rel', e.rel_type,
                'dst_type', e.dst_type,
                'dst_id', e.dst_id,
                'weight', e.weight
            )) AS edges
        FROM memory_edges e
        WHERE ((e.src_type = 'memory' AND e.src_id = p_seed_id::text)
           OR (e.dst_type = 'memory' AND e.dst_id = p_seed_id::text))
          AND (p_rel_types IS NULL OR e.rel_type = ANY(p_rel_types))
        UNION ALL
        SELECT
            e.id,
            e.src_type,
            e.src_id,
            e.rel_type,
            e.dst_type,
            e.dst_id,
            e.weight,
            w.depth + 1,
            w.visited || CASE
                WHEN e.src_type || ':' || e.src_id = w.visited[array_length(w.visited, 1)]
                THEN e.dst_type || ':' || e.dst_id
                ELSE e.src_type || ':' || e.src_id
            END,
            w.edges || jsonb_build_array(jsonb_build_object(
                'src_type', e.src_type,
                'src_id', e.src_id,
                'rel', e.rel_type,
                'dst_type', e.dst_type,
                'dst_id', e.dst_id,
                'weight', e.weight
            ))
        FROM walk w
        JOIN memory_edges e
          ON (e.src_type || ':' || e.src_id = w.visited[array_length(w.visited, 1)]
              OR e.dst_type || ':' || e.dst_id = w.visited[array_length(w.visited, 1)])
        WHERE w.depth < LEAST(GREATEST(COALESCE(p_depth, 3), 1), 6)
          AND (p_rel_types IS NULL OR e.rel_type = ANY(p_rel_types))
          AND NOT (
              CASE
                WHEN e.src_type || ':' || e.src_id = w.visited[array_length(w.visited, 1)]
                THEN e.dst_type || ':' || e.dst_id
                ELSE e.src_type || ':' || e.src_id
              END = ANY(w.visited)
          )
    ),
    ranked AS (
        SELECT *
        FROM walk
        ORDER BY depth ASC, weight DESC
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100)
    )
    SELECT jsonb_build_object(
        'seed_id', p_seed_id::text,
        'paths', COALESCE(jsonb_agg(jsonb_build_object(
            'depth', depth,
            'terminal', visited[array_length(visited, 1)],
            'visited', to_jsonb(visited),
            'edges', edges
        ) ORDER BY depth), '[]'::jsonb)
    )
    FROM ranked;
$$;

CREATE OR REPLACE FUNCTION memory_context_paths(
    p_seed_ids UUID[],
    p_depth INT DEFAULT 2
) RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'seeds', COALESCE((SELECT jsonb_agg(s::text) FROM unnest(COALESCE(p_seed_ids, ARRAY[]::uuid[])) s), '[]'::jsonb),
        'paths', COALESCE(jsonb_agg(path_doc), '[]'::jsonb)
    )
    FROM (
        SELECT memory_graph_paths(seed_id, ARRAY['CAUSES','CONTRADICTS','CONTESTED_BECAUSE','SUPPORTS','SUPERSEDES'], p_depth, 10) AS path_doc
        FROM unnest(COALESCE(p_seed_ids, ARRAY[]::uuid[])) seed_id
    ) q;
$$;

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    -- Sensitivity enforcement (#92): group channels and other shared
    -- surfaces recall with this TRUE; the agent's own 1:1 recall keeps
    -- everything. The prompt's privacy promise, made mechanical.
    p_exclude_sensitive BOOLEAN DEFAULT FALSE,
    -- Knowledge tier budget (#96 fusion): procedural, strategic, worldview,
    -- and goal memories join recall — one mind, one retrieval mechanism.
    p_k_know INT DEFAULT 5
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    fidelity FLOAT,
    strength FLOAT,
    emotional_intensity FLOAT,
    confidence FLOAT,
    retrieval_source TEXT
) AS $$
DECLARE
    query_embedding vector;
    zero_vec vector;
    strength_weight FLOAT;
    intensity_weight FLOAT;
    recency_weight FLOAT;
    recency_halflife FLOAT;
    boost_weight FLOAT;
    graph_weight FLOAT;
    min_trust FLOAT;
    current_valence FLOAT;
    current_arousal FLOAT;
    current_primary TEXT;
    affective_state JSONB;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1];
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    -- The unified ranker (#96, completing #57's "unification, first step"):
    -- recmem's tier skeleton with fast_recall's full scoring transplanted —
    -- associations, episode-temporal binding, mood congruence, trust floor,
    -- and the activation-boost term that lets incubation and reward actually
    -- change what comes to mind.
    recency_weight := COALESCE(get_config_float('memory.recency_weight'), 0.1);
    recency_halflife := GREATEST(COALESCE(get_config_float('memory.recency_halflife_days'), 7.0), 0.01);
    strength_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_strength_weight'), 0.5)));
    intensity_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_intensity_weight'), 0.5)));
    boost_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_activation_boost_weight'), 0.3)));
    graph_weight := LEAST(1.0, GREATEST(0.0, COALESCE(get_config_float('memory.recall_graph_adjacency_weight'), 0.12)));
    min_trust := COALESCE(get_config_float('memory.recall_min_trust_level'), 0.0);

    -- Mood-congruent recall: the current affective state colors what
    -- surfaces, exactly as it did in fast_recall.
    affective_state := get_current_affective_state();
    BEGIN
        current_valence := NULLIF(affective_state->>'valence', '')::float;
    EXCEPTION WHEN OTHERS THEN current_valence := NULL; END;
    BEGIN
        current_arousal := NULLIF(affective_state->>'arousal', '')::float;
    EXCEPTION WHEN OTHERS THEN current_arousal := NULL; END;
    BEGIN
        current_primary := NULLIF(affective_state->>'primary_emotion', '');
    EXCEPTION WHEN OTHERS THEN current_primary := NULL; END;
    current_valence := COALESCE(current_valence, 0.0);
    current_arousal := COALESCE(current_arousal, 0.5);
    current_primary := COALESCE(current_primary, 'neutral');

    RETURN QUERY
    WITH raw_hits AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            (1 - (s.embedding <=> query_embedding))::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity,
            NULL::float AS confidence,
            'vector'::text AS retrieval_source
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
          AND s.embedding <> zero_vec
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
        ORDER BY s.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sub, 10), 0)
    ),
    recent_unembedded AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            0.2::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            1.0::float AS fidelity,
            1.0::float AS strength,
            NULL::float AS emotional_intensity,
            NULL::float AS confidence,
            'temporal'::text AS retrieval_source
        FROM subconscious_units s
        WHERE p_session_id IS NOT NULL
          AND s.session_id = p_session_id
          AND s.status = 'active'
          AND s.embedding_status <> 'embedded'
          AND (NOT p_exclude_sensitive
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
        ORDER BY s.created_at DESC
        LIMIT 3
    ),
    -- Shared candidate machinery: ONE ANN scan seeds all memory tiers, and
    -- the association/temporal expansions run once over that shared pool —
    -- never per tier (#96 hot-path requirement).
    -- Per-type-group seed scans: each tier is GUARANTEED candidates of its
    -- own type (a type-blind shared pool lets the episodic bulk crowd rare
    -- types out entirely). The expensive shared machinery — association
    -- expansion and episode binding — still runs once over the union.
    mem_seeds AS (
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type = 'episodic'
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_epi, 5), 0) * 2)
        UNION ALL
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type = 'semantic'
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_sem, 10), 0) * 2)
        UNION ALL
        (SELECT m.id, (1 - (m.embedding <=> query_embedding))::float AS sim
         FROM memories m
         WHERE m.status = 'active'
           AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
           AND m.type::text IN ('procedural', 'strategic', 'worldview', 'goal')
           AND m.embedding IS NOT NULL AND m.embedding <> zero_vec
           AND (NOT p_exclude_sensitive
                OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
         ORDER BY m.embedding <=> query_embedding
         LIMIT GREATEST(COALESCE(p_k_know, 5), 0) * 2)
    ),
    associations AS (
        -- Spreading activation through precomputed neighborhoods.
        SELECT (n.key)::uuid AS mem_id, MAX((n.value)::float * s.sim) AS assoc_score
        FROM mem_seeds s
        JOIN memory_neighborhoods mn ON s.id = mn.memory_id,
        LATERAL jsonb_each_text(mn.neighbors) n
        WHERE NOT mn.is_stale
        GROUP BY (n.key)::uuid
    ),
    temporal AS (
        -- Episode binding: what belongs to the open or just-closed episode
        -- stays near the surface.
        SELECT DISTINCT fem.memory_id AS mem_id, 0.15::float AS temp_score
        FROM episodes e
        CROSS JOIN LATERAL find_episode_memories_graph(e.id) fem
        WHERE e.ended_at IS NULL
           OR e.ended_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
        LIMIT 20
    ),
    graph_adj AS (
        -- Typed graph adjacency: if vector recall catches one memory in a
        -- causal/contradictory/supporting cluster, its immediate typed
        -- neighbors receive a small candidate signal. This is distinct from
        -- embedding neighborhoods and preserves deliberate graph structure.
        SELECT neighbor_id::uuid AS mem_id, MAX(edge_signal) AS graph_score
        FROM (
            SELECT e.dst_id AS neighbor_id, COALESCE(e.weight, 1.0) * s.sim AS edge_signal
            FROM mem_seeds s
            JOIN memory_edges e
              ON e.src_type = 'memory'
             AND e.src_id = s.id::text
             AND e.dst_type = 'memory'
            WHERE e.rel_type IN ('SUPPORTS','CONTRADICTS','CAUSES','CONTESTED_BECAUSE','RELATED_TO','SUPERSEDES')
              AND _safe_uuid(e.dst_id) IS NOT NULL
            UNION ALL
            SELECT e.src_id AS neighbor_id, COALESCE(e.weight, 1.0) * s.sim AS edge_signal
            FROM mem_seeds s
            JOIN memory_edges e
              ON e.dst_type = 'memory'
             AND e.dst_id = s.id::text
             AND e.src_type = 'memory'
            WHERE e.rel_type IN ('SUPPORTS','CONTRADICTS','CAUSES','CONTESTED_BECAUSE','RELATED_TO','SUPERSEDES')
              AND _safe_uuid(e.src_id) IS NOT NULL
        ) g
        GROUP BY neighbor_id::uuid
    ),
    candidate_ids AS (
        SELECT s.id AS mem_id, s.sim AS vector_score, NULL::float AS assoc_score, NULL::float AS temp_score, NULL::float AS graph_score
        FROM mem_seeds s
        UNION
        SELECT a.mem_id, NULL, a.assoc_score, NULL, NULL FROM associations a
        UNION
        SELECT tp.mem_id, NULL, NULL, tp.temp_score, NULL FROM temporal tp
        UNION
        SELECT ga.mem_id, NULL, NULL, NULL, ga.graph_score FROM graph_adj ga
    ),
    candidates AS (
        SELECT c.mem_id,
               MAX(c.vector_score) AS vector_score,
               MAX(c.assoc_score) AS assoc_score,
               MAX(c.temp_score) AS temp_score,
               MAX(c.graph_score) AS graph_score
        FROM candidate_ids c
        GROUP BY c.mem_id
    ),
    scored AS (
        SELECT
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            m.type AS mtype,
            GREATEST(
                COALESCE(c.vector_score, (1 - (m.embedding <=> query_embedding)))
                  * (1.0 - strength_weight + strength_weight
                     * GREATEST(
                         calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced),
                         intensity_weight * current_emotional_intensity(
                             (m.metadata->'emotional_context'->>'intensity')::float,
                             (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)))
                + COALESCE(c.assoc_score, 0) * 0.2
                + COALESCE(c.temp_score, 0)
                + COALESCE(c.graph_score, 0) * graph_weight
                + recency_weight * exp(-ln(2.0) * GREATEST(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - m.created_at)), 0)
                                       / (86400.0 * recency_halflife))
                + COALESCE(m.trust_level, 0.5) * 0.1
                -- Reward/incubation salience: boosted memories genuinely come
                -- to mind more easily until the boost decays.
                + LEAST(1.0, GREATEST(0.0, COALESCE((m.metadata->>'activation_boost')::float, 0.0))) * boost_weight
                -- Mood congruence (transplanted from fast_recall, weight 0.05).
                + (CASE
                       WHEN m.metadata ? 'emotional_context' THEN
                           (COALESCE(
                                CASE WHEN (m.metadata->'emotional_context'->>'valence') IS NULL THEN NULL
                                     ELSE 1.0 - (ABS((m.metadata->'emotional_context'->>'valence')::float - current_valence) / 2.0)
                                END, 0.5) * 0.6
                            + COALESCE(
                                CASE WHEN (m.metadata->'emotional_context'->>'arousal') IS NULL THEN NULL
                                     ELSE 1.0 - ABS((m.metadata->'emotional_context'->>'arousal')::float - current_arousal)
                                END, 0.5) * 0.3
                            + (CASE
                                   WHEN (m.metadata->'emotional_context'->>'primary_emotion') IS NULL THEN 0.5
                                   WHEN (m.metadata->'emotional_context'->>'primary_emotion') = current_primary THEN 1.0
                                   ELSE 0.7
                               END) * 0.1)
                       ELSE
                           CASE WHEN (m.metadata->>'emotional_valence') IS NULL THEN 0.5
                                ELSE 1.0 - (ABS((m.metadata->>'emotional_valence')::float - current_valence) / 2.0)
                           END
                   END) * 0.05,
                0.001)::float AS score,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            m.fidelity,
            calculate_strength(m.importance, m.decay_rate, m.created_at, m.last_reinforced)::float AS strength,
            (current_emotional_intensity((m.metadata->'emotional_context'->>'intensity')::float,
                (m.metadata->>'emotional_valence')::float, m.created_at, m.last_reinforced)
             * SIGN(COALESCE((m.metadata->>'emotional_valence')::float, 0)))::float AS emotional_intensity,
            (m.metadata->>'confidence')::float AS confidence,
            CASE
                WHEN c.vector_score IS NOT NULL THEN 'vector'
                WHEN c.assoc_score IS NOT NULL THEN 'association'
                WHEN c.temp_score IS NOT NULL THEN 'temporal'
                WHEN c.graph_score IS NOT NULL THEN 'graph'
                ELSE 'fallback'
            END AS retrieval_source
        FROM candidates c
        JOIN memories m ON m.id = c.mem_id
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.embedding IS NOT NULL
          AND m.embedding <> zero_vec
          AND m.trust_level >= min_trust
          AND (NOT p_exclude_sensitive
               OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private')
    ),
    with_units AS (
        SELECT sc.*, COALESCE(
                   (SELECT array_agg(msu.subconscious_unit_id)
                    FROM memory_source_units msu
                    WHERE msu.memory_id = sc.item_id), '{}'::uuid[]) AS source_unit_ids
        FROM scored sc
    ),
    epi_hits AS (
        SELECT 'episodic'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype = 'episodic'
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_epi, 5), 0)
    ),
    sem_hits AS (
        SELECT 'semantic'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype = 'semantic'
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_sem, 10), 0)
    ),
    know_hits AS (
        SELECT 'knowledge'::text AS tier, w.item_id, w.content, w.memory_type, w.score,
               w.source_unit_ids, w.source_attribution, w.created_at, w.trust_level,
               w.fidelity, w.strength, w.emotional_intensity, w.confidence,
               w.retrieval_source
        FROM with_units w WHERE w.mtype::text IN ('procedural', 'strategic', 'worldview', 'goal')
        ORDER BY w.score DESC LIMIT GREATEST(COALESCE(p_k_know, 5), 0)
    ),
    spontaneous_hits AS (
        -- What's on her mind arrives unbidden (#98): strongly boosted
        -- memories (incubation resolutions, reward spikes) join recall even
        -- when the query didn't ask for them — then fade with boost decay.
        SELECT
            'spontaneous'::text AS tier,
            sm.id AS item_id,
            sm.content,
            sm.type::text AS memory_type,
            LEAST(1.0, COALESCE((sm.metadata->>'activation_boost')::float, 0.0))::float AS score,
            COALESCE((SELECT array_agg(msu.subconscious_unit_id)
                      FROM memory_source_units msu WHERE msu.memory_id = sm.id), '{}'::uuid[]) AS source_unit_ids,
            sm.source_attribution,
            sm.created_at,
            sm.trust_level,
            sm.fidelity,
            calculate_strength(sm.importance, sm.decay_rate, sm.created_at, sm.last_reinforced)::float AS strength,
            NULL::float AS emotional_intensity,
            (sm.metadata->>'confidence')::float AS confidence,
            'spontaneous'::text AS retrieval_source
        FROM get_spontaneous_memories(2) sm
        WHERE (NOT p_exclude_sensitive
               OR COALESCE(sm.source_attribution->>'sensitivity', '') <> 'private')
          AND sm.id NOT IN (
              SELECT h.item_id FROM epi_hits h
              UNION ALL SELECT h.item_id FROM sem_hits h
              UNION ALL SELECT h.item_id FROM know_hits h)
    )
    SELECT * FROM raw_hits
    UNION ALL
    SELECT * FROM recent_unembedded
    UNION ALL
    SELECT * FROM epi_hits
    UNION ALL
    SELECT * FROM sem_hits
    UNION ALL
    SELECT * FROM know_hits
    UNION ALL
    SELECT * FROM spontaneous_hits
    ORDER BY tier, score DESC, created_at DESC;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fire_dopamine_spike(
    p_rpe FLOAT,
    p_trigger TEXT DEFAULT '',
    p_retroactive_window INTERVAL DEFAULT INTERVAL '30 minutes'
)
RETURNS JSONB AS $$
DECLARE
    state JSONB;
    old_tonic FLOAT;
    new_tonic FLOAT;
    ema_alpha FLOAT := 0.15;  -- how fast tonic tracks phasic events
    boosted_count INT := 0;
    spread_count INT := 0;
    mem RECORD;
    neighbor_id UUID;
    neighbor_ids UUID[];
    current_boost FLOAT;
    boost_delta FLOAT;
    importance_delta FLOAT;
    abs_rpe FLOAT;
BEGIN
    abs_rpe := ABS(p_rpe);

    -- 1. Read current tonic
    state := get_current_affective_state();
    BEGIN old_tonic := NULLIF(state->>'dopamine_tonic', '')::float;
    EXCEPTION WHEN OTHERS THEN old_tonic := NULL; END;
    old_tonic := COALESCE(old_tonic, 0.5);

    -- EMA update: positive RPE pushes tonic up, negative pushes down
    -- Map RPE [-1,1] to target [0,1]: target = 0.5 + rpe * 0.5
    new_tonic := old_tonic * (1.0 - ema_alpha) + (0.5 + p_rpe * 0.5) * ema_alpha;
    new_tonic := LEAST(1.0, GREATEST(0.0, new_tonic));

    -- 2. Retroactive memory modulation
    -- Boost or suppress memories created within the retroactive window
    IF p_rpe > 0 THEN
        -- Positive RPE: enhance recent memories
        boost_delta := p_rpe * 0.4;       -- activation boost up to +0.4
        importance_delta := p_rpe * 0.12;  -- importance boost up to +0.12
    ELSE
        -- Negative RPE: suppress recent memories
        boost_delta := p_rpe * 0.25;       -- activation suppression up to -0.25
        importance_delta := p_rpe * 0.05;  -- slight importance reduction
    END IF;

    FOR mem IN
        SELECT id, metadata, importance
        FROM memories
        WHERE status = 'active'
          AND created_at >= CURRENT_TIMESTAMP - p_retroactive_window
        ORDER BY created_at DESC
        LIMIT 50  -- safety cap
    LOOP
        current_boost := COALESCE((mem.metadata->>'activation_boost')::float, 0);

        UPDATE memories
        SET metadata = jsonb_set(
                jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{activation_boost}',
                    to_jsonb(LEAST(1.0, GREATEST(0, current_boost + boost_delta)))
                ),
                '{dopamine_spike_rpe}',
                to_jsonb(p_rpe)
            ),
            importance = LEAST(1.0, GREATEST(0.1, importance + importance_delta))
        WHERE id = mem.id;

        boosted_count := boosted_count + 1;

        -- 3. Spread activation through neighborhoods (positive RPE only)
        IF p_rpe > 0 THEN
            SELECT ARRAY(
                SELECT (kv.value)::uuid
                FROM jsonb_each_text(
                    COALESCE(
                        (SELECT neighbors FROM memory_neighborhoods WHERE memory_id = mem.id),
                        '{}'::jsonb
                    )
                ) AS kv
                LIMIT 5  -- top 5 neighbors
            ) INTO neighbor_ids;

            IF neighbor_ids IS NOT NULL AND array_length(neighbor_ids, 1) > 0 THEN
                UPDATE memories
                SET metadata = jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{activation_boost}',
                    to_jsonb(LEAST(1.0, GREATEST(0,
                        COALESCE((metadata->>'activation_boost')::float, 0) + p_rpe * 0.15
                    )))
                )
                WHERE id = ANY(neighbor_ids)
                  AND status = 'active';

                GET DIAGNOSTICS spread_count = ROW_COUNT;
            END IF;
        END IF;
    END LOOP;

    -- 4. Modulate drives
    IF p_rpe > 0 THEN
        -- Positive RPE: satisfy curiosity + connection, reduce rest urgency
        UPDATE drives SET
            current_level = GREATEST(0, current_level - abs_rpe * 0.15),
            last_satisfied = CURRENT_TIMESTAMP
        WHERE name IN ('curiosity', 'connection');

        UPDATE drives SET
            current_level = GREATEST(0, current_level - abs_rpe * 0.1)
        WHERE name = 'rest';
    ELSE
        -- Negative RPE: increase rest drive, build coherence need
        UPDATE drives SET
            current_level = LEAST(1.0, current_level + abs_rpe * 0.1)
        WHERE name = 'rest';

        UPDATE drives SET
            current_level = LEAST(1.0, current_level + abs_rpe * 0.08)
        WHERE name = 'coherence';
    END IF;

    -- 5. Record spike in affective state
    PERFORM set_current_affective_state(jsonb_build_object(
        'dopamine_tonic', new_tonic,
        'dopamine_phasic', p_rpe,
        'dopamine_spike_at', CURRENT_TIMESTAMP,
        'dopamine_spike_rpe', p_rpe,
        'dopamine_spike_trigger', LEFT(COALESCE(p_trigger, ''), 500)
    ));

    BEGIN
        PERFORM record_reward_event(
            'dopamine_spike',
            p_rpe,
            abs_rpe,
            'dopamine',
            jsonb_build_object('trigger', LEFT(COALESCE(p_trigger, ''), 500))
        );
    EXCEPTION WHEN undefined_function THEN
        NULL;
    END;

    RETURN jsonb_build_object(
        'fired', true,
        'rpe', p_rpe,
        'tonic_old', old_tonic,
        'tonic_new', new_tonic,
        'memories_boosted', boosted_count,
        'neighbors_spread', spread_count,
        'trigger', LEFT(COALESCE(p_trigger, ''), 200)
    );
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- dopamine_decay_multiplier()  —  pure function
--
-- High dopamine → slower activation decay (reward memories persist).
-- Returns 0.3 – 1.0.   At tonic 0.5 (neutral) returns ~0.65.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS reward_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL,
    valence FLOAT NOT NULL DEFAULT 0.0 CHECK (valence >= -1.0 AND valence <= 1.0),
    salience FLOAT NOT NULL DEFAULT 0.5 CHECK (salience >= 0.0 AND salience <= 1.0),
    source TEXT NOT NULL DEFAULT 'unknown',
    expected FLOAT CHECK (expected IS NULL OR (expected >= -1.0 AND expected <= 1.0)),
    actual FLOAT CHECK (actual IS NULL OR (actual >= -1.0 AND actual <= 1.0)),
    rpe FLOAT CHECK (rpe IS NULL OR (rpe >= -1.0 AND rpe <= 1.0)),
    memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_reward_events_kind_created
    ON reward_events (kind, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reward_events_rpe_created
    ON reward_events (rpe, created_at DESC)
    WHERE rpe IS NOT NULL;

CREATE OR REPLACE FUNCTION record_reward_event(
    p_kind TEXT,
    p_valence FLOAT,
    p_salience FLOAT DEFAULT 0.5,
    p_source TEXT DEFAULT 'agent',
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_memory_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_event reward_events%ROWTYPE;
    val FLOAT := LEAST(1.0, GREATEST(-1.0, COALESCE(p_valence, 0.0)));
    sal FLOAT := LEAST(1.0, GREATEST(0.0, COALESCE(p_salience, ABS(COALESCE(p_valence, 0.0)), 0.5)));
BEGIN
    INSERT INTO reward_events (kind, valence, salience, source, memory_id, metadata)
    VALUES (
        COALESCE(NULLIF(btrim(p_kind), ''), 'reward'),
        val,
        sal,
        COALESCE(NULLIF(btrim(p_source), ''), 'agent'),
        p_memory_id,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING * INTO row_event;

    IF row_event.kind <> 'dopamine_spike'
       AND sal >= COALESCE(get_config_float('reward.dopamine_spike_salience_threshold'), 0.65) THEN
        PERFORM fire_dopamine_spike(
            val * sal,
            COALESCE(NULLIF(p_kind, ''), 'reward') || ': ' || COALESCE(p_metadata->>'summary', '')
        );
    END IF;

    RETURN jsonb_build_object(
        'event_id', row_event.id::text,
        'kind', row_event.kind,
        'valence', row_event.valence,
        'salience', row_event.salience,
        'source', row_event.source
    );
END;
$$;

CREATE OR REPLACE FUNCTION record_prediction_error(
    p_expected FLOAT,
    p_actual FLOAT,
    p_kind TEXT DEFAULT 'prediction_error',
    p_source TEXT DEFAULT 'agent',
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_event reward_events%ROWTYPE;
    expected_value FLOAT := LEAST(1.0, GREATEST(-1.0, COALESCE(p_expected, 0.0)));
    actual_value FLOAT := LEAST(1.0, GREATEST(-1.0, COALESCE(p_actual, 0.0)));
    rpe_value FLOAT;
BEGIN
    rpe_value := LEAST(1.0, GREATEST(-1.0, actual_value - expected_value));

    INSERT INTO reward_events (
        kind, valence, salience, source, expected, actual, rpe, metadata
    )
    VALUES (
        COALESCE(NULLIF(btrim(p_kind), ''), 'prediction_error'),
        rpe_value,
        ABS(rpe_value),
        COALESCE(NULLIF(btrim(p_source), ''), 'agent'),
        expected_value,
        actual_value,
        rpe_value,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING * INTO row_event;

    IF ABS(rpe_value) >= COALESCE(get_config_float('reward.rpe_spike_threshold'), 0.35) THEN
        PERFORM fire_dopamine_spike(
            rpe_value,
            COALESCE(NULLIF(p_kind, ''), 'prediction_error') || ': ' || COALESCE(p_metadata->>'summary', '')
        );
    END IF;

    RETURN jsonb_build_object(
        'event_id', row_event.id::text,
        'expected', expected_value,
        'actual', actual_value,
        'rpe', rpe_value,
        'dopamine_triggered', ABS(rpe_value) >= COALESCE(get_config_float('reward.rpe_spike_threshold'), 0.35)
    );
END;
$$;

CREATE OR REPLACE FUNCTION record_social_reward(
    p_signal TEXT,
    p_valence FLOAT DEFAULT 0.4,
    p_salience FLOAT DEFAULT 0.5,
    p_source TEXT DEFAULT 'conversation',
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE sql
AS $$
    SELECT record_reward_event(
        'social:' || COALESCE(NULLIF(btrim(p_signal), ''), 'interaction'),
        p_valence,
        p_salience,
        p_source,
        COALESCE(p_metadata, '{}'::jsonb)
    );
$$;

CREATE OR REPLACE FUNCTION reward_state_summary(
    p_since INTERVAL DEFAULT INTERVAL '24 hours'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    since_ts TIMESTAMPTZ := CURRENT_TIMESTAMP - COALESCE(p_since, INTERVAL '24 hours');
    event_count INT;
    avg_val NUMERIC;
    avg_sal NUMERIC;
    avg_rpe NUMERIC;
    by_kind JSONB;
BEGIN
    SELECT count(*)::int,
           COALESCE(round(avg(valence)::numeric, 4), 0),
           COALESCE(round(avg(salience)::numeric, 4), 0),
           COALESCE(round(avg(rpe)::numeric, 4), 0)
    INTO event_count, avg_val, avg_sal, avg_rpe
    FROM reward_events
    WHERE created_at >= since_ts;

    SELECT COALESCE(jsonb_object_agg(kind, count), '{}'::jsonb)
    INTO by_kind
    FROM (
        SELECT kind, count(*)::int AS count
        FROM reward_events
        WHERE created_at >= since_ts
        GROUP BY kind
    ) grouped;

    RETURN jsonb_build_object(
        'since', CURRENT_TIMESTAMP - COALESCE(p_since, INTERVAL '24 hours'),
        'events', event_count,
        'avg_valence', avg_val,
        'avg_salience', avg_sal,
        'avg_rpe', avg_rpe,
        'by_kind', by_kind,
        'dopamine', get_dopamine_state()
    );
END;
$$;


SET check_function_bodies = on;
