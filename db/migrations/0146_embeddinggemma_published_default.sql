-- Align Hexis with the published embeddinggemma binary defaults.
SET search_path = public, ag_catalog, "$user";

UPDATE config
SET value = to_jsonb(
        CASE value #>> '{}'
            WHEN 'http://host.docker.internal:11434/api/embed'
                THEN 'http://host.docker.internal:42666/api/embed'
            WHEN 'http://localhost:11434/api/embed'
                THEN 'http://localhost:42666/api/embed'
            WHEN 'http://127.0.0.1:11434/api/embed'
                THEN 'http://127.0.0.1:42666/api/embed'
            ELSE value #>> '{}'
        END
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'embedding.service_url'
  AND value #>> '{}' IN (
      'http://host.docker.internal:11434/api/embed',
      'http://localhost:11434/api/embed',
      'http://127.0.0.1:11434/api/embed'
  );
