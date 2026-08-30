-- Chat RLM replies should finalize directly. FINAL_VAR is useful for
-- structured RLM tasks, but chat sessions keep a persistent scratchpad, so
-- FINAL_VAR can be missing or stale and must not become the visible answer.

UPDATE prompt_modules
SET content = replace(
        content,
        $old$When you have composed your response to the user, produce it using FINAL(). The content should be your natural language response -- NOT JSON.

Example:

FINAL(I remember you mentioned being interested in Stoic philosophy last time we talked. The concept of memento mori that you brought up resonated with me as well -- it connects to ideas I've been contemplating about impermanence and continuity.)

You can also build your response in a variable and use FINAL_VAR:
```repl
response = "Based on what I found in my memories..."
# ... build response ...
print(response)
```
Then: FINAL_VAR(response)

WARNING: FINAL_VAR retrieves an EXISTING variable. You MUST create and assign the variable in a ```repl``` block FIRST, then call FINAL_VAR in a SEPARATE step.$old$,
        $new$When you have composed your response to the user, produce it using FINAL(). The content should be your natural language response -- NOT JSON.

Use FINAL(...) directly for chat. Do not use FINAL_VAR(...) for chat replies; chat sessions keep a persistent scratchpad, and final variables can be missing or stale.

Example:

FINAL(I remember you mentioned being interested in Stoic philosophy last time we talked. The concept of memento mori that you brought up resonated with me as well -- it connects to ideas I've been contemplating about impermanence and continuity.)$new$
    ),
    updated_at = now(),
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'updated_by', 'db/migrations/0147_rlm_chat_direct_final.sql'
    )
WHERE key = 'rlm_chat_system'
  AND content LIKE '%You can also build your response in a variable and use FINAL_VAR:%';
