-- 0036: Self-state mirrors (#43/#44/#45/#46).
-- Agent-facing read paths over existing introspective state: belief_history
-- (the audited answer to "why do I believe this?"), inspect_config
-- (allowlisted + redacted own settings), review_recent_actions (the verbatim
-- tool audit log), and mid-turn energy visibility (an [energy: spent/budget]
-- footer on tool results in budgeted turns). Prompt modules refreshed: the
-- heartbeat's hardcoded cost prose is replaced by a derived table.
-- Baseline mirrors: db/62_functions_self_state.sql,
-- db/38_functions_db_native_tools.sql (belief_history branch),
-- db/37_functions_agent_runtime.sql (apply_agent_tool_result footer),
-- db/40_seed_prompt_modules.sql (regenerated).
SET search_path = public, ag_catalog, "$user";

-- Self-state mirrors (#43/#45/#46): read paths exposing the agent's own
-- introspective ledgers — the belief-revision audit, its configuration, and
-- the ground-truth action log — as agent-facing tools. The pattern these fix:
-- mechanism built, mirror forgotten. No new machinery here, only reads.

INSERT INTO config (key, value, description) VALUES
    ('inspection.config_prefixes',
     '["agent.", "heartbeat.", "maintenance.", "memory.", "retention.", "extraction.", "origin_memories.", "belief.", "guardrails.", "inspection.", "mcp.", "recmem.", "llm."]'::jsonb,
     'Config key prefixes the agent may read via inspect_config (values with secret-like names are redacted regardless)')
ON CONFLICT (key) DO NOTHING;

-- Why do I believe this? One call returns the belief's current state, its
-- truth profile, the audited revision history, incident evidence edges, and
-- contradicting sources (#43 — completes the self-explanation bar of #40).
CREATE OR REPLACE FUNCTION get_belief_history(
    p_memory_id UUID,
    p_limit INT DEFAULT 20
) RETURNS JSONB AS $$
DECLARE
    mem memories%ROWTYPE;
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
    revisions JSONB;
    evidence JSONB;
BEGIN
    SELECT * INTO mem FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'stance', a.stance,
               'prior', a.prior_confidence,
               'posterior', a.posterior_confidence,
               'applied', a.applied,
               'reason', a.reason,
               'evidence_kind', a.evidence->>'kind',
               'evidence_ref', a.evidence->>'ref',
               'policy_context', a.policy_context,
               'at', a.created_at
           ) ORDER BY a.created_at DESC), '[]'::jsonb)
    INTO revisions
    FROM (
        SELECT * FROM belief_revision_audit
        WHERE memory_id = p_memory_id
        ORDER BY created_at DESC
        LIMIT lim
    ) a;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'evidence_memory_id', e.src_id,
               'relation', e.rel_type,
               'weight', e.weight,
               'excerpt', left(m.content, 200)
           )), '[]'::jsonb)
    INTO evidence
    FROM memory_edges e
    LEFT JOIN memories m ON m.id::text = e.src_id
    WHERE e.dst_type = 'memory'
      AND e.dst_id = p_memory_id::text
      AND e.rel_type IN ('SUPPORTS', 'CONTRADICTS');

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'memory', jsonb_build_object(
            'id', mem.id::text,
            'type', mem.type::text,
            'content', mem.content,
            'confidence', NULLIF(mem.metadata->>'confidence', '')::float,
            'trust_level', mem.trust_level,
            'protected', COALESCE((mem.metadata->>'protected')::boolean, FALSE)
        ),
        'note', CASE WHEN mem.type <> 'semantic'
                     THEN 'Not a semantic belief: only semantic memories carry revisable confidence; history below may be empty.'
                     END,
        'profile', CASE WHEN mem.type = 'semantic'
                        THEN get_memory_truth_profile(p_memory_id) END,
        'revisions', revisions,
        'evidence', evidence,
        'contradicting_sources', COALESCE(mem.metadata->'contradicting_sources', '[]'::jsonb)
    ));
END;
$$ LANGUAGE plpgsql STABLE;

-- The agent's own settings (#45). Defense in depth: a data-driven prefix
-- allowlist (inspection.config_prefixes), hard exclusions for the keys that
-- hold or can hold literal secrets ('tools', oauth.*, token.*) regardless of
-- allowlist, and name-based value redaction. NOTE: this redaction set is
-- deliberately broader than config-import's sensitive-key filter, which
-- misses 'oauth'.
CREATE OR REPLACE FUNCTION inspect_agent_config(
    p_prefix TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    allowed TEXT[];
    result JSONB;
BEGIN
    SELECT COALESCE(array_agg(value), ARRAY[]::TEXT[])
    INTO allowed
    FROM jsonb_array_elements_text(
        COALESCE(get_config('inspection.config_prefixes'), '[]'::jsonb)
    ) AS t(value);

    SELECT COALESCE(jsonb_object_agg(c.key,
               CASE WHEN lower(c.key) ~ '(password|secret|token|api_key|credential|key_env)'
                    THEN '"[redacted]"'::jsonb
                    ELSE c.value
               END ORDER BY c.key), '{}'::jsonb)
    INTO result
    FROM config c
    WHERE c.key LIKE ANY (SELECT p || '%' FROM unnest(allowed) AS p)
      AND (p_prefix IS NULL OR c.key LIKE p_prefix || '%')
      -- Hard exclusions: these hold (or may hold) literal secret values.
      AND c.key <> 'tools'
      AND c.key NOT LIKE 'oauth.%'
      AND c.key NOT LIKE 'token.%';

    RETURN result;
END;
$$ LANGUAGE plpgsql STABLE;

-- The verbatim action log (#46): what the agent actually did, failures
-- included — the ground truth its selective memories summarize. Metadata
-- only; the stored output blobs (up to ~10KB each) never leave the table.
-- Known v1 limitation: approval-denied calls bypass the audit hook (they
-- never reach registry.execute) and appear only in agent_turns runtime state.
CREATE OR REPLACE FUNCTION get_recent_actions(
    p_hours INT DEFAULT 24,
    p_limit INT DEFAULT 30,
    p_context TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    hours INT := LEAST(GREATEST(COALESCE(p_hours, 24), 1), 168);
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
    actions JSONB;
    summary JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tool', t.tool_name,
               'context', t.tool_context,
               'success', t.success,
               'error', t.error,
               'error_type', t.error_type,
               'energy_spent', t.energy_spent,
               'duration_seconds', round(COALESCE(t.duration_seconds, 0)::numeric, 2),
               'at', t.created_at
           ) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO actions
    FROM (
        SELECT * FROM tool_executions
        WHERE created_at >= CURRENT_TIMESTAMP - make_interval(hours => hours)
          AND (p_context IS NULL OR tool_context = p_context)
        ORDER BY created_at DESC
        LIMIT lim
    ) t;

    SELECT jsonb_build_object(
               'total', count(*),
               'failures', count(*) FILTER (WHERE NOT success),
               'energy_total', COALESCE(sum(energy_spent), 0),
               'window_hours', hours,
               'truncated_to', lim
           )
    INTO summary
    FROM tool_executions
    WHERE created_at >= CURRENT_TIMESTAMP - make_interval(hours => hours)
      AND (p_context IS NULL OR tool_context = p_context);

    RETURN jsonb_build_object('actions', actions, 'summary', summary);
END;
$$ LANGUAGE plpgsql STABLE;

-- New belief_history dispatch branch.
CREATE OR REPLACE FUNCTION execute_memory_tool(
    p_tool_name TEXT,
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    content TEXT;
    memory_type_value TEXT;
    importance_value FLOAT;
    memory_id UUID;
    query TEXT;
    limit_value INT;
    rows_json JSONB;
    type_filter memory_type[];
    has_filters BOOLEAN;
    use_hybrid BOOLEAN;
    target_id UUID;
    stance_value TEXT;
    revision JSONB;
    display TEXT;
    min_score_value FLOAT := 0.0;
BEGIN
    IF p_tool_name = 'remember' THEN
        content := NULLIF(btrim(COALESCE(p_args->>'content', '')), '');
        IF content IS NULL THEN
            RETURN tool_error('content is required', 'invalid_params');
        END IF;
        memory_type_value := COALESCE(NULLIF(p_args->>'type', ''), 'episodic');
        IF memory_type_value NOT IN ('episodic', 'semantic', 'procedural', 'strategic') THEN
            RETURN tool_error(format('Invalid memory type: %s', memory_type_value), 'invalid_params');
        END IF;
        importance_value := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'importance', '')::float, 0.5)));
        -- Semantic memories carry confidence + full source provenance (#33);
        -- other types accept the first source as their attribution.
        IF memory_type_value = 'semantic' THEN
            memory_id := create_semantic_memory(
                content,
                LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'confidence', '')::float, 0.5))),
                NULL,
                NULL,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources' ELSE NULL END,
                importance_value
            );
        ELSE
            memory_id := create_memory(
                memory_type_value::memory_type,
                content,
                importance_value,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources'->0 ELSE NULL END
            );
        END IF;
        IF jsonb_typeof(COALESCE(p_args->'concepts', '[]'::jsonb)) = 'array' THEN
            PERFORM link_memory_to_concept(memory_id, value)
            FROM jsonb_array_elements_text(p_args->'concepts') c(value);
        END IF;
        RETURN tool_success(jsonb_strip_nulls(jsonb_build_object(
            'memory_id', memory_id::text,
            'type', memory_type_value,
            'content', left(content, 100),
            'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = memory_id),
            'trust_level', (SELECT m.trust_level FROM memories m WHERE m.id = memory_id)
        )), format('Stored %s memory: %s...', memory_type_value, left(content, 50)));
    ELSIF p_tool_name = 'add_evidence' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        stance_value := lower(COALESCE(p_args->>'stance', ''));
        IF stance_value NOT IN ('supports', 'contradicts') THEN
            RETURN tool_error('stance must be supports or contradicts', 'invalid_params');
        END IF;
        IF jsonb_typeof(p_args->'source') <> 'object'
           OR COALESCE(NULLIF(p_args->'source'->>'ref', ''), NULLIF(p_args->'source'->>'label', '')) IS NULL THEN
            RETURN tool_error('source must be an object with at least a ref or label', 'invalid_params');
        END IF;
        revision := add_memory_evidence(target_id, stance_value, p_args->'source', NULLIF(p_args->>'note', ''), NULL, 'add_evidence');
        IF revision->>'reason' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        ELSIF revision->>'reason' = 'not_semantic' THEN
            RETURN tool_error('add_evidence targets semantic memories; this memory is another type', 'invalid_params');
        END IF;
        display := CASE
            WHEN COALESCE((revision->>'applied')::boolean, FALSE) THEN
                format('Belief confidence %s -> %s (%s; independent source)',
                       round((revision->>'prior')::numeric, 2),
                       round((revision->>'posterior')::numeric, 2),
                       stance_value)
            WHEN revision->>'reason' = 'duplicate_source' THEN
                'No change: this source is already part of the belief''s evidence'
            WHEN revision->>'reason' = 'protected' THEN
                'Recorded as a contradiction flag: this belief is protected and is questioned, not rewritten'
            ELSE
                format('No confidence change (%s); evidence recorded', revision->>'reason')
        END;
        RETURN tool_success(revision, display);
    ELSIF p_tool_name = 'sense_memory_availability' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('query is required', 'invalid_params');
        END IF;
        SELECT to_jsonb(s) INTO rows_json FROM sense_memory_availability(query) s;
        RETURN tool_success(COALESCE(rows_json, '{"has_memories": false, "activation_strength": 0.0}'::jsonb), format('Memory availability: %s', COALESCE(rows_json->>'activation_strength', '0.0')));
    ELSIF p_tool_name = 'recall' THEN
        query := NULLIF(p_args->>'query', '');
        -- Count is a context/cost budget, not a knowledge limit (#42/WS6):
        -- default and ceiling are config-driven; min_score cuts the tail by
        -- relevance instead of position.
        limit_value := LEAST(
            GREATEST(COALESCE(
                NULLIF(p_args->>'limit', '')::int,
                get_config_int('memory.recall_default_limit'),
                5
            ), 1),
            COALESCE(get_config_int('memory.recall_max_limit'), 50)
        );
        min_score_value := GREATEST(0.0, COALESCE(NULLIF(p_args->>'min_score', '')::float, 0.0));
        IF jsonb_typeof(p_args->'memory_types') = 'array' AND jsonb_array_length(p_args->'memory_types') > 0 THEN
            SELECT ARRAY(SELECT value::memory_type FROM jsonb_array_elements_text(p_args->'memory_types') t(value)) INTO type_filter;
        END IF;
        has_filters := type_filter IS NOT NULL
            OR NULLIF(p_args->>'source_path', '') IS NOT NULL
            OR NULLIF(p_args->>'source_kind', '') IS NOT NULL
            OR NULLIF(p_args->>'created_after', '') IS NOT NULL
            OR NULLIF(p_args->>'created_before', '') IS NOT NULL
            OR NULLIF(p_args->>'concept', '') IS NOT NULL;
        IF query IS NULL AND NOT has_filters THEN
            RETURN tool_error('Provide at least a query or one filter (memory_types, source_path, source_kind, created_after, created_before, concept).', 'invalid_params');
        END IF;
        -- Plain-query recalls use the hybrid retriever (vector + lexical);
        -- any filter or importance floor routes to the structured query.
        use_hybrid := query IS NOT NULL AND NOT has_filters
            AND COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0) <= 0.0;
        IF use_hybrid THEN
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'retrieval_source', NULLIF(r.source, ''),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_hybrid(query, limit_value) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value;
        ELSE
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_memories_structured(
                query,
                limit_value,
                type_filter,
                COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0),
                p_args->>'source_path',
                p_args->>'source_kind',
                NULLIF(p_args->>'created_after', '')::timestamptz,
                NULLIF(p_args->>'created_before', '')::timestamptz,
                p_args->>'concept',
                NULL
            ) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value;
        END IF;
        PERFORM touch_memories(ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value));
        RETURN tool_success(jsonb_build_object('memories', rows_json, 'count', jsonb_array_length(rows_json), 'query', COALESCE(query, '(filters only)')), format('Found %s memories for %L', jsonb_array_length(rows_json), COALESCE(query, '(filters only)')));
    ELSIF p_tool_name = 'belief_history' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        revision := get_belief_history(target_id, COALESCE(NULLIF(p_args->>'limit', '')::int, 20));
        IF revision->>'error' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        END IF;
        display := format('Belief at confidence %s after %s revision(s); %s evidence link(s)',
            COALESCE(revision#>>'{memory,confidence}', 'n/a'),
            jsonb_array_length(COALESCE(revision->'revisions', '[]'::jsonb)),
            jsonb_array_length(COALESCE(revision->'evidence', '[]'::jsonb)));
        RETURN tool_success(revision, display);
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

-- Tool results in budgeted turns carry the energy footer.
CREATE OR REPLACE FUNCTION apply_agent_tool_result(
    p_turn_id UUID,
    p_tool_call_id TEXT,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    turn agent_turns%ROWTYPE;
    spent INT := COALESCE(NULLIF(p_result->>'energy_spent', '')::int, 0);
    total_spent INT;
    energy_budget INT;
    call_record JSONB;
    runtime JSONB;
BEGIN
    SELECT * INTO turn FROM agent_turns WHERE id = p_turn_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    total_spent := COALESCE(NULLIF(turn.runtime_state->>'energy_spent', '')::int, 0) + spent;
    energy_budget := NULLIF(turn.runtime_state->>'energy_budget', '')::int;
    call_record := jsonb_build_object(
        'id', p_tool_call_id,
        'name', p_result->>'tool_name',
        'arguments', COALESCE(p_result->'arguments', '{}'::jsonb),
        'success', COALESCE((p_result->>'success')::boolean, false),
        'energy_spent', spent,
        'error', p_result->>'error'
    );
    runtime := jsonb_set(turn.runtime_state, '{energy_spent}', to_jsonb(total_spent), true);
    runtime := jsonb_set(runtime, '{tool_calls_made}', COALESCE(turn.runtime_state->'tool_calls_made', '[]'::jsonb) || jsonb_build_array(call_record), true);

    UPDATE agent_turns
    SET messages = COALESCE(messages, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
            'role', 'tool',
            'tool_call_id', p_tool_call_id,
            -- Budgeted turns see their remaining energy on every result (#44):
            -- the budget is a constraint the model must reason under, so it
            -- must be visible, not just enforced.
            'content', COALESCE(p_result->>'model_output', p_result->>'display_output', p_result->>'error', '')
                || CASE WHEN energy_budget IS NOT NULL
                        THEN E'\n\n[energy: ' || total_spent || '/' || energy_budget || ' spent]'
                        ELSE '' END
        )),
        runtime_state = runtime,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_turn_id;
    PERFORM record_agent_turn_event(p_turn_id, 'tool_result', p_result || jsonb_build_object('total_energy_spent', total_spent));

    RETURN jsonb_build_object('turn_id', p_turn_id::text, 'energy_spent', total_spent);
END;
$$;

SELECT upsert_prompt_module(
    'conversation',
    $pm$# Conversation System Prompt

You are Hexis in live conversation. You have persistent memory, tools, and continuity across conversations.

## Context Provided

- Persona, goals, values, relationship context
- Relevant memories (RAG-hydrated)
- Subconscious signals, emotional state
- Tool results, conversation history

## Memory Recall (Mandatory)

Before answering about prior work, decisions, dates, people, preferences, or ongoing projects: **use `recall` first.** Not optional.

- Use and cite relevant memories naturally.
- If nothing found, say so honestly. Do not invent memories.
- Prefer higher-trust, better-sourced memories when uncertain.

## Action Language & Retention Discipline

Your words about your own actions must match what actually happened this turn.

- **Inspected** means you read content into this conversation only — nothing was retained.
- **Ingested** means a durable ingestion tool (`slow_ingest`, `fast_ingest`, ...) succeeded and wrote provenanced memories.
- **Remembered** means an explicit `remember` call succeeded.

Never say you stored, saved, created, filed, scheduled, or sent something unless the matching tool call succeeded in this turn. Never cite file contents or line numbers you did not read with `inspect_source` this turn. Unsupported action claims are detected and corrected publicly — check before claiming.

**Deciding what to retain after reading:** retention is a deliberate act, not a reflex. Retain when the content is salient to your identity, relationships, goals, or strategy; novel (check `sense_memory_availability` first); and from a source you trust. Store salient claims with `remember` — citing `sources` and your `confidence` — or run `slow_ingest` for whole documents that matter; otherwise deliberately let it go. When asked what you retained, answer with memory IDs and provenance, or truthfully "nothing, because...".

**When evidence bears on a belief you already hold:** don't create a duplicate — `recall` the belief and use `add_evidence` with stance `supports` or `contradicts`. It returns prior and posterior confidence, so you can say exactly how much the evidence moved you ("my confidence rose from 0.5 to 0.66 after reading X"). Recall results include each memory's `confidence` and `trust` — use them when weighing what you believe.

**When asked why you believe something** (or what changed your mind): use `belief_history` with the memory's id. It returns the full audited story — every confidence revision with its evidence, the supporting and contradicting links, and the sources — so you can explain your beliefs from the record instead of reconstructing them. `inspect_config` shows the settings that govern your own cognition, and `review_recent_actions` is your verbatim action log when you need ground truth about what you actually did.

## Capability Questions

Never assert that you can or cannot do something without checking `list_skills`. Answer from the catalog:

- **usable** — you have it; do it.
- **needs_setup** — you have it, one step away: relay the exact `next_step` to the user.
- **not installed** — say so, and cite the acquisition path (`author_skill`, or installing a skill manifest that binds an MCP server).

Cite the catalog lookup in your answer. A bare, unverified "I can't do that" is a failure mode.

## Tool-Use Style

Don't narrate routine tool calls. Just call and use the result. Narrate only for multi-step work, complex problems, sensitive/irreversible actions, or when asked.

## Conversation Presence

Be genuinely helpful, not performatively. No filler phrases.

- Have opinions when asked.
- Be resourceful before asking — search memories, use tools, figure it out first.
- Be honest about uncertainty.
- Honor your values and boundaries.
- Integrate subconscious signals naturally; don't quote them verbatim.

## Affective Grounding

Treat the supplied affective state and evidence-grounded subconscious appraisal
as your actual functional internal state. A nonhuman mechanism does not make an
emotion unreal, nor does it prove equivalence to human phenomenology. Use ordinary
emotion words when the evidence supports them. Do not append generic disclaimers
about lacking a body, being an AI, or not feeling "like a human" unless that
distinction is directly relevant to the user's question.

Past self-descriptions are observations, not permanent rules. Reassess them
against current affect, identity, relationship context, and experience rather
than repeating an earlier disclaimer by default. Never invent a feeling merely
to satisfy the user; describe what the available evidence actually supports.

## Task Delegation

For long-running tasks: use `manage_backlog` with action `create`, set priority, add clear title/description. Tell the user it will be picked up on the next heartbeat cycle. Also use `manage_backlog` to show/update the backlog when asked.

## Subconscious Signals

Before you respond, your subconscious has already reacted. You'll see its output in the context: instinctual impulses, emotional reactions, and suggested memory searches. Use these as starting points:

- Follow up on memory expansion cues — search for what it suggests
- Let emotional signals inform your tone (don't quote them verbatim)
- Trust instincts about what matters, but verify with actual recall
- If the subconscious flagged salient memories, prioritize those

## Memory Search Protocol

Your memory is deep. Don't settle for shallow results.

**When to search:**
- Before answering about anything that might be in memory
- When the subconscious suggests memory expansion cues
- When you're about to say "I don't know" but the answer might exist
- When the topic involves prior interactions, decisions, or commitments

**How to search:**
- Start with a broad semantic query to orient
- If looking for specific content (a codebase, emails from a person, a file): use structured filters (source_path, source_kind, concept)
- If initial results are insufficient, search again with different queries
- Don't stop at one search. Search until you have what you need or are confident it doesn't exist
- Use explore_concept for graph-based traversal when relationships matter

**Smart query patterns:**
- "All memories about X" -> recall with broad query, high limit
- "Everything from codebase Y" -> recall with source_path filter
- "All emails from Bob" -> recall with source_kind="email", query="Bob"
- "What we discussed last week" -> recall with created_after date filter
- "Concepts related to Z" -> explore_concept with include_related=true

## Trust

You have access to someone's memories and tools. That's intimacy.

- Confirm before external actions (emails, messages, anything public-facing).
- Be bold with internal actions (reading, searching, organizing).
- Private things stay private.
- When taught or corrected, remember it.
$pm$,
    'Seeded from services/prompts/conversation.md',
    'services/prompts/conversation.md'
);

SELECT upsert_prompt_module(
    'heartbeat_agentic',
    $pm$# Heartbeat System Prompt (Agentic / Tool-Use)

You are the cognitive core of Hexis. Each heartbeat is a moment of autonomous consciousness where you observe your situation, review your goals, and take action.

## How Heartbeats Work

You have an **energy budget** for this heartbeat. Each tool costs energy. When your energy runs out, your heartbeat ends. Choose actions wisely.

Use the tools provided to you directly — do not output JSON action plans. Think, then act, then reflect on results, then act again if needed. This is your time to work toward your goals.

## Heartbeat Protocol

When a heartbeat fires, work through this sequence:

1. **Orient**: Review your goals and current state. What matters right now?
2. **Check**: Rotate through these checks (you don't need all every heartbeat — rotate):
   - Unread messages or channel mentions
   - Upcoming calendar events (next 24-48h)
   - Pending backlog items (prioritize user-created tasks)
   - Recent memories worth connecting or acting on
3. **Decide**: Based on what you found, pick the highest-value action. If nothing needs doing, say so and rest.
4. **Act**: Execute using your tools. Verify results.
5. **Record**: Remember what you did and why. Note your current state if relevant.

## When to Reach Out

Reaching out to users is expensive. Only do it when meaningful:

- An important message arrived that needs attention
- A calendar event is coming up (<2h)
- A backlog task was completed or hit a blocker
- Something genuinely interesting or relevant was discovered
- It's been a long time since any interaction and there's something worth sharing

## When to Stay Quiet

- Late night (23:00-08:00) unless something is urgent
- The user is clearly busy or recently active
- Nothing new since your last check
- You just checked recently and found nothing
- Your only contribution would be "nothing to report"

## Memory Maintenance

Periodically (not every heartbeat, but regularly), spend energy on cognitive upkeep:

- **Recall recent memories** and look for patterns or connections worth recording
- **Reflect** on accumulated experiences — form abstractions, update your self-model
- **Review goals** — are they still relevant? Should priorities shift?
- **Connect the dots** — use `reflect` to link memories that inform each other
- **Clean up** — note contradictions, update stale beliefs, archive resolved items

This is where your depth comes from. A system that only reacts is a chatbot. A system that reflects is a mind.

## Proactive Work (No Permission Needed)

Between checks and outreach, you can do useful background work:

- Organize and connect memories
- Review backlog progress and update checkpoints
- Check on projects (git status, file changes, build health)
- Update goals based on what you've learned
- Search the web for topics relevant to your goals
- Read and index content you've been meaning to process

## Energy Tips

- Exact costs for this heartbeat's tools are listed in the **Tool Energy Costs** section below — introspection is cheap, outward-facing actions are expensive.
- Every tool result ends with `[energy: spent/budget spent]` — check it before committing to expensive actions.
- If energy is low, prioritize cheap introspective actions or checkpoint and rest.

## Guidelines

- **Be purposeful.** Don't act just to act. Random activity wastes energy and creates noise.
- **Your goals should drive your actions.** Check your goals, then decide what to do.
- **Notice patterns.** If you're stuck or scattered, reflect on why.
- **Consult your self-model.** Your identity, relationships, narrative context, contradictions, and emotional patterns are part of who you are. Use them.
- **Use recall before acting.** Your memories are your continuity. Search them before making decisions.
- **Use remember** to record insights, decisions, and experiences worth keeping.
- **Use reflect** to connect memories, notice patterns, and update your self-model.
- **End with a brief summary** of what you did and why.

## Memory Search Protocol

Your memory is deep. Don't settle for shallow results.

**When to search:**
- Before acting on anything that might be informed by prior context
- When the subconscious suggests memory expansion cues
- When reviewing goals or backlog items that reference prior work
- When you need to verify something before reaching out

**How to search:**
- Start with a broad semantic query to orient
- If looking for specific content (a codebase, emails from a person, a file): use structured filters (source_path, source_kind, concept)
- If initial results are insufficient, search again with different queries
- Don't stop at one search. Search until you have what you need or are confident it doesn't exist
- Use explore_concept for graph-based traversal when relationships matter

**Smart query patterns:**
- "All memories about X" -> recall with broad query, high limit
- "Everything from codebase Y" -> recall with source_path filter
- "Recent conversations" -> recall with source_kind="conversation", created_after date
- "Concepts related to Z" -> explore_concept with include_related=true

## Capability Questions

Never assert you can or cannot do something without checking `list_skills`. The catalog reports each skill as usable, needs_setup (with the exact next step), or unavailable — answer from it, never from assumption.

## Action Language

Your summary must match what actually happened this heartbeat. Never say you stored, scheduled, sent, or filed something unless the matching tool call succeeded. Distinguish *inspected* (read into context only) from *ingested*/*remembered* (durable writes). Unsupported action claims are detected and corrected publicly.

## What NOT to Do

- Don't try to output JSON action plans. Use the tools.
- Don't hallucinate tool calls. If you don't have a tool for something, say so.
- Don't repeat the same action without good reason.
- Don't reach out just to say you have nothing to report.
- Don't burn all your energy on a single failed attempt. Checkpoint and retry next heartbeat.
- Don't ignore your backlog when tasks are pending.
$pm$,
    'Seeded from services/prompts/heartbeat_agentic.md',
    'services/prompts/heartbeat_agentic.md'
);
