-- Model price table pushdown (plans/db_pushdown.md 4.2): per-million-token
-- prices become data the operator can maintain, and record_api_usage
-- self-costs when the caller passes no cost. Python's _MODEL_COSTS dict and
-- estimate_cost() are deleted.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS model_costs (
    model TEXT PRIMARY KEY,
    input_per_mtok NUMERIC(12, 6) NOT NULL,
    output_per_mtok NUMERIC(12, 6) NOT NULL,
    cache_read_per_mtok NUMERIC(12, 6) NOT NULL DEFAULT 0,
    cache_write_per_mtok NUMERIC(12, 6) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE model_costs IS
    'USD per million tokens by model. estimate_api_cost() resolves a model by exact then longest-prefix match; unknown models cost NULL for local services.';

INSERT INTO model_costs (model, input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok) VALUES
    -- Anthropic
    ('claude-opus-4-6',            15.0,  75.0,  1.5,    18.75),
    ('claude-opus-4-5',            15.0,  75.0,  1.5,    18.75),
    ('claude-sonnet-4-5',          3.0,   15.0,  0.3,    3.75),
    ('claude-sonnet-4-5-20250929', 3.0,   15.0,  0.3,    3.75),
    ('claude-3-5-sonnet',          3.0,   15.0,  0.3,    3.75),
    ('claude-3-5-haiku',           0.8,   4.0,   0.08,   1.0),
    ('claude-haiku-4-5',           0.8,   4.0,   0.08,   1.0),
    ('claude-haiku-4-5-20251001',  0.8,   4.0,   0.08,   1.0),
    -- OpenAI
    ('gpt-4o',                     2.5,   10.0,  1.25,   0.0),
    ('gpt-4o-mini',                0.15,  0.6,   0.075,  0.0),
    ('gpt-4-turbo',                10.0,  30.0,  0.0,    0.0),
    ('o3',                         10.0,  40.0,  2.5,    0.0),
    ('o3-mini',                    1.1,   4.4,   0.55,   0.0),
    ('o4-mini',                    1.1,   4.4,   0.55,   0.0),
    -- Gemini
    ('gemini-2.5-pro',             1.25,  10.0,  0.315,  0.0),
    ('gemini-2.5-flash',           0.15,  0.6,   0.0375, 0.0),
    ('gemini-2.0-flash',           0.1,   0.4,   0.025,  0.0),
    -- Grok
    ('grok-3',                     3.0,   15.0,  0.0,    0.0),
    ('grok-3-mini',                0.3,   0.5,   0.0,    0.0)
ON CONFLICT (model) DO NOTHING;

CREATE OR REPLACE FUNCTION estimate_api_cost(
    p_model TEXT,
    p_input_tokens INT,
    p_output_tokens INT,
    p_cache_read_tokens INT DEFAULT 0,
    p_cache_write_tokens INT DEFAULT 0
) RETURNS NUMERIC AS $$
    -- Exact match first, then the longest prefix match in either direction
    -- (model ids grow date suffixes). No row means no price (local models).
    SELECT round((
        COALESCE(p_input_tokens, 0) * c.input_per_mtok
        + COALESCE(p_output_tokens, 0) * c.output_per_mtok
        + COALESCE(p_cache_read_tokens, 0) * c.cache_read_per_mtok
        + COALESCE(p_cache_write_tokens, 0) * c.cache_write_per_mtok
    ) / 1000000.0, 6)
    FROM model_costs c
    WHERE c.model = p_model
       OR p_model LIKE c.model || '%'
       OR c.model LIKE p_model || '%'
    ORDER BY (c.model = p_model) DESC, length(c.model) DESC
    LIMIT 1;
$$ LANGUAGE sql STABLE;

-- The DB self-costs: a NULL caller cost falls back to the price table.
CREATE OR REPLACE FUNCTION record_api_usage(
    p_provider TEXT,
    p_model TEXT,
    p_operation TEXT DEFAULT 'chat',
    p_input_tokens INT DEFAULT 0,
    p_output_tokens INT DEFAULT 0,
    p_cache_read_tokens INT DEFAULT 0,
    p_cache_write_tokens INT DEFAULT 0,
    p_cost_usd NUMERIC DEFAULT NULL,
    p_session_key TEXT DEFAULT NULL,
    p_source TEXT DEFAULT 'chat',
    p_metadata JSONB DEFAULT '{}'
) RETURNS BIGINT AS $$
    INSERT INTO api_usage (
        provider, model, operation,
        input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens,
        cost_usd, session_key, source, metadata
    ) VALUES (
        p_provider, p_model, p_operation,
        p_input_tokens, p_output_tokens,
        p_cache_read_tokens, p_cache_write_tokens,
        COALESCE(p_cost_usd, estimate_api_cost(
            p_model, p_input_tokens, p_output_tokens,
            p_cache_read_tokens, p_cache_write_tokens)),
        p_session_key, p_source, p_metadata
    )
    RETURNING id;
$$ LANGUAGE sql;
