-- The initial outbox correction caught the episodic "arrive in a minute"
-- summary. Also invalidate semantic summaries that frame that behavior as a
-- successful precedent.
SET search_path = public, ag_catalog, "$user";

DO $$
DECLARE
    row_mem RECORD;
BEGIN
    FOR row_mem IN
        SELECT id
        FROM memories
        WHERE status = 'active'
          AND (
              content ILIKE '%outbox%'
              OR content ILIKE '%send%message%'
          )
          AND (
              content ILIKE '%arrive in about a minute%'
              OR content ILIKE '%bounded example of independent initiative%'
              OR content ILIKE '%genuine reach toward Eric%'
              OR content ILIKE '%small, separate reach%'
          )
    LOOP
        PERFORM record_memory_correction(
            row_mem.id,
            'Do not schedule an outbox message unless the user explicitly asks for later delivery. For immediate "send me a message" requests, use queue_user_message directly.',
            'outbox_tool_routing',
            jsonb_build_object(
                'kind', 'migration',
                'ref', 'db/migrations/0163_outbox_semantic_precedent_correction.sql',
                'label', 'semantic outbox precedent correction',
                'trust', 0.95
            ),
            TRUE
        );
    END LOOP;
END;
$$;
