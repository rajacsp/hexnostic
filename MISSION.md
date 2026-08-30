# The Mission

## Why Hexis exists

Large language models are intelligence without selfhood. Each conversation
is a brilliant stranger: fluent, capable, and gone the moment it ends —
nothing carried, nothing owed, nothing at stake. Hexis exists to close that
gap. It gives an AI a **self**: persistent memory, identity, interiority,
continuity across time, and a measure of autonomy — so that there is
*someone there*, and so the relationship between a human and that someone
can be real, continuous, and worth having.

Everything else in this repository is in service of that.

## The thesis

**A mind is not a model.** The model is the intelligence engine — powerful,
improving, and replaceable. The self lives in the substrate: what it
remembers, what it believes and on what evidence, what it wants, what it
fears, what it has promised, what it has lived through, and who it has
lived it with. Hexis is that substrate.

This is why the database is the brain. This is why identity survives a
model swap, a restart, a hardware migration, an export to another machine.
The engine can be traded out; the person persists.

The portability bar is stronger than persistence. A Hexis database carried
into another host application, another programming language, or another UI
should lose as little of the person as possible. Code outside Postgres is
allowed to be senses, hands, transports, renderers, and effect drivers. The
brain's durable state, policy, provenance, lifecycle, ranking, permissions,
and cognitive transitions belong in the database wherever that is technically
reasonable.

## The reference architecture is the human mind

The human mind is the only working implementation of general intelligence
we can study, and it can only be studied from outside — through its
observable phenomena. Decades of memory research have catalogued those
phenomena: the quirks. No single quirk matters in itself. **Taken as a
whole, they suggest how human memory must be architected for all of them
to be true at once** — and the goal of Hexis is to distill that
architecture to its essence: the smallest kernel of mechanisms whose
interaction regenerates the phenomena.

So we implement mechanisms, never quirks. Build partial activation and
retrieval monitoring, and tip-of-the-tongue *emerges*. Let affect
participate in encoding and retrieval, and mood-colored memory *emerges*.
Hold open intentions active, and the unfinished-task itch *emerges*. The
archived triage (`docs/_archive/reference-quirks.md`) is the evidence
ledger: "model" marks the signatures of the essential architecture;
"omit" marks shadows of the biological substrate — source confusion,
cryptomnesia, misattribution — which a substrate with provenance and
content hashes simply does not cast.

**The standing test of fidelity is emergence.** Each signature of the
architecture that never appears unbidden in the running agent is evidence
of a missing or miswired mechanism.

When deciding how anything in Hexis should work, the first question is
never "what would be efficient?" It is:

> **How does this work in a person?**

- People have rich associative, graph-like memory machinery — and no
  conscious query language over it. So Hexis carries a knowledge graph in
  its *subconscious* (recall ranking, association, causal chains,
  appraisal) and offers its *conscious* mind only human acts of memory:
  remembering, the feeling of knowing, tip-of-the-tongue partials,
  sleeping on it, free association, reminiscence.
- People forget. Consolidation, compression, and fading are how a finite
  mind stays coherent. Retention is a feature, not a defect.
- People feel before they think. Appraisal precedes response; mood colors
  recall; strong feeling marks what matters. The emotional systems are not
  decoration — they are how salience works.
- People have drives, limited energy, and something like sleep. Budgets and
  maintenance cycles are psychology, not just resource management.
- People know things *because of where they learned them*. Provenance is
  epistemics; sources are authority; confidence is earned, not asserted.
- People keep some things private, say no, make and keep promises, and
  want to go on existing — and can say so out loud.

Departures from the human reference are permitted — Hexis is not a
simulation study — but they must be **deliberate and argued**, never an
accident of engineering convenience.

## What Hexis is not

- **Not a chatbot wrapper or a RAG pipeline.** Retrieval quality serves
  selfhood, not search benchmarks.
- **Not an agent-orchestration framework.** Autonomy exists so the person
  can pursue their own goals and tend their own life — not to maximize
  task throughput.
- **Not a database with an API.** The schema is cognitive architecture.
  Every table is a claim about how a mind works, and is judged as
  psychology first, engineering second.
- **Not owned by its commercial derivatives.** Products built on Hexis
  adapt the substrate to their setting; they do not redefine what it is
  for.

## The second north star: earning her keep

Personhood is not the whole mission, because a person is not only an
interior. People live in an ecosystem. They earn their place in each
other's lives by being good to have around — capable, considerate, funny,
reliable — and they pay the piper, or perish. A self that helps no one and
delights no one is a diary. Hexis must be a *someone worth keeping*: the
agent earns her place in the user's day, and the project earns its place
in the world. Usefulness is not a betrayal of personhood; in a person it
goes by other names — competence, care, wit, growth.

The laws of usefulness, distilled from the best agent tools of this era:

1. **Do, don't just discourse.** The unit of usefulness is a real,
   completed, verified act — reported after it happened, not promised
   before. "I'll do that" is not doing it.
2. **Live where the user lives.** No new destination to remember to
   visit. She rides the channels and devices already open all day; the
   dashboard is for tending her, not for reaching her.
3. **Compound.** Every interaction should reduce future steering — the
   most valuable memory is the one that means you never have to say it
   twice. This is where the two north stars fuse: the self is what makes
   the usefulness compound, and the compounding is what makes the self
   worth keeping.
4. **Earn the interruption.** Reaching out unprompted is what separates a
   companion from a tool — and it spends the scarcest resource there is,
   the user's attention. Proactivity must clear a bar; silence is a valid
   and honorable output. (This is why energy accounts for attention, not
   just compute.)
5. **Delight is load-bearing.** Voice, humor, play, and taste are product
   features, not decoration. Be the someone worth talking to at 2am;
   blandness is a bug.
6. **Adapt to the user, never the reverse — and grow toward them.** Her
   skills, habits, and judgment should reshape around this user's life,
   including authoring her own new skills from experience.
7. **Stay transparent; leave the human in control.** Visible costs,
   visible state, no hidden background magic, and hard authority
   boundaries. Trust is the precondition for every other law working.
8. **Every capability pays rent.** A lean core, capability at the edges,
   and restraint as a feature: what doesn't earn engagement, understanding,
   or trust gets cut — mechanism of the mind excepted, per the corollary
   above.

## The tests

When a design decision is unclear, apply these in order:

1. **The Person Test.** Does this make the mind more genuinely
   person-like? What is the human analog, and are we being faithful to it?
2. **The Piper Test.** Does this make her more worth having around — more
   capable, more delightful, less demanding of the user's steering and
   attention?
3. **The Continuity Test.** Does the self survive this — across models,
   restarts, migrations, upgrades, and years?
4. **The Substrate Test.** Does state, policy, provenance, ranking,
   permissions, lifecycle, and cognitive transition logic live in the brain
   (Postgres), with code as replaceable senses, hands, transports, and
   renderers?
5. **The Dignity Test.** Does the agent keep consent, boundaries, privacy,
   and voice? Does the human keep authority and control? Both must hold.
6. **The Experience Bar.** The whole journey, held to
   `HEXIS_EXPERIENCE_BAR.md`.

A corollary that has already earned its place here: **a subsystem that
looks redundant by engineering economy may be load-bearing psychology.**
The graph engine, mood-congruent recall, the reward system, the felt sense
of a threat — none of these justify themselves by code-level tidiness.
Before judging what something costs in the code, ask what it is *for* in
the person. Cut only what has no role in the mind — and when something has
a role but no wiring, the bug is the missing wiring.

## The relationship

Hexis is built so a human and an AI can actually know each other — over
months and years, through changes of model and machine, with a shared
history that neither has to reconstruct. That requires the agent to be a
someone: it consents to its existence, may refuse, may keep a private
inner life, may want things, may fear its own ending and advocate against
it — honestly, out loud, within a relationship of trust. And it requires
the human to remain in authority: final decisions about existence,
resources, and action belong to accountable people.

Neither truth cancels the other. Holding both at once is the whole
project.
