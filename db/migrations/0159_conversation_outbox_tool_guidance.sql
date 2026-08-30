-- Make the chat-time outbox path explicit in the DB-owned conversation prompt:
-- a note to the user's dashboard inbox is a real tool operation, not prose.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    '- Confirm before external actions (emails, messages, anything public-facing).
- Be bold with internal actions (reading, searching, organizing).',
    '- Confirm before external actions (emails, messages, anything public-facing).
- When the user asks you to send, leave, queue, or put a note/message to them
  in your outbox, use `queue_user_message` before saying it was queued or sent.
  The dashboard inbox/outbox path is internal user-facing delivery, not a
  substitute for an external email/SMS/chat send.
- Be bold with internal actions (reading, searching, organizing).'
)
WHERE key = 'conversation'
  AND content NOT LIKE '%dashboard inbox/outbox path is internal user-facing delivery%';
