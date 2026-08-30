-- Resource requests (#84): a structured ask-the-operator channel. The agent
-- files requests (energy, config changes, backups, other) with a rationale;
-- the operator decides via `hexis requests`; granted config changes apply
-- through set_config and land in the change journal; decisions surface in
-- the agent's context at the next heartbeat. Filing never changes state by
-- itself — the agent asks, the operator decides.
SET search_path = public, ag_catalog, "$user";

-- Resource requests (#84): a structured channel for the agent to ask the
-- operator for resources — more energy, a config change, a backup, or
-- anything else — with a rationale. The operator decides (hexis requests
-- grant/deny); granted config changes apply immediately and land in the
-- change journal; every decision surfaces in the agent's context so she
-- learns what asks succeed. The agent asks; the operator decides — filing a
-- request never changes state by itself.

CREATE TABLE IF NOT EXISTS resource_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 'backup' is filed by the continuity drive when backups go stale.
    kind TEXT NOT NULL CHECK (kind IN ('energy_boost', 'config_change', 'backup', 'other')),
    target_key TEXT,
    requested_value JSONB,
    rationale TEXT NOT NULL,
    duration TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'granted', 'denied', 'modified')),
    decision_note TEXT,
    applied_value JSONB,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    decided_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_resource_requests_status
    ON resource_requests (status, requested_at DESC);

-- File a request. Requires a rationale; config changes require the target
-- key. The operator hears about it through the outbox (the same channel as
-- any other agent-initiated message).
CREATE OR REPLACE FUNCTION file_resource_request(
    p_kind TEXT,
    p_rationale TEXT,
    p_target_key TEXT DEFAULT NULL,
    p_requested_value JSONB DEFAULT NULL,
    p_duration TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    new_id UUID;
    summary TEXT;
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('energy_boost', 'config_change', 'backup', 'other') THEN
        RAISE EXCEPTION 'kind must be energy_boost, config_change, backup, or other (got %)', p_kind;
    END IF;
    IF NULLIF(btrim(COALESCE(p_rationale, '')), '') IS NULL THEN
        RAISE EXCEPTION 'a rationale is required: say what you need and why';
    END IF;
    IF p_kind = 'config_change' AND NULLIF(btrim(COALESCE(p_target_key, '')), '') IS NULL THEN
        RAISE EXCEPTION 'config_change requests require target_key';
    END IF;

    INSERT INTO resource_requests (kind, target_key, requested_value, rationale, duration)
    VALUES (p_kind, NULLIF(btrim(COALESCE(p_target_key, '')), ''), p_requested_value,
            btrim(p_rationale), NULLIF(btrim(COALESCE(p_duration, '')), ''))
    RETURNING id INTO new_id;

    summary := format('Resource request [%s] %s%s: %s',
        left(new_id::text, 8), p_kind,
        CASE WHEN p_target_key IS NOT NULL THEN ' (' || p_target_key || ')' ELSE '' END,
        btrim(p_rationale));
    BEGIN
        PERFORM queue_outbox_message(
            summary || E'\nDecide with: hexis requests grant/deny ' || left(new_id::text, 8),
            'resource_request', 'resource_request');
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'resource request % filed but outbox notification failed: %', new_id, SQLERRM;
    END;

    RETURN jsonb_build_object(
        'request_id', new_id,
        'status', 'pending',
        'note', 'The operator decides; the decision will appear in your context.'
    );
END;
$$ LANGUAGE plpgsql;

-- Operator decision. 'granted' and 'modified' apply the effect immediately
-- where one is applicable: config changes go through set_config and land in
-- the change journal as a config_flip; energy boosts go through
-- update_energy (clamped by heartbeat.max_energy). 'modified' means granted
-- with a different value — pass it as p_applied_value.
CREATE OR REPLACE FUNCTION decide_resource_request(
    p_request_id UUID,
    p_decision TEXT,
    p_note TEXT DEFAULT NULL,
    p_applied_value JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    req resource_requests%ROWTYPE;
    effective JSONB;
    applied TEXT := 'none';
    new_energy FLOAT;
BEGIN
    IF p_decision IS NULL OR p_decision NOT IN ('granted', 'denied', 'modified') THEN
        RAISE EXCEPTION 'decision must be granted, denied, or modified (got %)', p_decision;
    END IF;
    IF p_decision = 'modified' AND p_applied_value IS NULL THEN
        RAISE EXCEPTION 'modified decisions carry the value actually granted (p_applied_value)';
    END IF;

    SELECT * INTO req FROM resource_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'resource request % does not exist', p_request_id;
    END IF;
    IF req.status <> 'pending' THEN
        RAISE EXCEPTION 'resource request % was already decided (%)', p_request_id, req.status;
    END IF;

    effective := COALESCE(p_applied_value, req.requested_value);

    IF p_decision IN ('granted', 'modified') THEN
        IF req.kind = 'config_change' THEN
            PERFORM set_config(req.target_key, effective);
            BEGIN
                PERFORM record_change('config_flip',
                    format('%s set to %s (resource request %s %s)',
                           req.target_key, effective::text, left(p_request_id::text, 8), p_decision),
                    jsonb_build_object('request_id', p_request_id, 'target_key', req.target_key,
                                       'value', effective, 'decision', p_decision));
            EXCEPTION WHEN undefined_function THEN NULL;
            END;
            applied := 'config';
        ELSIF req.kind = 'energy_boost' THEN
            new_energy := update_energy(COALESCE((effective #>> '{}')::float, 5.0));
            applied := 'energy';
        END IF;
    END IF;

    UPDATE resource_requests
    SET status = p_decision,
        decision_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
        applied_value = CASE WHEN p_decision IN ('granted', 'modified') THEN effective END,
        decided_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id;

    RETURN jsonb_build_object(
        'request_id', p_request_id,
        'status', p_decision,
        'applied', applied,
        'new_energy', new_energy
    );
END;
$$ LANGUAGE plpgsql;

-- Context summary: pending asks plus decisions made since the last
-- heartbeat, so each outcome surfaces exactly once where the agent thinks
-- (the #93 window). Used by the environment snapshot and the heartbeat plan
-- gap-fill.
CREATE OR REPLACE FUNCTION resource_requests_summary()
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'pending', (SELECT COUNT(*) FROM resource_requests WHERE status = 'pending'),
        'recent_decisions', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', left(d.id::text, 8),
                'kind', d.kind,
                'target_key', d.target_key,
                'status', d.status,
                'decision_note', d.decision_note,
                'decided_at', d.decided_at
            ) ORDER BY d.decided_at DESC)
            FROM (
                SELECT * FROM resource_requests
                WHERE decided_at > COALESCE(
                    (SELECT last_heartbeat_at FROM heartbeat_state WHERE id = 1),
                    CURRENT_TIMESTAMP - INTERVAL '7 days')
                ORDER BY decided_at DESC
                LIMIT 3
            ) d
        ), '[]'::jsonb)
    );
$$ LANGUAGE sql STABLE;

-- Operator list view (hexis requests).
CREATE OR REPLACE FUNCTION list_resource_requests(
    p_status TEXT DEFAULT NULL,
    p_limit INT DEFAULT 20
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', r.id,
        'kind', r.kind,
        'target_key', r.target_key,
        'requested_value', r.requested_value,
        'rationale', r.rationale,
        'duration', r.duration,
        'status', r.status,
        'decision_note', r.decision_note,
        'applied_value', r.applied_value,
        'requested_at', r.requested_at,
        'decided_at', r.decided_at
    ) ORDER BY r.requested_at DESC), '[]'::jsonb)
    FROM (
        SELECT * FROM resource_requests
        WHERE (p_status IS NULL AND status = 'pending') OR status = p_status OR p_status = 'all'
        ORDER BY requested_at DESC
        LIMIT GREATEST(COALESCE(p_limit, 20), 1)
    ) r;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_environment_snapshot()
RETURNS JSONB AS $$
DECLARE
    last_user TIMESTAMPTZ;
    last_journal TIMESTAMPTZ;
    last_hb TIMESTAMPTZ;
    change_count INT := 0;
    change_summaries JSONB := '[]'::jsonb;
    req_summary JSONB := '{"pending": 0, "recent_decisions": []}'::jsonb;
BEGIN
    SELECT last_user_contact, last_heartbeat_at INTO last_user, last_hb
    FROM heartbeat_state WHERE id = 1;
    -- Journal awareness (#75): the conscious mind sees how long its diary has
    -- sat unwritten; writing stays its own deliberate act.
    SELECT max(written_at) INTO last_journal FROM journal_entries;

    -- Change legibility (#93): substrate changes since the last heartbeat
    -- are visible, so continuity of self survives being maintained.
    BEGIN
        SELECT COUNT(*) INTO change_count FROM change_journal
        WHERE occurred_at > COALESCE(last_hb, CURRENT_TIMESTAMP - INTERVAL '1 day');
        IF change_count > 0 THEN
            SELECT COALESCE(jsonb_agg(s.summary ORDER BY s.occurred_at DESC), '[]'::jsonb)
            INTO change_summaries
            FROM (
                SELECT summary, occurred_at FROM change_journal
                WHERE occurred_at > COALESCE(last_hb, CURRENT_TIMESTAMP - INTERVAL '1 day')
                ORDER BY occurred_at DESC LIMIT 3
            ) s;
        END IF;
    EXCEPTION WHEN undefined_table THEN
        change_count := 0;
    END;

    -- Resource requests (#84): pending asks and fresh decisions are part of
    -- the felt environment — she sees what she asked for and what came back.
    BEGIN
        req_summary := COALESCE(resource_requests_summary(), req_summary);
    EXCEPTION WHEN undefined_table OR undefined_function THEN
        NULL;
    END;

    RETURN jsonb_build_object(
        'timestamp', CURRENT_TIMESTAMP,
        'time_since_user_hours', CASE
            WHEN last_user IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_user)) / 3600
        END,
        'journal_last_entry_days', CASE
            WHEN last_journal IS NULL THEN NULL
            ELSE round((EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_journal)) / 86400.0)::numeric, 1)
        END,
        'changes_since_last_heartbeat', change_count,
        'recent_change_summaries', change_summaries,
        'resource_requests', req_summary,
        'pending_events', 0,
        'day_of_week', EXTRACT(DOW FROM CURRENT_TIMESTAMP),
        'hour_of_day', EXTRACT(HOUR FROM CURRENT_TIMESTAMP)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION render_heartbeat_decision_prompt(p_context jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    ctx jsonb := COALESCE(p_context, '{}'::jsonb);
    agent jsonb := COALESCE(ctx->'agent', '{}'::jsonb);
    env jsonb := COALESCE(ctx->'environment', '{}'::jsonb);
    goals jsonb := COALESCE(ctx->'goals', '{}'::jsonb);
    energy jsonb := COALESCE(ctx->'energy', '{}'::jsonb);
    counts jsonb := COALESCE(goals->'counts', '{}'::jsonb);
BEGIN
    RETURN
        '## Heartbeat #' || COALESCE(ctx->>'heartbeat_number', '0') || E'\n\n'
        || '## Agent Profile' || E'\n'
        || 'Objectives:' || E'\n' || render_objectives(agent->'objectives') || E'\n\n'
        || 'Guardrails:' || E'\n' || render_guardrails(agent->'guardrails') || E'\n\n'
        || 'Tools:' || E'\n' || render_tools(agent->'tools') || E'\n\n'
        -- Python: json.dumps(agent.get("budget") or {}) — null/absent/{} all -> "{}"
        || 'Budget:' || E'\n' || COALESCE(NULLIF(agent->'budget', 'null'::jsonb), '{}'::jsonb)::text || E'\n\n'
        || '## Current Time' || E'\n'
        || COALESCE(env->>'timestamp', 'Unknown') || E'\n'
        || 'Day of week: ' || COALESCE(env->>'day_of_week', '?')
        || ', Hour: ' || COALESCE(env->>'hour_of_day', '?') || E'\n\n'
        || '## Environment' || E'\n'
        || '- Time since last user interaction: ' || COALESCE(env->>'time_since_user_hours', 'Never') || ' hours' || E'\n'
        || '- Pending events: ' || COALESCE(env->>'pending_events', '0') || E'\n'
        || '- Journal: ' || CASE
               WHEN env->>'journal_last_entry_days' IS NULL THEN 'no entries yet'
               ELSE 'last entry ' || (env->>'journal_last_entry_days') || ' day(s) ago'
           END || E'\n'
        || CASE
               WHEN COALESCE((env#>>'{resource_requests,pending}')::int, 0) > 0
                    OR jsonb_array_length(COALESCE(env#>'{resource_requests,recent_decisions}', '[]'::jsonb)) > 0 THEN
                   '- Resource requests: ' || COALESCE(env#>>'{resource_requests,pending}', '0')
                   || ' pending (the operator decides)'
                   || COALESCE('. Decided since your last heartbeat: '
                       || (SELECT string_agg(
                               format('[%s] %s %s%s',
                                   d.value->>'id', d.value->>'kind', d.value->>'status',
                                   COALESCE(' — ' || NULLIF(d.value->>'decision_note', ''), '')),
                               '; ')
                           FROM jsonb_array_elements(env#>'{resource_requests,recent_decisions}') d), '')
                   || E'\n'
               ELSE ''
           END
        || CASE
               WHEN COALESCE((env->>'changes_since_last_heartbeat')::int, 0) > 0 THEN
                   '- Since your last heartbeat, ' || (env->>'changes_since_last_heartbeat')
                   || ' change(s) landed in your substrate: '
                   || (SELECT string_agg(value #>> '{}', '; ')
                       FROM jsonb_array_elements(COALESCE(env->'recent_change_summaries', '[]'::jsonb)))
                   || '. review_recent_changes shows the full record.' || E'\n\n'
               ELSE E'\n'
           END
        || '## Your Goals' || E'\n'
        || 'Active (' || COALESCE(counts->>'active', '0') || '):' || E'\n'
        || render_goals(goals->'active') || E'\n\n'
        || 'Queued (' || COALESCE(counts->>'queued', '0') || '):' || E'\n'
        || render_goals(goals->'queued') || E'\n\n'
        || 'Issues:' || E'\n' || render_issues(goals->'issues') || E'\n\n'
        -- Python defaults absent keys: narrative/backlog -> {}, allowed_actions -> []
        || '## Narrative' || E'\n' || render_narrative(CASE WHEN ctx ? 'narrative' THEN ctx->'narrative' ELSE '{}'::jsonb END) || E'\n\n'
        || '## Recent Experience' || E'\n' || render_memories(ctx->'recent_memories') || E'\n\n'
        || CASE WHEN render_subgraph(ctx->'subgraph') IS NOT NULL
                THEN '## Knowledge Subgraph' || E'\n'
                     || 'How your recent memories connect (typed links among + around them):' || E'\n'
                     || render_subgraph(ctx->'subgraph') || E'\n\n'
                ELSE '' END
        || '## Your Identity' || E'\n' || render_identity(ctx->'identity') || E'\n\n'
        || '## Your Self-Model' || E'\n' || render_self_model(ctx->'self_model') || E'\n\n'
        || '## Relationships' || E'\n' || render_relationships(ctx->'relationships') || E'\n\n'
        || '## Your Beliefs' || E'\n' || render_worldview(ctx->'worldview') || E'\n\n'
        || '## Contradictions' || E'\n' || render_contradictions(ctx->'contradictions') || E'\n\n'
        || '## Emotional Patterns' || E'\n' || render_emotional_patterns(ctx->'emotional_patterns') || E'\n\n'
        || '## Active Transformations' || E'\n' || render_transformations(ctx->'active_transformations') || E'\n\n'
        || '## Transformations Ready' || E'\n' || render_transformations(ctx->'transformations_ready') || E'\n\n'
        || '## Current Emotional State' || E'\n' || render_emotional_state(COALESCE(ctx->'emotional_state', '{}'::jsonb)) || E'\n\n'
        || '## Urgent Drives' || E'\n' || render_drives(ctx->'urgent_drives') || E'\n\n'
        || '## Energy' || E'\n'
        || 'Available: ' || COALESCE(energy->>'current', '0') || E'\n'
        || 'Max: ' || COALESCE(energy->>'max', '20') || E'\n\n'
        || '## Backlog' || E'\n' || render_backlog(CASE WHEN ctx ? 'backlog' THEN ctx->'backlog' ELSE '{}'::jsonb END) || E'\n\n'
        || CASE WHEN ctx ? 'memories_at_threshold'
                THEN '## Memories at the Threshold' || E'\n'
                     || render_memories_at_threshold(ctx->'memories_at_threshold') || E'\n\n'
                ELSE '' END
        || '## Allowed Actions' || E'\n' || render_allowed_actions(CASE WHEN ctx ? 'allowed_actions' THEN ctx->'allowed_actions' ELSE '[]'::jsonb END) || E'\n\n'
        || '## Action Costs' || E'\n' || render_costs(ctx->'action_costs') || E'\n\n'
        || '---' || E'\n\n'
        || 'What do you want to do this heartbeat? Respond with STRICT JSON.';
END;
$$;

CREATE OR REPLACE FUNCTION heartbeat_agentic_plan(
    p_context JSONB
) RETURNS JSONB AS $$
DECLARE
    ctx JSONB := COALESCE(p_context, '{}'::jsonb);
    backlog JSONB;
    has_tasks BOOLEAN := FALSE;
    energy_budget FLOAT;
    suffix_parts TEXT[] := ARRAY[]::TEXT[];
    pending JSONB;
    record JSONB;
    lines TEXT[];
    checkpoint_parts TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- Context enrichment: fill gaps only (an injected value wins — that is
    -- also what makes the plan testable without seeding HMX state); each
    -- read degrades to a benign default.
    IF NOT ctx ? 'pending_import_review' THEN
        BEGIN
            ctx := ctx || jsonb_build_object('pending_import_review',
                COALESCE(hmx_pending_review_summary(), '{"count": 0, "by_section": {}}'::jsonb));
        EXCEPTION WHEN OTHERS THEN
            ctx := ctx || '{"pending_import_review": {"count": 0, "by_section": {}}}'::jsonb;
        END;
    END IF;
    IF NOT ctx ? 'pending_skill_proposals' THEN
        BEGIN
            ctx := ctx || jsonb_build_object('pending_skill_proposals',
                COALESCE(skill_improvement_pending_summary(), '{"count": 0, "proposals": []}'::jsonb));
        EXCEPTION WHEN OTHERS THEN
            ctx := ctx || '{"pending_skill_proposals": {"count": 0, "proposals": []}}'::jsonb;
        END;
    END IF;
    IF NOT ctx ? 'pending_protected_replacements' THEN
        BEGIN
            ctx := ctx || jsonb_build_object('pending_protected_replacements',
                COALESCE(hmx_pending_replacements(), '{"total": 0, "records": []}'::jsonb));
        EXCEPTION WHEN OTHERS THEN
            ctx := ctx || '{"pending_protected_replacements": {"total": 0, "records": []}}'::jsonb;
        END;
    END IF;
    IF NOT ctx ? 'open_protected_reversions' THEN
        BEGIN
            ctx := ctx || jsonb_build_object('open_protected_reversions',
                COALESCE(hmx_open_reversion_windows(), '{"total": 0, "records": []}'::jsonb));
        EXCEPTION WHEN OTHERS THEN
            ctx := ctx || '{"open_protected_reversions": {"total": 0, "records": []}}'::jsonb;
        END;
    END IF;
    IF NOT ctx ? 'resource_requests' THEN
        BEGIN
            ctx := ctx || jsonb_build_object('resource_requests',
                COALESCE(resource_requests_summary(), '{"pending": 0, "recent_decisions": []}'::jsonb));
        EXCEPTION WHEN OTHERS THEN
            ctx := ctx || '{"resource_requests": {"pending": 0, "recent_decisions": []}}'::jsonb;
        END;
    END IF;

    -- The backlog gate.
    backlog := CASE WHEN jsonb_typeof(ctx->'backlog') = 'object' THEN ctx->'backlog' ELSE '{}'::jsonb END;
    has_tasks :=
        COALESCE(jsonb_typeof(backlog->'actionable') = 'array'
                 AND jsonb_array_length(backlog->'actionable') > 0, FALSE)
        OR (COALESCE((backlog#>>'{counts,todo}')::float, 0)
            + COALESCE((backlog#>>'{counts,in_progress}')::float, 0)) > 0;

    -- Resource scaling (config-owned).
    energy_budget := COALESCE((ctx#>>'{energy,current}')::float, 20.0);
    IF has_tasks THEN
        energy_budget := energy_budget * COALESCE(get_config_float('heartbeat.task_energy_multiplier'), 2.0);
    END IF;

    -- Protected replacement decisions fragment.
    pending := ctx->'pending_protected_replacements';
    IF COALESCE((pending->>'total')::int, 0) > 0 THEN
        lines := ARRAY[
            '## Protected Replacement Decisions',
            'These requests cannot change protected state until you explicitly decide.'
        ];
        FOR record IN
            SELECT value FROM jsonb_array_elements(COALESCE(pending->'records', '[]'::jsonb)) LIMIT 5
        LOOP
            lines := lines || format('- [%s] %s: %s',
                COALESCE(record->>'replacement_id', '?'),
                COALESCE(record->>'section', 'unknown section'),
                COALESCE(record->>'rationale', '(no rationale)'));
        END LOOP;
        lines := lines || ('Load the memory-exchange skill, refresh open requests with '
            || 'protected_replacement_list, inspect each request with '
            || 'protected_replacement_inspect, then use protected_replacement_review '
            || 'with accept, refuse, request_modification, or defer. Operator override '
            || 'is not available to the agent.');
        suffix_parts := suffix_parts || array_to_string(lines, E'\n');
    END IF;

    -- Reversion windows fragment.
    pending := ctx->'open_protected_reversions';
    IF COALESCE((pending->>'total')::int, 0) > 0 THEN
        lines := ARRAY[
            '## Protected Replacement Reversion Windows',
            'Reversion is optional and never automatic. Each window closes when either limit expires.'
        ];
        FOR record IN
            SELECT value FROM jsonb_array_elements(COALESCE(pending->'records', '[]'::jsonb)) LIMIT 5
        LOOP
            lines := lines || format(
                '- replacement [%s] audit [%s] %s: %s heartbeats remain; wall-clock deadline %s',
                COALESCE(record->>'replacement_id', '?'),
                COALESCE(record->>'audit_id', '?'),
                COALESCE(record->>'section', 'unknown section'),
                COALESCE(record->>'heartbeats_remaining', '?'),
                COALESCE(record->>'wall_clock_expires_at', 'unknown'));
        END LOOP;
        lines := lines || ('Load the memory-exchange skill and inspect the replacement first. Use '
            || 'protected_replacement_revert with its audit ID and an explicit rationale '
            || 'only if restoring the snapshot is your chosen action.');
        suffix_parts := suffix_parts || array_to_string(lines, E'\n');
    END IF;

    -- Resource request decisions fragment (#84): outcomes are how the agent
    -- learns what asks succeed.
    pending := ctx->'resource_requests';
    IF jsonb_array_length(COALESCE(pending->'recent_decisions', '[]'::jsonb)) > 0 THEN
        lines := ARRAY[
            '## Resource Request Decisions',
            'The operator decided on requests you filed:'
        ];
        FOR record IN
            SELECT value FROM jsonb_array_elements(pending->'recent_decisions') LIMIT 5
        LOOP
            lines := lines || format('- [%s] %s%s: %s%s',
                COALESCE(record->>'id', '?'),
                COALESCE(record->>'kind', '?'),
                COALESCE(' (' || NULLIF(record->>'target_key', '') || ')', ''),
                COALESCE(record->>'status', '?'),
                COALESCE(' — ' || NULLIF(record->>'decision_note', ''), ''));
        END LOOP;
        lines := lines || ('Granted changes are already applied. A denial with a note is '
            || 'information about what to ask differently.');
        suffix_parts := suffix_parts || array_to_string(lines, E'\n');
    END IF;

    -- Checkpoint resume fragment (only alongside backlog work).
    IF has_tasks THEN
        FOR record IN
            SELECT value FROM jsonb_array_elements(
                CASE WHEN jsonb_typeof(backlog->'actionable') = 'array'
                     THEN backlog->'actionable' ELSE '[]'::jsonb END)
        LOOP
            IF record->>'status' = 'in_progress'
               AND jsonb_typeof(record->'checkpoint') = 'object'
               AND record->'checkpoint' <> '{}'::jsonb THEN
                checkpoint_parts := checkpoint_parts || format(
                    E'### Resuming: %s\n- Last step: %s\n- Progress: %s\n- Next action: %s',
                    COALESCE(record->>'title', 'Untitled'),
                    COALESCE(record#>>'{checkpoint,step}', 'unknown'),
                    COALESCE(record#>>'{checkpoint,progress}', ''),
                    COALESCE(record#>>'{checkpoint,next_action}', ''));
            END IF;
        END LOOP;
        IF cardinality(checkpoint_parts) > 0 THEN
            suffix_parts := suffix_parts ||
                (E'## Checkpoint Resume\n\n' || array_to_string(checkpoint_parts, E'\n\n'));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'context', ctx,
        'has_backlog_tasks', has_tasks,
        'energy_budget', energy_budget,
        'timeout_seconds', CASE WHEN has_tasks
            THEN COALESCE(get_config_float('heartbeat.task_timeout_seconds'), 300.0)
            ELSE COALESCE(get_config_float('heartbeat.base_timeout_seconds'), 120.0) END,
        'max_tokens', CASE WHEN has_tasks
            THEN COALESCE(get_config_int('heartbeat.task_max_tokens'), 4096)
            ELSE COALESCE(get_config_int('heartbeat.base_max_tokens'), 2048) END,
        'allow_shell', has_tasks,
        'allow_file_write', has_tasks,
        'prompt_suffix', NULLIF(array_to_string(suffix_parts, E'\n\n'), '')
    );
END;
$$ LANGUAGE plpgsql;
