-- Optional HMX raw-unit and non-sensitive configuration serializers.
CREATE OR REPLACE FUNCTION hmx_export_raw_units() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', u.id,
        'user_text', u.user_text,
        'assistant_text', u.assistant_text,
        'turn_at', u.turn_at,
        'importance', u.importance,
        'route_status', u.route_status,
        'source_identity', u.source_identity,
        'idempotency_key', u.idempotency_key,
        'derived_memory_ids', COALESCE((
            SELECT jsonb_agg(msu.memory_id ORDER BY msu.memory_id)
            FROM memory_source_units msu
            WHERE msu.subconscious_unit_id = u.id
        ), '[]'::jsonb)
    ) ORDER BY u.turn_at, u.id), '[]'::jsonb)
    FROM subconscious_units u
    WHERE u.status <> 'redacted';
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION hmx_export_config() RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(c.key, c.value ORDER BY c.key), '{}'::jsonb)
    FROM config c
    WHERE lower(c.key) !~ '(key|secret|token|password|signature|credential|auth|trust|anchor|certificate)';
$$ LANGUAGE sql STABLE;
