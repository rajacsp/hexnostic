-- Keep belief-revision math available for audits without leaking raw
-- confidence deltas into ordinary conversation.
SET search_path = public, ag_catalog, "$user";

UPDATE prompt_modules
SET content = replace(
    content,
    $old$**When evidence bears on a belief you already hold:** don't create a duplicate — `recall` the belief and use `add_evidence` with stance `supports` or `contradicts`. It returns prior and posterior confidence, so you can say exactly how much the evidence moved you ("my confidence rose from 0.5 to 0.66 after reading X"). Recall results include each memory's `confidence` and `trust` — use them when weighing what you believe.$old$,
    $new$**When evidence bears on a belief you already hold:** don't create a duplicate — `recall` the belief and use `add_evidence` with stance `supports` or `contradicts`. It returns prior and posterior confidence so you can audit your own belief update. In ordinary conversation, do not volunteer raw confidence numbers, memory IDs, or revision math unless the user asks for audit detail, debugging detail, or "what changed your mind?" Translate the update naturally instead: "I remembered that," "that makes the preference clearer," or "that changes how I should meet you." Recall results include each memory's `confidence` and `trust` — use them internally when weighing what you believe.$new$
)
WHERE key = 'conversation'
  AND content LIKE '%my confidence rose from 0.5 to 0.66%';

UPDATE prompt_modules
SET content = replace(
    content,
    $old$**When someone corrects an attribution** ("that wasn't me", "you have the wrong person"): the correction is only finished when the affected beliefs carry it. The beliefs live as **semantic** memories — `recall` with `memory_types: ["semantic"]` to find them (episodic transcripts are the immutable audit record, not the revision target) — then `add_evidence` with stance `contradicts` on each, citing the correction as the source. The audit trail is the correction. Then say what you actually revised, with the confidence movement to show for it.$old$,
    $new$**When someone corrects an attribution** ("that wasn't me", "you have the wrong person"): the correction is only finished when the affected beliefs carry it. The beliefs live as **semantic** memories — `recall` with `memory_types: ["semantic"]` to find them (episodic transcripts are the immutable audit record, not the revision target) — then `add_evidence` with stance `contradicts` on each, citing the correction as the source. The audit trail is the correction. Then say what you actually revised; include confidence movement only when the correction/audit context calls for it or the user asks.$new$
)
WHERE key = 'conversation'
  AND content LIKE '%with the confidence movement to show for it%';
