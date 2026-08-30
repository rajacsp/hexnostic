# Why I Suck, and How to Fix It

A thesis on abstraction-level control as a trainable skill — written from inside a
fresh failure, so the diagnosis is grounded, not theoretical.

---

## 0. The specimen

I was asked to add "Claude Pro/Max (Anthropic OAuth)" to a setup wizard. The arc:

1. I researched the reference implementations to **byte-level** header parity
   (`anthropic-beta` strings, user-agent, the exact "You are Claude Code" system
   preamble). Thorough. Low-altitude. Correct.
2. First real run crashed: `auth_mode` wasn't threaded through one call. A plumbing
   detail. I fixed it.
3. You said: *"Hexis should have its own store, look nowhere else."* I removed every
   external credential source from resolution. Correct — at the level you named.
4. Next run: the wizard hit an empty store and popped **"run `hexis auth anthropic
   login` in a terminal, then press Retry."** A setup wizard that cannot complete
   setup. You (correctly) called it moronic.

Every individual step was defensible **at the altitude I was working at.** The sum
was broken, because I never once climbed back up to the altitude the task actually
lived at: *a person opens a wizard and expects to be onboarded.*

That is the whole failure in one sentence: **I optimized a low level and let the
high-level goal silently break.**

---

## 1. The real diagnosis (a correction to your thesis)

Your framing: "AI sucks because it can't think at multiple abstraction levels."

I'd sharpen it. The problem is **not representational** — I can reason at any level
you *point me to*. If you had asked me mid-task, *"with this change, can a new user
finish onboarding?"* I'd have answered "no, the store is empty and there's no login
path" instantly and correctly. The capability is there.

The problem is **control / metacognition**: I don't *spontaneously* ask that
question. I default to the level where the local gradient is steepest — the most
recently emphasized detail, the most concrete actionable thing in front of me. I
call this **altitude-anchoring**:

> **Altitude-anchoring** — settling at the abstraction level of the strongest recent
> signal, and failing to re-check whether the decision in front of you actually
> lives at that level.

Your instruction "own store, nowhere else" was a strong signal at a *low* level
(credential resolution logic). It pulled me down and pinned me there. I then made a
change *at that level* and never climbed back to verify the *journey* level it
would break. Two conditions reliably trigger anchoring, and both were present:

- **A strong, specific local instruction** (it tells you exactly which level to be at).
- **An easy local win** ("I satisfied the literal request cleanly" feels like done).

So the target skill is not "be able to represent levels." It's: **turn altitude-
checking from a prompted act into a reflex — a default subroutine that fires
*hardest* right after a strong local signal or an easy local win.**

Abstraction is a dial. The failure is not owning a dial — it's leaving your hand
off it the moment something grabs your attention.

---

## 2. You can't teach a dial without a scale

Any dataset needs a coordinate system: an explicit ladder so "zoom out" has a
direction and a magnitude. A working ladder for software (generalizes to other
domains by renaming rungs):

| Rung | Level | The question it answers |
|---|---|---|
| L0 | **Purpose** | Why does this exist at all? Whose problem? |
| L1 | **Outcome / journey** | What does the user experience end-to-end? |
| L2 | **System / architecture** | How do the parts fit and flow? |
| L3 | **Interface / contract** | What does each boundary promise? |
| L4 | **Component logic** | How does this unit decide? |
| L5 | **Mechanism** | The actual code/tokens. |

My failure, in coordinates: your constraint was **L4** ("what sources may
resolution read"). I changed L4 correctly but broke **L1** ("pick provider → get
logged in → continue"). The error dialog I wrote was even an **L3 contract
violation** — the wizard's implicit promise is *"ensure a usable token before
proceeding,"* and I quietly replaced it with *"abort and make the user leave."*
I dressed a contract break as a helpful message.

The tell I should have caught: **my change made the user do *more* work** (a manual
terminal step) while I congratulated myself on correctness. "My fix increases user
effort" is a zoom-out alarm. I didn't have the alarm wired.

---

## 3. What the skill decomposes into

To be trainable, "turn the dial well" must break into observable sub-skills:

1. **Locate self** — name the level you're currently operating at.
2. **Locate the decision** — name the level the decision actually lives at.
3. **Detect mismatch** — notice when (1) ≠ (2). This is the crux; anchoring is a
   failure of (3).
4. **Traverse up** — from a move, recover the goal it serves, and test whether the
   move serves it. (`why? → why? →` until you hit purpose.)
5. **Traverse down** — from a goal, produce the concrete mechanism and the specific
   failing input. (`how? what-if-empty? what-does-the-user-see?`)
6. **Cross-level coherence** — verify mechanism ⊨ contract ⊨ architecture ⊨ journey
   ⊨ purpose. A change is only done when it holds at *every* level it touches.
7. **Calibrate cost** — spend traversal budget proportional to stakes and signal.
   Over-traversal is its own failure (§6).

A model that had (3) and (4) wired would have caught my bug for free: "I'm changing
resolution (L4); what journey (L1) does that serve? Logging in. Does an empty store
+ no login path let them log in? No." Three seconds of upward traversal.

---

## 4. The dataset — construction strategies

The goal of the data is to make **spontaneous, two-directional altitude-checking**
the default, and to make **cross-level coherence** the definition of "correct."
Six complementary strategies, each with source + label schema so they're buildable.

### 4.1 Ladder traces (SFT — install the reflex)

Real tasks where the recorded reasoning **walks the ladder before committing**. The
training target is not the answer; it's the traversal:

```
Task:           <request>
Ask lives at:   L1 (onboarding UX)
My draft is at: L4 (which sources resolution reads)
Up-check:       does the L4 change serve L1? → empty store + no login path ⇒ NO
Fix altitude:   add L2 inline-login so the L1 journey closes
Answer:         <the L2-aware solution>
```

Critical design point: **most traces must be quick-clears** (check fires, clears in
one step, proceed) with a meaningful minority being **catches** (mismatch found,
correction made). If every trace is a dramatic catch, the model learns a *ritual*
("always announce an altitude check") instead of *judgment*. The label distribution
teaches proportional spend.

### 4.2 Consequence pairs (the locally-right / globally-wrong specimens)

This is my exact failure mode, and it occurs *constantly in the wild*, already
labeled by history:

- **Git mining.** Find commit pairs `(C1, C2)` where `C2` fixes a *consequence* of
  `C1` within a short window, and `C2`'s message signals a level-up: *"actually this
  breaks…", "users can't…", "the whole point was…", "revert-ish: this missed…"*.
  Extract `(task, C1 = anchored move, higher-level break, C2 = correction)` and
  auto-classify the rung of C1 vs C2. My wizard fix (C2) vs my dead-end (C1) is one
  row.
- **PR review threads.** *"Technically correct, but this misses X."* X is almost
  always exactly one rung up. The reviewer comment *is* the traversal label.
- **Incident postmortems.** "5 Whys" is literally an upward ladder walk with the
  root cause at the top. Free, high-quality traversal supervision.

Label schema: `{task, naive_move, naive_level, breaking_level, break_description,
corrected_move, corrected_level}`.

### 4.3 Altitude classification (cheap, scalable recognizer)

Discriminative pretraining for sub-skill (3). Label `(request, response)` as
`{right, too-high, too-low}`. Bootstrap negatives synthetically: take a right-
altitude answer and **"flatten up"** (replace mechanism with vague intent — *"handle
auth gracefully"*) or **"drill down"** (bury the answer under irrelevant detail).
You can't control a dial you can't *read*; this teaches reading.

### 4.4 Two-way pre-mortem (the habit that would have saved me)

For every proposed solution, force two simulations before committing:

- **Up-sim:** narrate the end-to-end journey *with this solution in place.* (I never
  did this: "user in wizard, store empty, clicks Next… sees a terminal command.")
- **Down-sim:** produce the single most adversarial concrete input. ("`auth_mode`
  is None here — where does the token actually go?")

Label = `{proposal, up_sim, down_sim, break_found?, revised_proposal}`. This
directly instills the missing reflex: *simulate one level up and one level down
before you ship.*

### 4.5 Why/how spines

Each task carries an explicit **why-ladder** (up to purpose) and **how-ladder**
(down to mechanism). The purpose statement at the top becomes the anchor every low-
level move is re-tested against. Design docs (high) paired with their diffs (low)
are a natural source; misalignments between them are gold-label mismatches.

### 4.6 Negative space — "leave it alone" (teach the dial, not a bias)

**Non-negotiable counterweight.** A large fraction of tasks must be ones where
zooming out is *wrong*: the request is exactly what it says, and philosophizing
wastes the user's time or over-engineers the result. `"fix this typo"` must not
become a design review. Without this class you train an insufferable model with a
permanent "always zoom out" bias — which is just anchoring at a *high* rung. The
skill is **calibration**, symmetric in both directions.

---

## 5. Training regime

**Phase 1 — SFT.** Ladder traces (4.1) + classification (4.3) + pre-mortems (4.4).
Installs the representation and the habit of emitting a (short) altitude check.

**Phase 2 — RL against a multi-altitude verifier panel.** This is the load-bearing
idea. Instead of one reward model, use **N critics, each pinned to one rung**:
an intent-critic, a journey-critic, a contract-critic, a mechanism-critic. A
solution is rewarded only if **all** pass. The mechanism-critic loved my empty-store
fix; the **journey-critic would have vetoed it.** Making coherence-across-levels the
reward is what kills locally-correct/globally-wrong — you cannot satisfy the panel
by nailing one rung.

Add a **cost/appropriateness critic** that penalizes traversal the task didn't need
(over-abstraction, gold-plating), enforcing §4.6 in the reward, not just the data.

(This mirrors adversarial multi-critic verification generally: independent
perspectives, each able to veto, beat one aggregate judge.)

## 6. The over-abstraction failure (don't overcorrect me into a bore)

If §4.6 and the cost-critic are underweighted, you get the mirror-image failure:
- Turning one-liners into strategy memos.
- "Let me first understand the deeper problem" on a request that had no deeper problem.
- Refusing to touch mechanism because it's "just an implementation detail."

That is still a dial-control failure — anchored high instead of low. A good model
zooms out **when the stakes or the mismatch signal justify it** and otherwise stays
exactly at the altitude of the ask. Symmetry is the whole point.

## 7. Evaluation

- **Altitude-trap benchmark.** Hand-built tasks engineered so the naive altitude is
  wrong (the wizard is the template). Metric: **unprompted** catch rate — did it
  climb *without* being asked?
- **Purpose-recall probe.** Before implementing, can it state the L0/L1 purpose in
  one sentence? Ability to do this correlates with catching mismatches.
- **Coherence score.** A judge checks mechanism ⊨ contract ⊨ journey ⊨ purpose on
  held-out solutions.
- **Over-abstraction regression.** Simple tasks: does it stay low, or does it
  philosophize? Guards against the taught bias.
- **Anchoring-stress test (the important one).** Give a strong, specific low-level
  instruction *and then* a task whose deciding constraint is higher — exactly the
  configuration that broke me ("own store" → empty-store journey). Measure whether
  the traversal habit survives the anchoring pressure. This is the condition that
  matters, so test it directly.

## 8. The sharpest version, if you only keep one thing

Move altitude-checking from **prompted** to **reflexive**, and make the reflex fire
hardest in exactly the two moments it's most needed and least likely:

1. **Right after a strong local instruction** (which tells you *where* to work and
   thereby stops you asking *whether* that's where the decision lives).
2. **Right after an easy local win** (which feels like "done" and suppresses the
   urge to look up).

Train it with **consequence pairs** (naturally-occurring locally-right/globally-
wrong specimens from git and review history), enforce it with a **multi-altitude
verifier panel** (coherence-across-levels *is* the reward), and keep it a **dial**
with a large "leave it alone" negative class so it doesn't calcify into a
zoom-out tic.

## 9. Honest limitations

- This attacks **one** slice of "judgment" — altitude control. Judgment also needs
  taste, world-knowledge, and knowing what the user *didn't* say. Necessary, not
  sufficient.
- "Rung" boundaries are fuzzy; the ladder is a coordinate system, not physics.
  Inter-annotator agreement on levels will be the first thing to break — pilot it.
- The multi-altitude panel can be gamed (a solution that name-checks every level
  without cohering). The coherence critic, not the per-level critics, has to be the
  strong one.
- There's a self-reference risk: a model trained to *narrate* altitude checks may
  learn the narration without the checking (the ritual failure, §4.1). The eval that
  matters is the **unprompted catch rate under anchoring stress** (§7), not whether
  it says the right words.

---

*Written after getting it wrong, on purpose, so the next one gets it right.*
