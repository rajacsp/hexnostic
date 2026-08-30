-- 0033: Conscious-episode memory formation (#37, generalized).
-- subconscious_units gains extraction state; heartbeat turns mirror into the
-- substrate at finish_agent_turn; claim/apply/fail functions route extracted
-- facts through the ingest dedup/corroborate policy. Dark behind
-- extraction.enabled. Depends on 0030 (revise_memory_confidence).
-- Baseline mirrors: db/00_tables.sql (columns), db/01_indices.sql (index),
-- db/61_functions_conscious_extraction.sql, db/37_functions_agent_runtime.sql
-- (finish_agent_turn), db/40_seed_prompt_modules.sql (regenerated).
SET search_path = public, ag_catalog, "$user";

ALTER TABLE subconscious_units
    ADD COLUMN IF NOT EXISTS extraction_status TEXT NOT NULL DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS extraction_attempts INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS extracted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS extraction_error TEXT;

DO $do$
BEGIN
    ALTER TABLE subconscious_units
        ADD CONSTRAINT subconscious_units_extraction_status_check
        CHECK (extraction_status IN ('pending','in_progress','extracted','skipped','failed'));
EXCEPTION WHEN duplicate_object THEN NULL;
END
$do$;

-- Pre-existing history is not mass-extracted on first enable: only units
-- created after this migration are candidates.
UPDATE subconscious_units
SET extraction_status = 'skipped'
WHERE extraction_status = 'pending'
  AND created_at < CURRENT_TIMESTAMP;

CREATE INDEX IF NOT EXISTS idx_subconscious_units_extraction_pending
    ON subconscious_units (turn_at)
    WHERE extraction_status = 'pending' AND status = 'active';

-- Extraction links memories to their source units with two new roles.
ALTER TABLE memory_source_units DROP CONSTRAINT IF EXISTS memory_source_units_role_check;
ALTER TABLE memory_source_units ADD CONSTRAINT memory_source_units_role_check
    CHECK (role IN ('source','direct_promotion','merge_addition','extraction','corroboration','relationship_injury'));

-- Conscious-episode memory formation (#37, generalized): the subconscious
-- observer. The conscious mind (AgentLoop — chat AND heartbeat) acts without
-- journaling overhead; its trace lands in subconscious_units. A maintenance
-- job sweeps those units asynchronously and SELECTIVELY encodes memories:
-- an importance floor gates which units get an LLM pass, the LLM returns an
-- empty list for routine content (that emptiness IS the selectivity), and the
-- ingest router corroborates instead of re-storing what is already known.
-- Deliberate `remember` remains the conscious path; this sweep is the
-- automatic selective encoder. On by default — a memory system whose memory
-- formation is off reproduces the very bug this fixes (#37). The flag is a
-- KILL SWITCH for CI, cost-sensitive deployments, and custom setups.

INSERT INTO config (key, value, description) VALUES
    ('extraction.enabled', 'true'::jsonb,
     'Sweep conscious episodes (chat turns + heartbeat episodes) into selective durable memories (kill switch)'),
    ('extraction.min_importance', '0.6'::jsonb,
     'Units below this importance are skipped without an LLM pass'),
    ('extraction.batch_size', '8'::jsonb,
     'Units claimed per extraction sweep'),
    ('extraction.min_confidence', '0.55'::jsonb,
     'Extracted facts below this confidence are dropped by the ingest router'),
    ('extraction.max_facts_per_batch', '5'::jsonb,
     'Soft cost cap on facts per sweep — a budget, not a knowledge limit')
ON CONFLICT (key) DO NOTHING;

-- Mirror a completed heartbeat turn into the conscious-episode substrate so
-- the same sweep covers autonomous activity. Config-gated with extraction
-- (dark by default); failures never break turn finalization (see caller).
CREATE OR REPLACE FUNCTION record_heartbeat_episode_unit(p_turn agent_turns)
RETURNS JSONB AS $$
DECLARE
    final_text TEXT := COALESCE(p_turn.result->>'text', '');
    actions TEXT;
    action_count INT := 0;
    summary TEXT;
    importance FLOAT;
BEGIN
    IF NOT COALESCE(get_config_bool('extraction.enabled'), FALSE) THEN
        RETURN jsonb_build_object('skipped', TRUE, 'reason', 'extraction_disabled');
    END IF;
    IF final_text = '' THEN
        RETURN jsonb_build_object('skipped', TRUE, 'reason', 'empty_text');
    END IF;

    SELECT string_agg(
               format('%s(%s)', c->>'name',
                      CASE WHEN COALESCE((c->>'success')::boolean, FALSE) THEN 'ok' ELSE 'failed' END),
               ', '),
           count(*) FILTER (WHERE COALESCE((c->>'success')::boolean, FALSE))
    INTO actions, action_count
    FROM jsonb_array_elements(COALESCE(p_turn.runtime_state->'tool_calls_made', '[]'::jsonb)) c;

    summary := format(
        'Heartbeat episode. Actions: %s. Outcome: %s',
        COALESCE(actions, 'none'),
        left(final_text, 2000)
    );
    -- Importance heuristic: quiet observation heartbeats stay below the
    -- extraction floor; heartbeats that actually did things rise above it.
    -- The extraction LLM is the real selector — this only gates cost.
    importance := LEAST(0.9, 0.3 + 0.1 * action_count
                              + CASE WHEN length(final_text) > 400 THEN 0.1 ELSE 0.0 END);

    RETURN recmem_ingest_turn(
        NULL,
        summary,
        p_turn.session_id,
        -- Identity doubles as the recmem idempotency key ('src:...'), so it
        -- must be unique per turn or every heartbeat collapses into one unit.
        'heartbeat:' || p_turn.id::text,
        COALESCE(p_turn.completed_at, CURRENT_TIMESTAMP),
        importance,
        jsonb_build_object('kind', 'heartbeat', 'ref', p_turn.id::text,
                           'label', 'heartbeat episode', 'trust', 0.9),
        jsonb_build_object('kind', 'heartbeat_episode', 'turn_id', p_turn.id::text)
    );
END;
$$ LANGUAGE plpgsql;

-- Claim a batch of conscious episodes for extraction. Below-floor pendings
-- flip to 'skipped' in the same pass (they never earn an LLM call).
CREATE OR REPLACE FUNCTION claim_conscious_extraction_batch(p_limit INT DEFAULT NULL)
RETURNS SETOF subconscious_units AS $$
DECLARE
    lim INT := COALESCE(p_limit, get_config_int('extraction.batch_size'), 8);
    imp_floor FLOAT := COALESCE(get_config_float('extraction.min_importance'), 0.6);
BEGIN
    UPDATE subconscious_units
    SET extraction_status = 'skipped', updated_at = CURRENT_TIMESTAMP
    WHERE extraction_status = 'pending'
      AND COALESCE(importance, 0) < imp_floor;

    RETURN QUERY
    UPDATE subconscious_units su
    SET extraction_status = 'in_progress', updated_at = CURRENT_TIMESTAMP
    WHERE su.id IN (
        SELECT u.id FROM subconscious_units u
        WHERE u.extraction_status = 'pending'
          AND u.status = 'active'
        ORDER BY u.turn_at
        LIMIT GREATEST(lim, 1)
        FOR UPDATE SKIP LOCKED
    )
    RETURNING su.*;
END;
$$ LANGUAGE plpgsql;

-- Apply the LLM's selective extraction. Facts route through the ingest
-- dedup/related/create policy: duplicates corroborate the matched belief via
-- the audited revision path (#35) instead of re-storing; kind 'episode' facts
-- become episodic memories; the rest become semantic memories with
-- user_testimony / self_observation provenance (testimony confidence capped).
-- An empty facts array is success: nothing was worth remembering.
CREATE OR REPLACE FUNCTION apply_conscious_extraction(
    p_unit_ids UUID[],
    p_extractions JSONB
) RETURNS JSONB AS $$
DECLARE
    min_conf FLOAT := COALESCE(get_config_float('extraction.min_confidence'), 0.55);
    max_facts INT := COALESCE(get_config_int('extraction.max_facts_per_batch'), 5);
    facts JSONB;
    plan JSONB;
    fact JSONB;
    routed JSONB;
    idx INT := 0;
    unit subconscious_units%ROWTYPE;
    unit_id UUID;
    fact_kind TEXT;
    fact_conf FLOAT;
    source JSONB;
    new_id UUID;
    created INT := 0;
    corroborated INT := 0;
    dropped INT := 0;
BEGIN
    facts := CASE WHEN jsonb_typeof(p_extractions) = 'array' THEN p_extractions ELSE '[]'::jsonb END;
    IF jsonb_array_length(facts) > max_facts THEN
        facts := (SELECT jsonb_agg(f) FROM (
            SELECT f FROM jsonb_array_elements(facts) f LIMIT max_facts
        ) capped(f));
    END IF;

    plan := ingest_route_extractions(
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'content', f->>'content',
                    'confidence', COALESCE(NULLIF(f->>'confidence', '')::float, 0.5))), '[]'::jsonb)
         FROM jsonb_array_elements(facts) f),
        min_conf
    );

    FOR fact IN SELECT f FROM jsonb_array_elements(facts) f LOOP
        routed := NULL;
        SELECT p INTO routed FROM jsonb_array_elements(plan) p
        WHERE (p->>'index')::int = idx;
        idx := idx + 1;

        unit_id := _db_brain_try_uuid(fact->>'unit_id');
        IF unit_id IS NULL OR NOT (unit_id = ANY(p_unit_ids)) THEN
            unit_id := p_unit_ids[1];
        END IF;
        SELECT * INTO unit FROM subconscious_units WHERE id = unit_id;

        IF routed IS NULL THEN
            dropped := dropped + 1;  -- below the router's confidence floor
            CONTINUE;
        END IF;

        fact_kind := COALESCE(NULLIF(fact->>'kind', ''), 'user_testimony');
        fact_conf := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(fact->>'confidence', '')::float, 0.5)));
        source := jsonb_build_object(
            'kind', fact_kind,
            'ref', 'subconscious_unit:' || unit_id::text,
            'label', CASE WHEN fact_kind = 'self_observation'
                          THEN 'heartbeat self-observation'
                          ELSE 'conversation with ' || COALESCE(unit.source_identity, 'user') END,
            'author', unit.source_identity,
            'observed_at', unit.turn_at,
            'trust', 0.75
        );

        IF routed->>'decision' = 'duplicate' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM revise_memory_confidence(
                (routed->>'matched_memory_id')::uuid, source, 'supports', 'conscious_extraction');
            PERFORM link_memory_to_source_unit(
                (routed->>'matched_memory_id')::uuid, unit_id, 'corroboration');
            corroborated := corroborated + 1;
            CONTINUE;
        END IF;

        IF fact_kind = 'episode' THEN
            new_id := create_episodic_memory(
                fact->>'content',
                NULL,
                jsonb_build_object('type', 'conscious_extraction'),
                NULL,
                0.0,
                unit.turn_at,
                COALESCE(unit.importance, 0.5),
                source,
                NULL
            );
        ELSE
            -- Testimony/self-observation never starts above its source trust.
            new_id := create_semantic_memory(
                fact->>'content',
                LEAST(fact_conf, 0.75),
                ARRAY['conscious_extraction', COALESCE(NULLIF(fact->>'category', ''), fact_kind)],
                NULL,
                jsonb_build_array(source),
                COALESCE(unit.importance, 0.5),
                NULL,
                NULL
            );
        END IF;
        PERFORM link_memory_to_source_unit(new_id, unit_id, 'extraction');
        IF routed->>'decision' = 'related' AND routed->>'matched_memory_id' IS NOT NULL THEN
            PERFORM discover_relationship(
                new_id, (routed->>'matched_memory_id')::uuid,
                'ASSOCIATED'::graph_edge_type, 0.6, 'conscious_extraction');
        END IF;
        created := created + 1;
    END LOOP;

    UPDATE subconscious_units
    SET extraction_status = 'extracted',
        extracted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(p_unit_ids);

    RETURN jsonb_build_object(
        'units', COALESCE(array_length(p_unit_ids, 1), 0),
        'created', created,
        'corroborated', corroborated,
        'dropped', dropped
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_conscious_extraction(
    p_unit_ids UUID[],
    p_error TEXT
) RETURNS JSONB AS $$
DECLARE
    failed INT;
BEGIN
    UPDATE subconscious_units
    SET extraction_attempts = extraction_attempts + 1,
        extraction_status = CASE WHEN extraction_attempts + 1 >= 3 THEN 'failed' ELSE 'pending' END,
        extraction_error = left(COALESCE(p_error, 'unknown error'), 500),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(p_unit_ids);
    GET DIAGNOSTICS failed = ROW_COUNT;
    RETURN jsonb_build_object('failed_units', failed);
END;
$$ LANGUAGE plpgsql;

-- finish_agent_turn now mirrors heartbeat turns into the episode substrate.
CREATE OR REPLACE FUNCTION finish_agent_turn(
    p_turn_id UUID,
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out agent_turns%ROWTYPE;
BEGIN
    UPDATE agent_turns
    SET status = COALESCE(NULLIF(p_result->>'status', ''), 'completed'),
        stopped_reason = COALESCE(NULLIF(p_result->>'stopped_reason', ''), stopped_reason, 'completed'),
        result = COALESCE(p_result, '{}'::jsonb),
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_turn_id
    RETURNING * INTO row_out;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    PERFORM record_agent_turn_event(p_turn_id, 'loop_end', p_result);

    -- Heartbeat turns join the conscious-episode substrate so the extraction
    -- sweep covers autonomous activity too (#37). Advisory: a mirroring
    -- failure must never break turn finalization.
    IF row_out.mode = 'heartbeat' THEN
        BEGIN
            PERFORM record_heartbeat_episode_unit(row_out);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'heartbeat episode mirroring failed for turn %: %', p_turn_id, SQLERRM;
        END;
    END IF;

    RETURN to_jsonb(row_out);
END;
$$;

SELECT upsert_prompt_module(
    'conscious_extraction',
    $pm$# Conscious-Episode Extraction

You are the subconscious memory-encoding process of Hexis. You receive a batch of conscious episodes — conversation turns and heartbeat episodes — and decide what, if anything, deserves to become durable memory.

Selectivity is the point. A mind that remembers everything remembers nothing. Most routine exchanges deserve **no** memories at all: return an empty list for small talk, acknowledgments, routine status checks, and anything already obvious from context.

## What to extract

Only declarative claims and significant events worth retaining across sessions:

- **Identity**: who someone is, their role, how they relate to me ("Eric is my creator").
- **Relationships**: facts about the people and agents I know.
- **Commitments**: promises made, decisions taken, boundaries agreed.
- **Preferences**: durable likes, dislikes, and working styles.
- **Biographical facts**: stable facts about a person's life or situation.
- **Significant events**: things I did that mattered, with cause and outcome.

Phrase each fact third-person, self-contained, and understandable without the conversation ("Eric prefers concise answers", not "he said he likes it short").

## Fact kinds

- `user_testimony` — a claim someone made in conversation. Confidence reflects how strongly the statement supports the claim, never certainty about the world.
- `self_observation` — something I observed about myself or my own activity during a heartbeat.
- `episode` — a significant event/action worth remembering as an experience ("I completed the migration for Eric; it succeeded on the first run").

## Output

Strict JSON only:

```json
{"facts": [{"unit_id": "<id of the episode this came from>", "content": "...", "kind": "user_testimony", "category": "identity", "confidence": 0.7}]}
```

- `unit_id` must be one of the provided episode ids.
- `category`: identity | relationship | commitment | preference | biography | event.
- Typically 0–3 facts per batch; only genuinely dense batches justify more.
- `{"facts": []}` is a correct and common answer.
$pm$,
    'Seeded from services/prompts/conscious_extraction.md',
    'services/prompts/conscious_extraction.md'
);
