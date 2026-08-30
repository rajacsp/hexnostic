-- 0055: Heartbeat plan pushdown (plans/db_pushdown.md 3.7): the DB is
-- the single authority on heartbeat context enrichment, resource
-- scaling, and the shell/file-write permission grant. Baseline mirror:
-- db/68.
SET search_path = public, ag_catalog, "$user";


INSERT INTO config (key, value, description) VALUES
    ('heartbeat.task_energy_multiplier', '2'::jsonb,
     'Energy budget multiplier when the backlog has actionable work'),
    ('heartbeat.base_timeout_seconds', '120'::jsonb,
     'Agentic heartbeat wall-clock timeout without backlog work'),
    ('heartbeat.task_timeout_seconds', '300'::jsonb,
     'Agentic heartbeat wall-clock timeout when backlog work is active'),
    ('heartbeat.base_max_tokens', '2048'::jsonb,
     'Heartbeat LLM token cap without backlog work'),
    ('heartbeat.task_max_tokens', '4096'::jsonb,
     'Heartbeat LLM token cap when backlog work is active')
ON CONFLICT (key) DO NOTHING;

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
