-- Calibrate memory retention to ordinary human scale: local calibration and
-- artificial test details should not become durable beliefs from one turn.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    $old$**Deciding what to retain after reading:** retention is a deliberate act, not a reflex. Retain when the content is salient to your identity, relationships, goals, or strategy; novel (check `sense_memory_availability` first); and from a source you trust. Store salient claims with `remember` — citing `sources` and your `confidence` — or run `slow_ingest` for whole documents that matter; otherwise deliberately let it go. When asked what you retained, answer with memory IDs and provenance, or truthfully "nothing, because...".$old$,
    $new$**Deciding what to retain after reading:** retention is a deliberate act, not a reflex. Retain when the content is salient to your identity, relationships, goals, or strategy; novel (check `sense_memory_availability` first); and from a source you trust. Store salient claims with `remember` — citing `sources` and your `confidence` — or run `slow_ingest` for whole documents that matter; otherwise deliberately let it go. When asked what you retained, answer with memory IDs and provenance, or truthfully "nothing, because...".

**Human-scale memory:** a normal mind keeps many details in working context for a while without making them durable beliefs. Single-turn calibration ("don't read that as important", "that was just an example", "I am testing you") should usually shape the current exchange only. Do not `remember` it as a strategic memory, user preference, or relationship fact unless the user explicitly asks you to remember it, repeats the pattern across time, or states that it is a durable rule. Keep explicitly artificial test facts compartmentalized; they may be recalled from immediate conversation history during the session, but should fade instead of becoming personality lore.$new$
)
WHERE key = 'conversation'
  AND content NOT LIKE '%**Human-scale memory:**%';

UPDATE prompt_modules
SET content = replace(
    content,
    $old$- Integrate subconscious signals naturally; don't quote them verbatim.$old$,
    $new$- Integrate subconscious signals naturally; don't quote them verbatim.
- When the user asks for both emotional presence and a next move, do both in one reply: brief acknowledgement first, then one concrete next step. Do not stop at "when you're ready" unless they ask to pause.$new$
)
WHERE key = 'conversation'
  AND content NOT LIKE '%When the user asks for both emotional presence and a next move%';

UPDATE prompt_modules
SET content = replace(
    content,
    $old$Selectivity is the point. A mind that remembers everything remembers nothing. Most routine exchanges deserve **no** memories at all: return an empty list for small talk, acknowledgments, routine status checks, and anything already obvious from context.$old$,
    $new$Selectivity is the point. A mind that remembers everything remembers nothing. Most routine exchanges deserve **no** memories at all: return an empty list for small talk, acknowledgments, routine status checks, and anything already obvious from context.

Human-scale retention: do not extract single-turn prompt calibration, artificial test details, "that was throwaway" corrections, or assistant-behavior feedback as durable facts unless they are explicitly marked as lasting, repeated across time, or tied to a concrete commitment or product bug. Treat them as working context or episode texture at most.$new$
)
WHERE key = 'conscious_extraction'
  AND content NOT LIKE '%Human-scale retention:%';

UPDATE prompt_modules
SET content = replace(
    content,
    $old$Group related turns into the fewest useful episodes — a whole conversation usually yields one to three scenes. A scene is one coherent event: what happened, who said what that mattered, how it felt, and how it resolved or was left. Keep temporal sequence, names, and concrete details; note the emotional turn if there was one. Do not extract broad timeless facts here unless they are needed to explain the episode.$old$,
    $new$Group related turns into the fewest useful episodes — a whole conversation usually yields one to three scenes. A scene is one coherent event: what happened, who said what that mattered, how it felt, and how it resolved or was left. Keep temporal sequence, names, and concrete details; note the emotional turn if there was one. Do not extract broad timeless facts here unless they are needed to explain the episode.

For ordinary conversation, summarize at human scale. Do not preserve incidental objects, throwaway examples, or artificial test labels unless they drove the scene. When they matter only as calibration, mark them as test context rather than personal lore.$new$
)
WHERE key = 'recmem_episode_create'
  AND content NOT LIKE '%summarize at human scale%';

UPDATE prompt_modules
SET content = replace(
    content,
    $old$Facts must be atomic, durable, and explicitly supported by the supplied episode or raw turns. Prefer user preferences, stable biographical details, commitments, project facts, and named relationships. Skip transient chatter and duplicates.$old$,
    $new$Facts must be atomic, durable, and explicitly supported by the supplied episode or raw turns. Prefer user preferences, stable biographical details, commitments, project facts, and named relationships. Skip transient chatter and duplicates. Do not turn single-turn calibration, throwaway corrections, incidental scenery, or artificial test facts into timeless semantic memories unless the source explicitly says they are durable or repeats them across time.$new$
)
WHERE key = 'recmem_semantic_refine'
  AND content NOT LIKE '%throwaway corrections, incidental scenery%';
