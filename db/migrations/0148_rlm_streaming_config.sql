-- RLM chat is currently buffered: it cannot emit user-visible tokens until the
-- FINAL/FINAL_VAR answer is parsed. Keep streaming transports on AgentLoop by
-- default, while leaving an explicit switch for native RLM streaming work.

INSERT INTO config_defaults (key, value, description)
VALUES (
    'rlm.chat.streaming_enabled',
    'false'::jsonb,
    'Use native RLM chat path for streaming transports; false keeps UI/CLI token streaming through AgentLoop until RLM supports incremental final output'
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();
