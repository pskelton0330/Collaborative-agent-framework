# Subsystem Usage Review — 2026-07

A data-driven look at two subsystems that the shared/ records show are effectively
unused, with a recommendation for each. **These are decisions for the maintainer to
make** — nothing here is auto-applied. Evidence is from the live `shared/` archive on
the development machine (≈140 review exchanges, 2026-05 → 2026-07).

> Method: counted requests/responses across `shared/archive/` + open dirs; approval
> verdicts from `approval:` front-matter; escalations from `*.escalation.md`; plans from
> `shared/plans/`. See the numbers inline.

---

## 1. Escalation — **0 / 140 uses**

**Evidence.** In ~140 review exchanges, `shared/escalation/` contains only `.gitkeep`.
No escalation was ever created, despite threads reaching `review_cycle` 6 (past the soft
ceiling) and a 50% `BLOCKED` rate (70/140). The entire subsystem — the `escalated`
state, `max_escalation_cycles`, the escalation template, `new-request --type escalation`,
and PROTOCOL §9 — has never fired in real use.

**Why it's unused (most likely).** Two compounding reasons:
1. **The human is usually in the loop.** Escalation's job — "the review loop is stuck,
   get a deeper/alternative opinion before giving up" — competes directly with "ask the
   operator," and when the operator is present (the normal mode today) human-handoff
   wins every time. *This very review session is an example:* when increment 1 hit the
   review-cycle ceiling at cycle 4, the Primary surfaced the scope decision to the human
   rather than escalating to a deeper Secondary pass.
2. **The lightweight re-audit loop already absorbs the load.** Threads either converge
   within review cycles or the Primary accepts `APPROVED_WITH_CONCERNS`. The heavier
   escalation path rarely adds anything the next re-audit wouldn't.

**Options.**
- **(A) Keep as-is.** ~Zero carrying cost; documents intent; a safety valve for the case
  the operator isn't watching.
- **(B) Keep + instrument.** Make the Primary *actually* hit the escalation trigger at
  the §9 conditions and **log the decision either way** (including the "no"s), to gather
  evidence on whether it helps — the same trick the planning `contribution signal` uses.
- **(C) Remove it.** Simplify the state machine so a ceiling-without-approval goes
  straight to `human_required`. Smaller surface area, but loses the "bounded deeper
  review before giving up" story that matters for autonomous operation.

**Recommendation: (A), reframed — keep, but scope it explicitly to _unattended/
autonomous_ operation.** The 0/140 is not a bug; it's the correct behavior *when a human
is present*. Escalation earns its keep only in the roadmap's Phase 3 (autonomy), where
there is no operator to hand off to. Add one sentence to PROTOCOL §9 / README saying so,
so the zero-usage reads as "not yet in the regime where this matters," not "dead code."
Do **not** invest in (B) until autonomous runs are a real workload. Do **not** remove
(C) — it's cheap and it's load-bearing for the autonomy story.

---

## 2. Collaborative planning — **1 / 140 uses**

**Evidence.** `shared/plans/archive/` contains exactly one plan — `PLAN-20260611-133411`,
dated the day the subsystem was built (2026-06-11) — and nothing since. The
`scripts/plan` CLI, the blind-draft/commit-reveal mechanic, and the **contribution
signal** (designed as the evidence-gate for advancing the ADAPTIVE roadmap to Phase 2)
have a real-world sample size of **one**.

**Why it's unused.** Planning is human-triggered and front-loads cost (two blind drafts +
a synthesis) before any code exists. The path of least resistance is to start
implementing and lean on review — which is what happens. Planning's value shows up only
on wide-blast-radius or genuinely-ambiguous-design tasks, and the Primary doesn't
proactively reach for it on those.

**The consequence.** The ADAPTIVE_COLLABORATION roadmap is explicitly *evidence-gated*:
Phase 2 (adaptive triggering) is not supposed to start until the contribution signal
shows the Secondary's independent drafts regularly add value. With n=1, that gate can
never open. **The roadmap is frozen by non-use, not by a negative result.**

**A concrete data point in favor of planning.** Increment 1 of *this* task took 4 review
cycles largely because the initial *design* was wrong — "a response exists" was treated
as "the exchange is resolved," which ignored non-final responses and live-thread members.
A blind-draft planning round on the one-line question *"what does 'resolved' mean here?"*
might well have surfaced that before implementation, collapsing two of the four review
cycles. That is exactly the design-ambiguity case planning is for.

**Options.**
- **(A) Shelve formally.** Mark it dormant/experimental in the docs; stop
  ADAPTIVE_COLLABORATION from implying an *active* gate. Keeps the code (it's a parallel
  subsystem, doesn't destabilize review), just stops the roadmap from reading as
  in-progress.
- **(B) Commit to using it.** Deliberately run `plan` on the next 3–5 qualifying tasks
  (wide blast radius / multiple viable approaches / ambiguous spec) to generate real
  contribution-signal data, then decide on Phase 2 honestly.
- **(C) Remove it.** Recover the surface area. But the design is sound and the sunk cost
  is already paid, so this mainly buys a smaller repo.

**Recommendation: (B) if you still want the roadmap to move; otherwise (A).** Don't
remove it — it's well-built and isolated. The real question is whether *adaptive
collaboration* is still a goal. If yes, the only way forward is to feed the contribution
signal with real runs (start with design-ambiguous tasks like the one above). If it's not
a near-term goal, formally shelve it so the docs stop over-promising — either is honest;
leaving it in limbo is the only wrong answer.

---

## Summary

| Subsystem | Uses | Root cause | Recommendation |
|---|---|---|---|
| Escalation | 0 / 140 | Human-in-the-loop makes handoff dominate; re-audit absorbs the rest | **Keep**, reframe docs as "for autonomous mode"; don't invest yet |
| Planning | 1 / 140 | Front-loaded cost; not proactively triggered → roadmap gate starved | **Use it** on 3–5 design-ambiguous tasks to unfreeze the roadmap, **or** formally shelve. Don't leave in limbo |

Neither should be **deleted** — both are cheap-to-keep and design-sound. The finding is
about *documentation honesty and where to invest*, not dead code to rip out.
