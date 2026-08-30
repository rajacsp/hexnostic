-- Single-source ingestion lands on the RecMem desk by default. Bulk walkers
-- and connector backfills opt out in the pipeline so large corpus imports do
-- not flood mid-term working memory.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('ingest.auto_load_to_desk', 'true'::jsonb,
     'Automatically place newly ingested single-source user/agent documents on the RecMem desk; bulk and connector imports opt out')
ON CONFLICT (key) DO NOTHING;

UPDATE prompt_modules
SET content = replace(
        content,
        $old$**Source-document filing cabinet -- the retrieval ladder:** Ingested files, emails, web pages, and channel messages are preserved as exact source documents with durable, citable chunks, separate from distilled memories. You always know this cabinet exists; you learn what is in it by searching it or following a memory's provenance. Climb this ladder and stop at the first rung that truly answers:$old$,
        $new$**Source-document filing cabinet -- the retrieval ladder:** Ingested files, emails, web pages, and channel messages are preserved as exact source documents with durable, citable chunks, separate from distilled memories. You always know this cabinet exists. Single-source user/agent ingestion also lands on the RecMem desk immediately as incoming work; bulk corpus and connector backfills stay in the cabinet until you deliberately pull relevant sources onto the desk. You learn what is in the cabinet by searching it or following a memory's provenance. Climb this ladder and stop at the first rung that truly answers:$new$
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key IN ('conversation', 'heartbeat_agentic')
  AND content LIKE '%You always know this cabinet exists; you learn what is in it by searching it%';

UPDATE prompt_modules
SET content = replace(
        replace(
            content,
            $old$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Use deliberately for large specs or reference files you will
need to search on demand later.$old$,
            $new$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Use deliberately for large specs or reference files you will
need to search on demand later.
Single-source user/agent ingestion already places the new source on the desk
as incoming work; bulk corpus and connector imports stay in the cabinet until
you pull specific sources onto the desk.$new$
        ),
        $old$- Use `document_load_to_desk()` only when the source should remain searchable
  as desk material beyond the current REPL workspace.$old$,
        $new$- Use `document_load_to_desk()` when the source should remain searchable as
  desk material beyond the current REPL workspace, or when a bulk-imported
  source needs to be pulled from the cabinet.$new$
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'rlm_chat_system'
  AND content LIKE '%Use deliberately for large specs or reference files you will%';

UPDATE prompt_modules
SET content = replace(
        replace(
            content,
            $old$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Use deliberately for large specs or reference files you will
need to search on demand in later turns.$old$,
            $new$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Use deliberately for large specs or reference files you will
need to search on demand in later turns.
Single-source user/agent ingestion already places the new source on the desk
as incoming work; bulk corpus and connector imports stay in the cabinet until
you pull specific sources onto the desk.$new$
        ),
        $old$- Use `document_load_to_desk()` only when the source should remain searchable
  as RecMem desk material beyond the current heartbeat workspace.$old$,
        $new$- Use `document_load_to_desk()` when the source should remain searchable as
  RecMem desk material beyond the current heartbeat workspace, or when a
  bulk-imported source needs to be pulled from the cabinet.$new$
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'rlm_heartbeat_system'
  AND content LIKE '%need to search on demand in later turns%';

UPDATE prompt_modules
SET content = replace(
        replace(
            content,
            $old$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Use this sparingly during ingestion when a source must remain
searchable by later RecMem/history queries.$old$,
            $new$Load selected source documents onto the RecMem desk as searchable mid-term
working material. Single-source user/agent ingestion already places the new
source on the desk as incoming work; bulk corpus and connector imports stay in
the cabinet until you pull specific sources onto the desk.$new$
        ),
        $old$- Use `document_load_to_desk()` only when the source should remain searchable
  as desk material after this ingestion pass.$old$,
        $new$- Use `document_load_to_desk()` when the source should remain searchable as
  desk material after this ingestion pass, or when a bulk-imported source needs
  to be pulled from the cabinet.$new$
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'rlm_slow_ingest_system'
  AND content LIKE '%Use this sparingly during ingestion when a source must remain%';

DO $$
DECLARE
    fn_oid OID;
    ddl TEXT;
    patched TEXT;
BEGIN
    fn_oid := to_regprocedure(
        'upsert_connector_source_item(text,text,text,text,text,text,text,timestamp with time zone,text[],jsonb,jsonb,jsonb,text,boolean)'
    );
    IF fn_oid IS NOT NULL THEN
        ddl := pg_get_functiondef(fn_oid);
        patched := replace(
            ddl,
            $old$'provider_thread_id', NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
                    'sensitivity', normalized_sensitivity$old$,
            $new$'provider_thread_id', NULLIF(btrim(COALESCE(p_provider_thread_id, '')), ''),
                    'acquisition', 'connector',
                    'sensitivity', normalized_sensitivity$new$
        );
        IF patched IS DISTINCT FROM ddl THEN
            EXECUTE patched;
        END IF;
    END IF;

    fn_oid := to_regprocedure('upsert_channel_source_item(uuid,boolean)');
    IF fn_oid IS NOT NULL THEN
        ddl := pg_get_functiondef(fn_oid);
        patched := replace(
            ddl,
            $old$'platform_message_id', row_message.platform_message_id,
                    'sensitivity', normalized_sensitivity$old$,
            $new$'platform_message_id', row_message.platform_message_id,
                    'acquisition', 'connector',
                    'sensitivity', normalized_sensitivity$new$
        );
        IF patched IS DISTINCT FROM ddl THEN
            EXECUTE patched;
        END IF;
    END IF;
END;
$$;
