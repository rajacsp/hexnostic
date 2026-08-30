-- Self-extension visibility (#99): tools and skills the agent grows are
-- substrate changes — they join the change journal under their own kind
-- and post a web-inbox notice, so the operator always sees what she grew.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE change_journal DROP CONSTRAINT IF EXISTS change_journal_kind_check;
ALTER TABLE change_journal ADD CONSTRAINT change_journal_kind_check
    CHECK (kind IN ('migration', 'code', 'prompt_module', 'config_flip', 'self_extension'));
