# ADAPTIVE_COLLABORATION — Design Direction

**Status:** design direction, not yet implemented. `PROTOCOL.md` remains the
authoritative contract for how the system behaves *today* (post-hoc peer review).
This document records what we are evolving the framework toward, why, and in what
order — so the rationale survives between sessions and guides the build.

_Last updated: 2026-05-29._

---

## North star

The system should **feel like a smooth collaboration between the agents, work well
on its own, and not require the human to babysit it.** During a mature run the
human is largely absent; they review outcomes, not steps.

## The core principle

You don't reach "no babysitting" by trusting a smarter Primary. You reach it by
making **the two agents check each other well enough that the human doesn't have
to.** The Secondary catching the Primary's blind spots is exactly the function a
babysitting human performs today. So *smooth agent collaboration* and *no human
babysitting* are not two goals — the first is the **mechanism** for the second.

This has a sharp consequence: the collaboration has to be **real**. If the second
model just agrees with the first, we've removed the human *and* the backstop at the
same time. Defending against that (anti-anchoring, surfacing disagreement) is
therefore a safety requirement, not a nicety.

The human's role shifts from **operator → exception handler**: pulled in only when
the agents *together* can't resolve something. The existing `human_required`
handoff and bounded counters already implement this; the work is tuning the
threshold so the handoff is **rare but honest**.

---

## Two axes — and why we move along them separately

The evolution lives on **two independent axes** that earlier thinking bundled
together. Keeping them separate is the central strategic decision of this design.

1. **Capability** — *which stages* the agents collaborate on:
   `review → +planning → +hard-unit coding`.
2. **Autonomy** — *how much the human is in the loop*:
   `human-triggered → adaptive self-triggering → silent`.

**The strategy: advance capability first; hold autonomy at "human-triggered";
then advance autonomy separately, gated on evidence.** This decoupling is what
turns an ambitious-but-fragile single design into a staged one where the
high-confidence value ships first and carries none of the speculative risk.

Why it matters: the genuinely valuable, high-confidence part (collaborative
planning + the plan-as-rubric effect) sits on the *capability* axis. The risky,
low-confidence part (reliably detecting one's own ambiguity, then acting without
asking) sits on the *autonomy* axis. Bundling them made the sure thing depend on
the speculative thing. Separating them removes that dependency.

---

## The gap today

The framework does one shape of work: Primary produces an artifact → Secondary
judges it → bounded convergence → archive. That is *convergent, post-hoc,
asymmetric* — well-suited to review, but it means:

- There is **no pre-implementation phase**. The state machine goes
  `idle → request_pending`, which already assumes the work is done.
- **Planning happens solo, in the Primary's head**, before the Secondary ever sees
  anything. That is the categorical gap this design closes.

---

## The roadmap (phased and evidence-gated)

Each phase is independently shippable and valuable. Each later phase is **gated on
evidence from the one before it** — you may stop at any phase. Build discipline:
*do not build a phase until the prior phase's data justifies it.* The architecture
can't enforce this; it's a behavioral commitment, and skipping it forfeits the
entire benefit of phasing.

### Phase 1 — Collaborative planning, human-triggered

A small delta on the current system. Reuses the existing request / response /
counter / archive machinery.

**Adds:**
- A `planning` phase in the state machine: `idle → planning → implementation → review`.
- A `plan` request type whose scope is a **problem statement + context**, not a
  file list (needs its own template variant).
- A planning **verdict vocabulary** (e.g. `READY_TO_BUILD / NEEDS_WORK / REFRAME`)
  — `APPROVED/BLOCKED` does not fit a plan.
- A `plans/` artifact location. The committed plan **becomes the rubric the later
  review checks against** — upstream collaboration improves downstream review.
- The **blind-draft / commit-reveal** mechanic (see Mechanisms).
- The **contribution signal** baked into synthesis (see Mechanisms) — the gate to
  Phase 2.

**Deliberately does NOT carry** (this is the point of the phase): no
ambiguity-detection, no adaptive self-triggering, no narration, no heartbeat.
Planning fires the way review fires *today* — on existing structural checkpoints,
or because the human says "plan this one collaboratively."

**Cost profile:** this phase is **not** a J-curve. It's straightforwardly valuable
under normal oversight — arguably *less* total oversight, because the plan is now
vetted. (The "more babysitting before less" J-curve is a Phase 2/3 phenomenon,
quarantined out of here.)

**Gate to Phase 2:** the contribution signal must show the Secondary's independent
drafts are *regularly adding something* (net-new options, caught risks). If they
add nothing, that's convergence collapse — fix model pairing or stop; do **not**
proceed to adaptive triggering.

### Phase 2 — Adaptive triggering

Only once Phase 1 data shows planning collaboration pays. Moves *one notch* along
the autonomy axis: the Primary may now *decide for itself* when to open a planning
or review round — but still surfaces what it's doing.

**Adds:**
- **Judgment triggers** (ambiguity, novelty, multiple viable approaches with high
  reversal cost) on top of the existing **structural triggers** (security/secrets
  paths, wide blast radius, pre-commit, climbing `retry_count`, underspecified
  task). Much of this is *promoting existing review checkpoints to also fire
  planning.*
- **Trigger-decision logging — including the "no"s** (audit trail + the on-ramp to
  trust).
- A **bias toward over-triggering** at first (asymmetric costs: a needless
  collaboration wastes tokens; a missed one ships a bad plan), tuned down as logs
  show it crying wolf.
- A **milestone heartbeat** — a low-frequency second look regardless of felt
  confidence, as a backstop for unknown-unknowns no trigger fired on.

**Why this is the risky phase:** felt-uncertainty judgments are what LLMs are worst
at (systematic overconfidence → the default failure is *under-triggering*, which is
the original problem under a nicer name). But here it's added to a *proven*
capability with a *real outcome signal* to tell you whether triggering is
calibrated. This is also where the J-curve lives — you babysit the trigger logs
heavily at first precisely so you can stop later.

**Gate to Phase 3:** trigger logs show good calibration — it pulls in the Secondary
when it should and skips when it shouldn't — sustained over real work.

### Phase 3 — Autonomy ("no babysitting")

Only once triggering is calibrated. Moves to the far end of the autonomy axis: turn
**narration down**, push the human to exception-handler. This is the north star,
now *earned* rather than assumed (see Narrated autonomy + graduated trust).

### Optional / later — Collaborative coding

Not a separate machine. Either a *tighter review cadence* (a dial on existing
review) or *blind-draft on a rare hard unit* (the Phase 1 pattern at code-unit
grain). Add only if planning data shows value left on the table. Explicitly **not**
real-time pairing or split-and-parallelize (see Collaborative coding).

---

## Mechanisms (reference)

### Blind drafts → reveal → synthesize (Phase 1)

The value of two *different models* is diversity of thought; the enemy is
**anchoring** — once the Secondary sees the Primary's plan it reacts to that framing
and (especially with similar models) collapses into agreement. So:

1. **Primary opens a planning round** with a request containing *only the problem* —
   goal, constraints, context, what's been tried. **Not** the Primary's own plan.
2. **Both models draft independently and blind.** The Secondary's response *is* its
   plan draft. The Primary writes its own draft at the same time, sealed.
   - *Commit-reveal:* the Primary commits its draft to a sealed path the request
     doesn't reference, **before** reading the Secondary's response. Timestamps make
     "blind" verifiable rather than trust-based.
3. **Reveal + synthesize.** The Primary identifies where the two independently
   agreed, where they diverged, and why.
4. **Output: a plan with confidence-tagged sections.** Independent agreement → high
   confidence, low scrutiny. Divergence → a flagged decision ("Primary chose X over
   Secondary's Z because Y"). **Disagreement is the deliverable**; agreement must be
   *earned*, never the default.

**Model pairing matters.** Two instances of the same model is theater. The value
comes from pairing *complementary* families; record which model played which role.

Optional later depth: one *reaction* round (each critiques the other's draft before
synthesis); an *N-model* planning panel. Both bounded; neither needed for v1.

### The contribution signal (Phase 1 deliverable; the Phase 2 gate)

The synthesis step records one cheap thing: **what did the Secondary's independent
draft actually contribute?** — net-new options, caught risks, or nothing. This does
double duty:

- **Convergence-collapse alarm.** If the Secondary's draft never adds anything, the
  collaboration is theater — the models aren't diverse enough, or planning isn't
  earning its cost.
- **The gate.** It is the evidence that decides whether advancing to adaptive
  triggering is even worth it. Without a signal on plan *quality* (not just trigger
  *frequency*), the graduated-trust loop can't be closed honestly.

### Adaptive triggering (Phase 2)

Do **not** rely on felt uncertainty alone — combine structural triggers (fire on
facts, catch confident-wrong cases) with judgment triggers, evaluated against a
small named checklist at each meaningful checkpoint. Which round a trigger opens:
ambiguity/novelty → **planning**; risk/blast-radius → **review**; stuck →
**escalation**. Disciplines: log every decision, bias toward over-triggering early,
heartbeat as backstop. (Detail in the Phase 2 roadmap entry.)

### Narrated autonomy + graduated trust (Phase 3)

"Runs itself" and "I like being pulled in" reconcile via **narrated autonomy**: the
Primary collaborates without asking permission each time (no nagging) but
*announces* each trigger; the human keeps situational awareness and can veto. The
heartbeat doubles as a visibility signal on quiet stretches.

**"Just works without babysitting" is earned, not configured** — the output of a
tuning loop: run narrated → read the trigger + contribution logs → tune → turn
narration down as the track record proves out. The logs are the **on-ramp to
trust**, not bureaucracy. Jumping straight to silent-and-trusted either over-trusts
(gets burned → back to babysitting) or under-trusts (never stops watching).

### The Secondary's authority (cross-cutting)

**Advisory everywhere; disagreements surfaced loudly; the single owner (Primary)
decides.** This preserves no-deadlock and no-loop guarantees — there is always one
decider when the models disagree. The value is in *surfacing divergence*, not in a
veto.

### Collaborative coding (scoped deliberately small)

**Not** real-time pairing (the protocol is checkpoint-based file handoffs, not
streaming; the Secondary can't edit files) and **not** split-and-parallelize
(breaks the "only Primary edits" invariant; needs worktrees + merge handling). The
coherent versions reuse what we have: a *tighter review cadence*, or *blind-draft on
a rare hard unit*.

---

## Design constraints that protect the phasing

- **Build the "when do we plan?" decision as an explicit seam in Phase 1**, even
  though it initially just means "human says so / structural checkpoint." Phase 2
  swaps adaptive logic in at that seam without restructuring. Cheap now, expensive
  to retrofit.
- **Gate honestly.** The temptation is to build all phases at once; doing so undoes
  the risk-quarantine that is the entire point.

---

## Safety invariants — all preserved

Adaptive behavior changes only *when* a round opens, not *who controls the loop*.
Everything in `PROTOCOL.md §10` survives:

- Primary still **initiates** every round, **owns the counters**, **bounds the
  loops**, and **decides**.
- Secondary still **never starts a loop** — its plan draft is structurally a
  *response* to a Primary-initiated request.
- Rounds remain **bounded** (reuse a `review_cycles`-style counter for planning).
- The **single-active-request** invariant holds.

Already solved by the existing design and relied on here: infinite-loop / ping-pong
(bounded counters), deadlock (single-owner decider), crash recovery (atomic writes
+ reconciliation + watcher).

---

## Risks we are explicitly defending against

Most autonomy-killing failure modes are already handled (above). The phasing
quarantines the rest:

1. **Convergence collapse (collaboration theater)** — agents agree too easily,
   quality silently drops, no human notices. Defense: blind drafts, complementary
   models, and the **contribution signal** as an explicit alarm. The most insidious
   risk because it fails quietly and looks like success.
2. **Mis-triggering** — wrong cadence (too chatty = un-smooth + costly; too quiet =
   barrels ahead wrong). Quarantined to Phase 2 and defended by logging,
   over-trigger bias, and the heartbeat. The genuinely *new* value (catching
   *unrecognized* ambiguity) is the part most likely to underperform — which is why
   it is gated behind Phase 1 evidence rather than assumed.

---

## Open decisions (to settle within their phase)

- **Planning verdict vocabulary** (Phase 1) — confirm terms (`READY_TO_BUILD /
  NEEDS_WORK / REFRAME` or similar).
- **Planning request/response contract** (Phase 1) — problem-statement scope needs
  its own template variant.
- **Contribution signal format** (Phase 1) — how synthesis records what the
  Secondary added, concretely enough to audit.
- **Milestone heartbeat** (Phase 2) — confirm it earns its cost, or trust the
  trigger list.
- **Hard gate on expensive triggers** (Phase 3) — does a *full escalation* still
  ping the human even when planning is autonomous?

---

## One-line summary

Today: a post-hoc reviewer the Primary calls at fixed points. The direction: a
proactive collaborator — **planning first (sure win, ships now), adaptivity and
autonomy later (gated on evidence, optional)** — that shifts the human from operator
to exception handler without touching any loop-safety guarantee.
