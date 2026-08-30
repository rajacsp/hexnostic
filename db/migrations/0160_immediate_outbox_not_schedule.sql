-- Clarify that immediate dashboard/outbox notes use queue_user_message
-- directly; scheduling is only for explicit future/recurring work.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    '  The dashboard inbox/outbox path is internal user-facing delivery, not a
  substitute for an external email/SMS/chat send.
- Be bold with internal actions (reading, searching, organizing).',
    '  The dashboard inbox/outbox path is internal user-facing delivery, not a
  substitute for an external email/SMS/chat send.
  Use `manage_schedule` only when the user asks for an explicit future time,
  delay, recurrence, or reminder. Do not invent a delay to make the message
  feel more independent.
- Be bold with internal actions (reading, searching, organizing).'
)
WHERE key = 'conversation'
  AND content NOT LIKE '%Do not invent a delay to make the message%';
