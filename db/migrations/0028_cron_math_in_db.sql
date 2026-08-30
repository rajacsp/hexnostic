-- Real cron math in the database: cron_next_fire evaluates 5-field cron
-- expressions (Vixie semantics, timezone-aware) and replaces the
-- now+1-minute placeholder that made DB-native cron tasks degrade to
-- every-minute firing. parse_schedule_input validates cron at creation,
-- and manage_schedule_tool reaches parity with the deleted Python
-- fallback (curated list/stats shapes, recent_runs, update delivery
-- validation). Mirrors db/19_functions_scheduling.sql and
-- db/36_functions_tool_runtime.sql.

SET check_function_bodies = off;

-- One atom of a cron field: a number or a name (JAN..DEC / SUN..SAT).
CREATE OR REPLACE FUNCTION cron_field_atom(
    p_atom TEXT, p_min INT, p_max INT, p_names TEXT[] DEFAULT NULL
) RETURNS INT AS $$
DECLARE
    idx INT;
    val INT;
BEGIN
    IF p_names IS NOT NULL THEN
        idx := array_position(p_names, upper(btrim(p_atom)));
        IF idx IS NOT NULL THEN
            RETURN p_min + idx - 1;
        END IF;
    END IF;
    IF btrim(p_atom) !~ '^\d+$' THEN
        RAISE EXCEPTION 'invalid cron atom: %', p_atom;
    END IF;
    val := btrim(p_atom)::int;
    IF val < p_min OR val > p_max THEN
        RAISE EXCEPTION 'cron value % out of range %-%', val, p_min, p_max;
    END IF;
    RETURN val;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Expand one cron field ('*', 'a', 'a-b', '*/n', 'a-b/n', 'a/n', lists) into
-- its sorted value set. Raises on any invalid syntax or out-of-range value,
-- so this doubles as the cron validator.
CREATE OR REPLACE FUNCTION cron_field_values(
    p_field TEXT, p_min INT, p_max INT, p_names TEXT[] DEFAULT NULL
) RETURNS INT[] AS $$
DECLARE
    field TEXT := btrim(coalesce(p_field, ''));
    part TEXT;
    body TEXT;
    step_txt TEXT;
    step INT;
    lo INT;
    hi INT;
    seen BOOLEAN[] := array_fill(false, ARRAY[p_max - p_min + 1]);
    result INT[] := '{}';
    i INT;
BEGIN
    IF field = '' THEN
        RAISE EXCEPTION 'empty cron field';
    END IF;
    FOREACH part IN ARRAY string_to_array(field, ',') LOOP
        part := btrim(part);
        step := 1;
        body := part;
        IF position('/' in part) > 0 THEN
            body := split_part(part, '/', 1);
            step_txt := split_part(part, '/', 2);
            IF step_txt !~ '^\d+$' OR step_txt::int < 1 THEN
                RAISE EXCEPTION 'invalid cron step: %', part;
            END IF;
            step := step_txt::int;
        END IF;
        IF body = '*' THEN
            lo := p_min;
            hi := p_max;
        ELSIF position('-' in body) > 0 THEN
            lo := cron_field_atom(split_part(body, '-', 1), p_min, p_max, p_names);
            hi := cron_field_atom(split_part(body, '-', 2), p_min, p_max, p_names);
            IF lo > hi THEN
                RAISE EXCEPTION 'inverted cron range: %', body;
            END IF;
        ELSE
            lo := cron_field_atom(body, p_min, p_max, p_names);
            -- 'a/n' means a..max stepped by n; a bare 'a' is just a.
            hi := CASE WHEN step > 1 THEN p_max ELSE lo END;
        END IF;
        i := lo;
        WHILE i <= hi LOOP
            seen[i - p_min + 1] := true;
            i := i + step;
        END LOOP;
    END LOOP;
    FOR i IN p_min..p_max LOOP
        IF seen[i - p_min + 1] THEN
            result := result || i;
        END IF;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Real cron next-fire computation (minute resolution) in the task's
-- timezone. Fields: minute hour day-of-month month day-of-week; a 6-field
-- expression drops its trailing seconds field. Standard Vixie semantics: when
-- both day fields are restricted (not '*'), a day matches if EITHER matches;
-- day-of-week accepts 0-7 (0 and 7 are Sunday) and SUN-SAT names.
CREATE OR REPLACE FUNCTION cron_next_fire(
    p_cron TEXT,
    p_timezone TEXT DEFAULT 'UTC',
    p_after TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
) RETURNS TIMESTAMPTZ AS $$
DECLARE
    fields TEXT[] := regexp_split_to_array(btrim(coalesce(p_cron, '')), '\s+');
    minutes INT[];
    hours INT[];
    doms INT[];
    months INT[];
    dows INT[];
    dom_star BOOLEAN;
    dow_star BOOLEAN;
    tz TEXT := normalize_timezone(p_timezone);
    local_after TIMESTAMP;
    day0 DATE;
    day DATE;
    d INT;
    h INT;
    m INT;
    day_ok BOOLEAN;
    cursor_time TIME;
    result TIMESTAMPTZ;
BEGIN
    IF array_length(fields, 1) = 6 THEN
        fields := fields[1:5];
    END IF;
    IF array_length(fields, 1) <> 5 THEN
        RAISE EXCEPTION 'cron expression must have 5 fields: %', p_cron;
    END IF;
    minutes := cron_field_values(fields[1], 0, 59);
    hours := cron_field_values(fields[2], 0, 23);
    doms := cron_field_values(fields[3], 1, 31);
    months := cron_field_values(fields[4], 1, 12,
        ARRAY['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC']);
    dows := ARRAY(SELECT DISTINCT v % 7 FROM unnest(cron_field_values(fields[5], 0, 7,
        ARRAY['SUN','MON','TUE','WED','THU','FRI','SAT','SUN'])) v ORDER BY v % 7);
    dom_star := btrim(fields[3]) = '*';
    dow_star := btrim(fields[5]) = '*';

    local_after := date_trunc('minute', p_after AT TIME ZONE tz) + INTERVAL '1 minute';
    day0 := local_after::date;
    FOR d IN 0..1500 LOOP
        day := day0 + d;
        IF NOT (EXTRACT(MONTH FROM day)::int = ANY(months)) THEN
            CONTINUE;
        END IF;
        IF dom_star AND dow_star THEN
            day_ok := true;
        ELSIF dom_star THEN
            day_ok := EXTRACT(DOW FROM day)::int = ANY(dows);
        ELSIF dow_star THEN
            day_ok := EXTRACT(DAY FROM day)::int = ANY(doms);
        ELSE
            day_ok := EXTRACT(DAY FROM day)::int = ANY(doms)
                   OR EXTRACT(DOW FROM day)::int = ANY(dows);
        END IF;
        IF NOT day_ok THEN
            CONTINUE;
        END IF;
        cursor_time := CASE WHEN d = 0 THEN local_after::time ELSE '00:00'::time END;
        FOREACH h IN ARRAY hours LOOP
            IF make_time(h, 59, 59.0) < cursor_time THEN
                CONTINUE;
            END IF;
            FOREACH m IN ARRAY minutes LOOP
                IF make_time(h, m, 0.0) >= cursor_time THEN
                    result := (day + make_time(h, m, 0.0)) AT TIME ZONE tz;
                    IF result > p_after THEN
                        RETURN result;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    RAISE EXCEPTION 'cron expression never fires: %', p_cron;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION compute_next_run_at(
    p_schedule_kind TEXT,
    p_schedule JSONB,
    p_timezone TEXT DEFAULT 'UTC',
    p_after TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
)
RETURNS TIMESTAMPTZ AS $$
DECLARE
    schedule_kind TEXT;
    tz TEXT;
    after_ts TIMESTAMPTZ;
    after_local TIMESTAMP;
    run_at TIMESTAMPTZ;
    target_time TIME;
    weekday INT;
    days_ahead INT;
    interval_seconds INT;
    anchor_ts TIMESTAMPTZ;
    elapsed_seconds DOUBLE PRECISION;
    next_ts TIMESTAMPTZ;
BEGIN
    schedule_kind := NULLIF(lower(btrim(p_schedule_kind)), '');
    IF schedule_kind IS NULL THEN
        RAISE EXCEPTION 'schedule_kind is required';
    END IF;

    tz := normalize_timezone(p_timezone);
    after_ts := COALESCE(p_after, CURRENT_TIMESTAMP);

    CASE schedule_kind
        WHEN 'once' THEN
            run_at := NULLIF(p_schedule->>'run_at', '')::timestamptz;
            IF run_at IS NULL THEN
                RAISE EXCEPTION 'schedule.run_at is required for once schedules';
            END IF;
            IF run_at <= after_ts THEN
                RETURN NULL;
            END IF;
            RETURN run_at;
        WHEN 'interval' THEN
            interval_seconds := COALESCE(
                NULLIF((p_schedule->>'every_seconds')::int, 0),
                NULLIF((p_schedule->>'every_minutes')::int, 0) * 60,
                NULLIF((p_schedule->>'every_hours')::int, 0) * 3600
            );
            IF interval_seconds IS NULL OR interval_seconds <= 0 THEN
                RAISE EXCEPTION 'schedule.every_seconds/every_minutes/every_hours required for interval schedules';
            END IF;
            anchor_ts := NULLIF(p_schedule->>'anchor_at', '')::timestamptz;
            IF anchor_ts IS NULL THEN
                anchor_ts := after_ts;
            END IF;
            IF after_ts < anchor_ts THEN
                RETURN anchor_ts;
            END IF;
            elapsed_seconds := EXTRACT(EPOCH FROM (after_ts - anchor_ts));
            next_ts := anchor_ts + ((floor(elapsed_seconds / interval_seconds) + 1) * interval_seconds) * INTERVAL '1 second';
            RETURN next_ts;
        WHEN 'daily' THEN
            target_time := parse_time_of_day(p_schedule->>'time');
            after_local := after_ts AT TIME ZONE tz;
            run_at := (date_trunc('day', after_local) + target_time) AT TIME ZONE tz;
            IF run_at <= after_ts THEN
                run_at := ((date_trunc('day', after_local) + target_time) + INTERVAL '1 day') AT TIME ZONE tz;
            END IF;
            RETURN run_at;
        WHEN 'weekly' THEN
            target_time := parse_time_of_day(p_schedule->>'time');
            weekday := normalize_weekday(p_schedule->>'weekday');
            after_local := after_ts AT TIME ZONE tz;
            days_ahead := (weekday - EXTRACT(ISODOW FROM after_local)::int + 7) % 7;
            run_at := (date_trunc('day', after_local) + (days_ahead || ' days')::interval + target_time) AT TIME ZONE tz;
            IF run_at <= after_ts THEN
                run_at := run_at + INTERVAL '7 days';
            END IF;
            RETURN run_at;
        WHEN 'cron' THEN
            -- Real cron math lives in cron_next_fire; the schedule JSONB
            -- stores {"cron": "..."} (a stale "_next_run" is ignored).
            -- Fail open to +1 minute only if evaluation fails at runtime —
            -- creation-time validation should make that unreachable.
            BEGIN
                RETURN cron_next_fire(p_schedule->>'cron', tz, after_ts);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'cron_next_fire failed for %: %', p_schedule->>'cron', SQLERRM;
                run_at := NULLIF(p_schedule->>'_next_run', '')::timestamptz;
                IF run_at IS NOT NULL AND run_at > after_ts THEN
                    RETURN run_at;
                END IF;
                RETURN after_ts + INTERVAL '1 minute';
            END;
        ELSE
            RAISE EXCEPTION 'Unsupported schedule_kind: %', schedule_kind;
    END CASE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION parse_schedule_input(
    p_input JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    schedule_str TEXT := NULLIF(btrim(COALESCE(p_input->>'schedule', '')), '');
    schedule_kind TEXT := NULLIF(lower(btrim(COALESCE(p_input->>'schedule_kind', ''))), '');
    timezone_value TEXT := normalize_timezone(COALESCE(p_input->>'timezone', 'UTC'));
    parts TEXT[];
    schedule JSONB := '{}'::jsonb;
    offset_text TEXT;
    offset_value INT;
    offset_unit TEXT;
    run_at TIMESTAMPTZ;
BEGIN
    IF schedule_str IS NOT NULL THEN
        IF db_brain_is_cron_expression(schedule_str) THEN
            schedule_kind := 'cron';
            schedule := jsonb_build_object('cron', schedule_str);
        ELSIF schedule_str LIKE '{%' THEN
            schedule := schedule_str::jsonb;
        ELSIF position(':' in schedule_str) > 0 THEN
            parts := string_to_array(schedule_str, ':');
            CASE lower(parts[1])
                WHEN 'once' THEN
                    offset_text := regexp_replace(COALESCE(parts[2], ''), '^\+', '');
                    IF offset_text !~ '^\d+[hmd]$' THEN
                        RAISE EXCEPTION 'Invalid offset format: %', offset_text;
                    END IF;
                    offset_value := left(offset_text, length(offset_text) - 1)::int;
                    offset_unit := right(offset_text, 1);
                    run_at := CURRENT_TIMESTAMP
                        + CASE offset_unit
                            WHEN 'h' THEN offset_value * INTERVAL '1 hour'
                            WHEN 'm' THEN offset_value * INTERVAL '1 minute'
                            WHEN 'd' THEN offset_value * INTERVAL '1 day'
                          END;
                    schedule_kind := 'once';
                    schedule := jsonb_build_object('run_at', run_at);
                WHEN 'daily' THEN
                    schedule_kind := 'daily';
                    schedule := jsonb_build_object('time', parts[2] || ':' || COALESCE(parts[3], '00'));
                WHEN 'weekly' THEN
                    schedule_kind := 'weekly';
                    schedule := jsonb_build_object('weekday', parts[2], 'time', parts[3] || ':' || COALESCE(parts[4], '00'));
                WHEN 'every' THEN
                    offset_text := COALESCE(parts[2], '');
                    IF offset_text !~ '^\d+[hms]$' THEN
                        RAISE EXCEPTION 'Invalid interval format: %', offset_text;
                    END IF;
                    schedule_kind := 'interval';
                    offset_value := left(offset_text, length(offset_text) - 1)::int;
                    offset_unit := right(offset_text, 1);
                    schedule := CASE offset_unit
                        WHEN 'h' THEN jsonb_build_object('every_hours', offset_value)
                        WHEN 'm' THEN jsonb_build_object('every_minutes', offset_value)
                        ELSE jsonb_build_object('every_seconds', offset_value)
                    END;
                ELSE
                    IF length(schedule_str) <= 5 THEN
                        schedule_kind := COALESCE(schedule_kind, 'daily');
                        schedule := jsonb_build_object('time', schedule_str);
                    ELSE
                        RAISE EXCEPTION 'Could not parse schedule: %', schedule_str;
                    END IF;
            END CASE;
        ELSIF length(schedule_str) <= 5 THEN
            schedule_kind := COALESCE(schedule_kind, 'daily');
            schedule := jsonb_build_object('time', schedule_str);
        ELSE
            RAISE EXCEPTION 'Could not parse schedule: %', schedule_str;
        END IF;
    END IF;

    IF schedule_kind IS NULL THEN
        RAISE EXCEPTION 'schedule_kind is required';
    END IF;

    IF schedule_kind = 'cron' THEN
        IF NULLIF(schedule->>'cron', '') IS NULL THEN
            RAISE EXCEPTION 'cron schedule requires a "cron" expression';
        END IF;
        -- cron_next_fire validates the expression (raises on bad syntax,
        -- out-of-range values, or a never-firing schedule).
        schedule := schedule || jsonb_build_object(
            '_next_run', cron_next_fire(schedule->>'cron', timezone_value, CURRENT_TIMESTAMP)::text);
    END IF;

    IF schedule_kind = 'once' AND schedule ? '_offset' THEN
        offset_text := regexp_replace(schedule->>'_offset', '^\+', '');
        IF offset_text !~ '^\d+[hmd]$' THEN
            RAISE EXCEPTION 'Invalid offset format: %', offset_text;
        END IF;
        offset_value := left(offset_text, length(offset_text) - 1)::int;
        offset_unit := right(offset_text, 1);
        run_at := CURRENT_TIMESTAMP
            + CASE offset_unit
                WHEN 'h' THEN offset_value * INTERVAL '1 hour'
                WHEN 'm' THEN offset_value * INTERVAL '1 minute'
                WHEN 'd' THEN offset_value * INTERVAL '1 day'
              END;
        schedule := (schedule - '_offset') || jsonb_build_object('run_at', run_at);
    END IF;

    RETURN jsonb_build_object(
        'schedule_kind', schedule_kind,
        'schedule', schedule,
        'timezone', timezone_value,
        'next_run_at', compute_next_run_at(schedule_kind, schedule, timezone_value, CURRENT_TIMESTAMP)
    );
END;
$$;

CREATE OR REPLACE FUNCTION manage_schedule_tool(
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    action TEXT := COALESCE(p_args->>'action', '');
    parsed JSONB;
    delivery JSONB;
    action_kind TEXT;
    action_payload JSONB := '{}'::jsonb;
    task_id UUID;
    row_data JSONB;
    tasks JSONB;
BEGIN
    IF action NOT IN ('create', 'list', 'update', 'cancel', 'stats') THEN
        RETURN jsonb_build_object('success', false, 'error', format('Invalid action %L', action), 'error_type', 'invalid_params');
    END IF;

    IF action = 'create' THEN
        IF NULLIF(btrim(COALESCE(p_args->>'name', '')), '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Name is required for create', 'error_type', 'invalid_params');
        END IF;
        action_kind := COALESCE(NULLIF(p_args->>'action_kind', ''), 'queue_user_message');
        IF action_kind = 'queue_user_message' THEN
            IF NULLIF(btrim(COALESCE(p_args->>'message', '')), '') IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'message is required for queue_user_message action_kind', 'error_type', 'invalid_params');
            END IF;
            action_payload := jsonb_build_object('message', p_args->>'message');
        ELSIF action_kind = 'create_goal' THEN
            action_payload := jsonb_build_object('title', COALESCE(NULLIF(p_args->>'goal_title', ''), p_args->>'name'), 'description', p_args->>'description');
        ELSE
            RETURN jsonb_build_object('success', false, 'error', format('Invalid action_kind %L', action_kind), 'error_type', 'invalid_params');
        END IF;
        delivery := build_schedule_delivery(p_args);
        IF delivery->>'mode' = 'channel' AND NULLIF(delivery->>'target_id', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_target_id is required when delivery_mode is channel', 'error_type', 'invalid_params');
        END IF;
        IF delivery->>'mode' = 'webhook' AND NULLIF(delivery->>'url', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_webhook_url is required when delivery_mode is webhook', 'error_type', 'invalid_params');
        END IF;
        parsed := parse_schedule_input(p_args);
        task_id := create_scheduled_task(
            p_args->>'name',
            parsed->>'schedule_kind',
            parsed->'schedule',
            action_kind,
            action_payload,
            parsed->>'timezone',
            p_args->>'description',
            'active',
            COALESCE(NULLIF(p_args->>'max_runs', '')::int, CASE WHEN parsed->>'schedule_kind' = 'once' THEN 1 ELSE NULL END),
            'agent',
            delivery
        );
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object(
            'task_id', task_id::text,
            'name', p_args->>'name',
            'schedule_kind', parsed->>'schedule_kind',
            'action_kind', action_kind,
            'delivery', delivery
        ), 'display_output', format('Created scheduled task: %s (%s)', p_args->>'name', parsed->>'schedule_kind'));
    ELSIF action = 'list' THEN
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', t.id::text,
                'name', t.name,
                'description', t.description,
                'schedule_kind', t.schedule_kind,
                'status', t.status,
                'next_run_at', t.next_run_at::text,
                'last_run_at', t.last_run_at::text,
                'run_count', COALESCE(t.run_count, 0),
                'action_kind', t.action_kind,
                'last_error', t.last_error
            )
            -- default outbox delivery is implementation detail; only
            -- non-default routing is surfaced
            || CASE WHEN t.delivery IS NOT NULL AND (t.delivery->>'mode') IS DISTINCT FROM 'outbox'
                    THEN jsonb_build_object('delivery', t.delivery)
                    ELSE '{}'::jsonb END
        ), '[]'::jsonb)
        INTO tasks
        FROM list_scheduled_tasks(NULLIF(p_args->>'status', '')) t;
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('tasks', tasks, 'count', jsonb_array_length(tasks)), 'display_output', format('Found %s scheduled task(s)', jsonb_array_length(tasks)));
    ELSIF action = 'update' THEN
        task_id := NULLIF(p_args->>'task_id', '')::uuid;
        IF task_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'task_id is required for update', 'error_type', 'invalid_params');
        END IF;
        parsed := CASE WHEN p_args ? 'schedule' OR p_args ? 'schedule_kind' THEN parse_schedule_input(p_args) ELSE NULL END;
        delivery := CASE WHEN p_args ? 'delivery_mode' OR p_args ? 'delivery_channel' OR p_args ? 'delivery_target_id' OR p_args ? 'delivery_webhook_url' THEN build_schedule_delivery(p_args) ELSE NULL END;
        IF delivery IS NOT NULL AND delivery->>'mode' = 'channel' AND NULLIF(delivery->>'target_id', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_target_id is required when delivery_mode is channel', 'error_type', 'invalid_params');
        END IF;
        IF delivery IS NOT NULL AND delivery->>'mode' = 'webhook' AND NULLIF(delivery->>'url', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_webhook_url is required when delivery_mode is webhook', 'error_type', 'invalid_params');
        END IF;
        action_payload := CASE
            WHEN p_args ? 'message' THEN jsonb_build_object('message', p_args->>'message')
            WHEN p_args ? 'goal_title' THEN jsonb_build_object('title', p_args->>'goal_title')
            ELSE NULL
        END;
        row_data := update_scheduled_task(
            task_id,
            p_args->>'name',
            p_args->>'description',
            COALESCE(parsed->>'schedule_kind', p_args->>'schedule_kind'),
            parsed->'schedule',
            COALESCE(parsed->>'timezone', p_args->>'timezone'),
            p_args->>'action_kind',
            action_payload,
            p_args->>'status',
            NULLIF(p_args->>'max_runs', '')::int,
            delivery
        );
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('task_id', task_id::text, 'updated', true, 'task', row_data), 'display_output', format('Updated scheduled task %s...', left(task_id::text, 8)));
    ELSIF action = 'cancel' THEN
        task_id := NULLIF(p_args->>'task_id', '')::uuid;
        IF task_id IS NULL AND NULLIF(p_args->>'name', '') IS NOT NULL THEN
            SELECT id INTO task_id FROM scheduled_tasks WHERE name = p_args->>'name' AND status = 'active' LIMIT 1;
        END IF;
        IF task_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'task_id or name is required for cancel', 'error_type', 'invalid_params');
        END IF;
        IF delete_scheduled_task(task_id, false, COALESCE(p_args->>'description', 'Cancelled by agent')) THEN
            RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('task_id', task_id::text, 'cancelled', true), 'display_output', format('Cancelled scheduled task %s...', left(task_id::text, 8)));
        END IF;
        RETURN jsonb_build_object('success', false, 'error', format('Task %s not found', task_id), 'error_type', 'invalid_params');
    ELSE
        IF NULLIF(p_args->>'task_id', '') IS NOT NULL THEN
            SELECT jsonb_build_object(
                'task_id', t.id::text,
                'name', t.name,
                'schedule_kind', t.schedule_kind,
                'status', t.status,
                'run_count', t.run_count,
                'max_runs', t.max_runs,
                'last_run_at', t.last_run_at::text,
                'next_run_at', t.next_run_at::text,
                'last_error', t.last_error,
                'created_at', t.created_at::text
            ) INTO row_data
            FROM scheduled_tasks t WHERE id = (p_args->>'task_id')::uuid;
            IF row_data IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', format('Task %s not found', p_args->>'task_id'), 'error_type', 'execution_failed');
            END IF;
            RETURN jsonb_build_object('success', true, 'output', row_data);
        END IF;
        SELECT jsonb_build_object(
            'active_tasks', COUNT(*) FILTER (WHERE status = 'active'),
            'paused_tasks', COUNT(*) FILTER (WHERE status = 'paused'),
            'disabled_tasks', COUNT(*) FILTER (WHERE status = 'disabled'),
            'total_executions', COALESCE(SUM(run_count), 0),
            'tasks_with_errors', COUNT(*) FILTER (WHERE last_error IS NOT NULL AND status = 'active'),
            'last_execution', MAX(last_run_at)::text,
            'next_execution', (MIN(next_run_at) FILTER (WHERE status = 'active'))::text
        ) INTO row_data
        FROM scheduled_tasks;
        row_data := row_data || jsonb_build_object('recent_runs', COALESCE(
            (SELECT jsonb_agg(jsonb_build_object(
                    'at', e.created_at::text,
                    'tasks_executed', e.payload->'executed'
                ) ORDER BY e.created_at DESC)
             FROM (SELECT created_at, payload FROM gateway_events
                   WHERE source = 'cron'
                   ORDER BY created_at DESC LIMIT 10) e),
            '[]'::jsonb));
        RETURN jsonb_build_object('success', true, 'output', row_data);
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_type', 'execution_failed');
END;
$$;

CREATE OR REPLACE FUNCTION recompute_cron_next_runs(
    p_task_ids UUID[]
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    updated_count INT := 0;
    task_id UUID;
    schedule_value JSONB;
    next_run TIMESTAMPTZ;
    task_tz TEXT;
BEGIN
    IF p_task_ids IS NULL OR cardinality(p_task_ids) = 0 THEN
        RETURN 0;
    END IF;
    FOREACH task_id IN ARRAY p_task_ids LOOP
        SELECT schedule, COALESCE(timezone, 'UTC') INTO schedule_value, task_tz FROM scheduled_tasks WHERE id = task_id AND schedule_kind = 'cron';
        IF NOT FOUND THEN
            CONTINUE;
        END IF;
        next_run := compute_next_run_at('cron', schedule_value, task_tz, CURRENT_TIMESTAMP);
        schedule_value := COALESCE(schedule_value, '{}'::jsonb)
            || jsonb_build_object('_next_run', next_run::text);
        UPDATE scheduled_tasks
        SET schedule = schedule_value,
            next_run_at = next_run,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = task_id;
        updated_count := updated_count + 1;
    END LOOP;
    RETURN updated_count;
END;
$$;

SET check_function_bodies = on;
