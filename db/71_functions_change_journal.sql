-- Change legibility (#93): record_change/recent_changes over the
-- change_journal table (db/32). Writers: the migration runner, worker/API
-- startup build-stamp comparison, prompt-module upserts, and operator
-- decisions (D2).
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_change(
    p_kind TEXT,
    p_summary TEXT,
    p_detail JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
    INSERT INTO change_journal (kind, summary, detail)
    VALUES (p_kind, p_summary, COALESCE(p_detail, '{}'::jsonb))
    RETURNING id;
$$ LANGUAGE sql;

-- The journal read for tools and the heartbeat context: recent changes,
-- newest first.
CREATE OR REPLACE FUNCTION recent_changes(
    p_since TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 20
) RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(item ORDER BY ord), '[]'::jsonb) FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY c.occurred_at DESC) AS ord,
               jsonb_build_object(
                   'kind', c.kind,
                   'summary', c.summary,
                   'detail', c.detail,
                   'occurred_at', c.occurred_at) AS item
        FROM change_journal c
        WHERE p_since IS NULL OR c.occurred_at > p_since
        ORDER BY c.occurred_at DESC
        LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100))
    ) s;
$$ LANGUAGE sql STABLE;
