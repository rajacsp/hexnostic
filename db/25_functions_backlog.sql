-- ============================================================================
-- Backlog CRUD Functions
-- ============================================================================
SET search_path = public, ag_catalog, "$user";

-- ----------------------------------------------------------------------------
-- Create a backlog item
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_backlog_item(
    p_title TEXT,
    p_description TEXT DEFAULT '',
    p_priority TEXT DEFAULT 'normal',
    p_owner TEXT DEFAULT 'agent',
    p_created_by TEXT DEFAULT 'agent',
    p_tags TEXT[] DEFAULT '{}',
    p_parent_id UUID DEFAULT NULL,
    p_due_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS backlog AS $$
DECLARE
    new_item backlog;
BEGIN
    -- Validate priority
    IF p_priority NOT IN ('urgent', 'high', 'normal', 'low') THEN
        p_priority := 'normal';
    END IF;
    -- Validate owner
    IF p_owner NOT IN ('agent', 'user', 'shared') THEN
        p_owner := 'agent';
    END IF;
    -- Validate created_by
    IF p_created_by NOT IN ('agent', 'user') THEN
        p_created_by := 'agent';
    END IF;

    INSERT INTO backlog (title, description, priority, owner, created_by, tags, parent_id, due_date)
    VALUES (p_title, COALESCE(p_description, ''), p_priority, p_owner, p_created_by, COALESCE(p_tags, '{}'), p_parent_id, p_due_date)
    RETURNING * INTO new_item;

    RETURN new_item;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- Get a single backlog item by ID
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_backlog_item(p_id UUID)
RETURNS backlog AS $$
DECLARE
    item backlog;
BEGIN
    SELECT * INTO item FROM backlog WHERE id = p_id;
    RETURN item;
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- List backlog items with optional filters
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_backlog(
    p_status TEXT DEFAULT NULL,
    p_priority TEXT DEFAULT NULL,
    p_owner TEXT DEFAULT NULL,
    p_limit INT DEFAULT 50
)
RETURNS SETOF backlog AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM backlog
    WHERE (p_status IS NULL OR status = p_status)
      AND (p_priority IS NULL OR priority = p_priority)
      AND (p_owner IS NULL OR owner = p_owner)
    ORDER BY
        CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high' THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low' THEN 3
        END,
        created_at ASC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- Update a backlog item (flexible field update via JSONB)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_backlog_item(
    p_id UUID,
    p_fields JSONB
)
RETURNS backlog AS $$
DECLARE
    updated_item backlog;
BEGIN
    UPDATE backlog SET
        title = COALESCE(p_fields->>'title', title),
        description = COALESCE(p_fields->>'description', description),
        status = CASE
            WHEN p_fields->>'status' IS NOT NULL
                 AND p_fields->>'status' IN ('todo', 'in_progress', 'done', 'blocked', 'cancelled')
            THEN p_fields->>'status'
            ELSE status
        END,
        priority = CASE
            WHEN p_fields->>'priority' IS NOT NULL
                 AND p_fields->>'priority' IN ('urgent', 'high', 'normal', 'low')
            THEN p_fields->>'priority'
            ELSE priority
        END,
        owner = CASE
            WHEN p_fields->>'owner' IS NOT NULL
                 AND p_fields->>'owner' IN ('agent', 'user', 'shared')
            THEN p_fields->>'owner'
            ELSE owner
        END,
        tags = CASE
            WHEN p_fields->'tags' IS NOT NULL
            THEN ARRAY(SELECT jsonb_array_elements_text(p_fields->'tags'))
            ELSE tags
        END,
        checkpoint = CASE
            WHEN p_fields ? 'checkpoint'
            THEN p_fields->'checkpoint'
            ELSE checkpoint
        END,
        due_date = CASE
            WHEN p_fields ? 'due_date'
            THEN (p_fields->>'due_date')::timestamptz
            ELSE due_date
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id
    RETURNING * INTO updated_item;

    RETURN updated_item;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- Delete a backlog item (hard delete)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_backlog_item(p_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    DELETE FROM backlog WHERE id = p_id;
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- Get backlog snapshot for heartbeat context
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_backlog_snapshot(p_limit INT DEFAULT 20)
RETURNS JSONB AS $$
DECLARE
    counts JSONB;
    actionable JSONB;
BEGIN
    -- Get counts by status
    SELECT jsonb_object_agg(status, cnt) INTO counts
    FROM (
        SELECT status, COUNT(*)::int AS cnt
        FROM backlog
        WHERE status NOT IN ('done', 'cancelled')
        GROUP BY status
    ) s;

    -- Get top actionable items
    SELECT COALESCE(jsonb_agg(item ORDER BY prio_rank, created_at), '[]'::jsonb) INTO actionable
    FROM (
        SELECT jsonb_build_object(
            'id', id,
            'title', title,
            'description', CASE WHEN length(description) > 200 THEN left(description, 200) || '...' ELSE description END,
            'priority', priority,
            'owner', owner,
            'status', status,
            'tags', to_jsonb(tags),
            'has_checkpoint', checkpoint IS NOT NULL,
            'parent_id', parent_id,
            'due_date', due_date
        ) AS item,
        CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high' THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low' THEN 3
        END AS prio_rank,
        created_at
        FROM backlog
        WHERE status IN ('todo', 'in_progress', 'blocked')
        LIMIT p_limit
    ) items;

    RETURN jsonb_build_object(
        'counts', COALESCE(counts, '{}'::jsonb),
        'actionable', actionable
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- Auto-update updated_at trigger
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backlog_updated_at_trigger()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_backlog_updated_at ON backlog;
CREATE TRIGGER trg_backlog_updated_at
    BEFORE UPDATE ON backlog
    FOR EACH ROW
    EXECUTE FUNCTION backlog_updated_at_trigger();
