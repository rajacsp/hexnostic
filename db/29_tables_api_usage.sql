-- =============================================================
-- API Usage Tracking
-- =============================================================
SET search_path = public, ag_catalog, "$user";

-- Tracks every LLM and embedding API call for cost analysis.
-- Inspired by OpenClaw's provider-usage system, but stored in
-- Postgres (our brain) rather than JSONL transcript files.

-- -------------------------------------------------------------
-- Table
-- -------------------------------------------------------------

CREATE TABLE api_usage (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    provider        TEXT NOT NULL,            -- e.g. 'anthropic', 'openai', 'gemini', 'local-embedding'
    model           TEXT NOT NULL,            -- e.g. 'claude-opus-4-6', 'gpt-4o'
    operation       TEXT NOT NULL DEFAULT 'chat',  -- 'chat', 'embed', 'image', 'stream'
    input_tokens    INT NOT NULL DEFAULT 0,
    output_tokens   INT NOT NULL DEFAULT 0,
    cache_read_tokens  INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    total_tokens    INT GENERATED ALWAYS AS (
        input_tokens + output_tokens + cache_read_tokens + cache_write_tokens
    ) STORED,
    cost_usd        NUMERIC(12, 6),          -- NULL if unknown
    session_key     TEXT,                     -- correlate to chat/heartbeat session
    source          TEXT NOT NULL DEFAULT 'chat',  -- 'chat', 'heartbeat', 'cron', 'sub_agent', 'maintenance'
    metadata        JSONB NOT NULL DEFAULT '{}'
);

-- -------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------

CREATE INDEX idx_api_usage_created
    ON api_usage (created_at DESC);

CREATE INDEX idx_api_usage_provider
    ON api_usage (provider, created_at DESC);

CREATE INDEX idx_api_usage_source
    ON api_usage (source, created_at DESC);

CREATE INDEX idx_api_usage_session
    ON api_usage (session_key, created_at DESC)
    WHERE session_key IS NOT NULL;

-- -------------------------------------------------------------
-- Functions
-- -------------------------------------------------------------

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



-- Summarize usage for a time range, grouped by provider + model
CREATE FUNCTION usage_summary(
    p_since INTERVAL DEFAULT '30 days',
    p_source TEXT DEFAULT NULL
) RETURNS TABLE (
    provider TEXT,
    model TEXT,
    operation TEXT,
    call_count BIGINT,
    total_input_tokens BIGINT,
    total_output_tokens BIGINT,
    total_cache_read BIGINT,
    total_cache_write BIGINT,
    total_tokens BIGINT,
    total_cost NUMERIC
) AS $$
    SELECT
        u.provider,
        u.model,
        u.operation,
        count(*) AS call_count,
        sum(u.input_tokens)::bigint AS total_input_tokens,
        sum(u.output_tokens)::bigint AS total_output_tokens,
        sum(u.cache_read_tokens)::bigint AS total_cache_read,
        sum(u.cache_write_tokens)::bigint AS total_cache_write,
        sum(u.total_tokens)::bigint AS total_tokens,
        sum(u.cost_usd) AS total_cost
    FROM api_usage u
    WHERE u.created_at >= now() - p_since
      AND (p_source IS NULL OR u.source = p_source)
    GROUP BY u.provider, u.model, u.operation
    ORDER BY total_cost DESC NULLS LAST, total_tokens DESC;
$$ LANGUAGE sql STABLE;


-- Daily cost breakdown for a time range
CREATE FUNCTION usage_daily(
    p_since INTERVAL DEFAULT '30 days',
    p_source TEXT DEFAULT NULL
) RETURNS TABLE (
    day DATE,
    provider TEXT,
    model TEXT,
    call_count BIGINT,
    total_tokens BIGINT,
    total_cost NUMERIC
) AS $$
    SELECT
        date_trunc('day', u.created_at)::date AS day,
        u.provider,
        u.model,
        count(*) AS call_count,
        sum(u.total_tokens)::bigint AS total_tokens,
        sum(u.cost_usd) AS total_cost
    FROM api_usage u
    WHERE u.created_at >= now() - p_since
      AND (p_source IS NULL OR u.source = p_source)
    GROUP BY day, u.provider, u.model
    ORDER BY day DESC, total_cost DESC NULLS LAST;
$$ LANGUAGE sql STABLE;


-- Cleanup old usage records (default: keep 90 days)
CREATE FUNCTION usage_cleanup(p_older_than INTERVAL DEFAULT '90 days')
RETURNS INTEGER AS $$
    WITH deleted AS (
        DELETE FROM api_usage
        WHERE created_at < now() - p_older_than
        RETURNING 1
    )
    SELECT count(*)::integer FROM deleted;
$$ LANGUAGE sql;
