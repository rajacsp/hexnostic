-- 0171: URL ingestion is a durable background job, not a foreground chat task.

UPDATE prompt_modules
SET content = replace(
        content,
        '`remember` only durable conclusions; `pin_desk_item` what stays actively needed; `clear_desk` when the work is done. When you fetch a web resource worth keeping, ingest it (`url_ingest`) -- but for freshness-sensitive facts, fetch the live web rather than trusting a stale ingested copy.',
        '`remember` only durable conclusions; `pin_desk_item` what stays actively needed; `clear_desk` when the work is done. When you fetch a web resource worth keeping, queue it for durable background ingestion (`url_ingest`) and continue the conversation; do not wait for the job to finish. For freshness-sensitive facts, fetch the live web rather than trusting a stale ingested copy.'
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'conversation'
  AND content LIKE '%When you fetch a web resource worth keeping, ingest it (`url_ingest`)%';

UPDATE prompt_modules
SET content = replace(
        content,
        '`remember` only durable conclusions; `pin_desk_item` what stays actively needed; `clear_desk` when the work is done. When you fetch a web resource worth keeping, ingest it (`url_ingest`) -- but for freshness-sensitive facts, fetch the live web rather than trusting a stale ingested copy.',
        '`remember` only durable conclusions; `pin_desk_item` what stays actively needed; `clear_desk` when the work is done. When you fetch a web resource worth keeping, queue it for durable background ingestion (`url_ingest`) and continue the heartbeat; do not wait for the job to finish. For freshness-sensitive facts, fetch the live web rather than trusting a stale ingested copy.'
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'heartbeat_agentic'
  AND content LIKE '%When you fetch a web resource worth keeping, ingest it (`url_ingest`)%';

INSERT INTO change_journal (kind, summary, detail)
VALUES (
    'prompt_module',
    'Clarified url_ingest as async durable background persistence',
    '{"migration": "0171_async_url_ingest_prompt", "modules": ["conversation", "heartbeat_agentic"]}'::jsonb
);
