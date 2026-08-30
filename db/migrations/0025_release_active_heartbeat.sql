-- Finalizing an agentic heartbeat now releases the run's active claim in
-- the same call, and release_active_heartbeat() gives error paths a guarded
-- (or explicit unconditional) release. Mirrors db/43_functions_heartbeat_agentic.sql.

SET check_function_bodies = off;

-- Release the active-heartbeat claim. With p_heartbeat_id the release is
-- guarded (only that run's claim is cleared); with NULL it clears
-- unconditionally (operator/error recovery). Returns whether a claim was
-- cleared.
CREATE OR REPLACE FUNCTION release_active_heartbeat(
    p_heartbeat_id TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    cleared INT;
BEGIN
    UPDATE heartbeat_state
    SET active_heartbeat_id = NULL,
        active_heartbeat_number = NULL,
        active_actions = '[]'::jsonb,
        active_reasoning = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1
      AND (p_heartbeat_id IS NULL OR active_heartbeat_id::text = p_heartbeat_id);
    GET DIAGNOSTICS cleared = ROW_COUNT;
    RETURN cleared > 0;
END;
$$;

CREATE OR REPLACE FUNCTION finalize_agentic_heartbeat(
    p_heartbeat_id TEXT,
    p_summary TEXT,
    p_energy_spent INT DEFAULT 0,
    p_tool_call_count INT DEFAULT 0,
    p_stopped_reason TEXT DEFAULT 'completed',
    p_has_tasks BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    memory_id UUID;
    item RECORD;
BEGIN
    -- 1. Record the heartbeat as an episodic memory. Best-effort: a memory
    --    failure (e.g. embedding service down) must not block finalization.
    --    (The pre-move Python call used the wrong arg names/types — p_action and
    --    a text p_result — so it silently never recorded anything; corrected here.)
    BEGIN
        memory_id := create_episodic_memory(
            p_content := left(COALESCE(p_summary, ''), 2000),
            p_action_taken := to_jsonb('heartbeat'::text),
            p_context := jsonb_build_object(
                'heartbeat_id', p_heartbeat_id,
                'energy_spent', p_energy_spent,
                'tool_calls', p_tool_call_count,
                'stopped_reason', p_stopped_reason,
                'has_backlog_tasks', p_has_tasks
            ),
            p_result := to_jsonb(CASE WHEN p_stopped_reason = 'completed' THEN 'completed' ELSE p_stopped_reason END),
            p_importance := 0.5::double precision,
            p_trust_level := 1.0::double precision
        );
    EXCEPTION WHEN OTHERS THEN
        memory_id := NULL;
    END;

    -- 2. Mark heartbeat completion and release this run's active claim.
    UPDATE heartbeat_state
    SET last_heartbeat_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;
    PERFORM release_active_heartbeat(p_heartbeat_id);

    -- 3. Auto-checkpoint in-progress backlog items interrupted by timeout/energy,
    --    so the next heartbeat can resume (only those without a checkpoint yet).
    IF p_has_tasks AND p_stopped_reason IN ('timeout', 'energy_exhausted') THEN
        FOR item IN
            SELECT id, checkpoint
            FROM public.backlog
            WHERE status = 'in_progress'
            ORDER BY updated_at DESC
            LIMIT 5
        LOOP
            IF item.checkpoint IS NULL THEN
                UPDATE public.backlog
                SET checkpoint = jsonb_build_object(
                        'step', 'interrupted',
                        'progress', format('Heartbeat ended (%s). %s tool calls made.',
                                           p_stopped_reason, p_tool_call_count),
                        'next_action', 'Continue from where left off'
                    ),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = item.id;
            END IF;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('memory_id', memory_id::text);
END;
$$;

SET check_function_bodies = on;
