# PLANNING — collaborative planning (Phase 1)

The implemented spec for the planning phase. `ADAPTIVE_COLLABORATION.md` is the
*direction*; this file is the *contract* for the planning flow that ships today.
`PROTOCOL.md` remains authoritative for the review flow.

Planning runs **before** implementation. Both agents draft a plan **independently
and blind**, then the Primary reveals both, synthesizes one plan, and records what
the Secondary's independent draft contributed. The synthesized plan becomes the
**rubric the later implementation review checks against**.

It is a **parallel subsystem** to review: it reuses the conventions (atomic
staging, files-authoritative state, append-only log, single owner) but its own
script (`scripts/plan`) and artifacts (`shared/plans/`), so it cannot destabilize
the review contract.

---

## When to use it

Human-triggered (Phase 1 deliberately adds **no** adaptive self-triggering): the
Primary opens a planning round when you ask, or at a structural checkpoint where a
plan is worth vetting before building (wide blast radius, multiple viable
approaches, an underspecified task). Solo work skips it entirely.

## Verdict vocabulary

`APPROVED/BLOCKED` does not fit a plan. Plan drafts and the synthesis use:

- **READY_TO_BUILD** — the plan is solid; proceed to implementation.
- **NEEDS_WORK** — the approach is right but has gaps to close first.
- **REFRAME** — the *problem statement itself* should be reframed before planning.

## Artifacts (`shared/plans/<plan-id>/`)

| File | Who writes | What |
|---|---|---|
| `problem.md` | Primary | the problem statement — goal/constraints/context, **no solution** |
| `primary-draft.md` | Primary | the Primary's blind plan draft (sealed before the Secondary drafts) |
| `.sealed` | `plan seal` | timestamp proving the Primary committed before revealing |
| `secondary-draft.md` | Secondary | the Secondary's **independent** plan draft (its "response") |
| `plan.md` | Primary | the synthesized plan: rubric + confidence tags + contribution signal |

Plan id: `PLAN-YYYYMMDD-HHMMSS`. Finished rounds move to `shared/plans/archive/<id>/`.

## Flow (commit-reveal)

```
plan new "<label>"     Primary  scaffold problem.md; state=planning
  (fill problem.md; write primary-draft.md from templates/plan-draft.md)
plan seal <id>         Primary  seal the blind draft — REFUSED if the Secondary
                                already drafted (blindness) or the draft is unfilled
  (Secondary reads problem.md ONLY; writes secondary-draft.md.tmp)
plan submit <id>       Secondary validate (verdict + sections) + publish; REFUSED
                                unless the Primary sealed first (commit-reveal order)
plan reveal <id>       Primary  verify the seal precedes the Secondary draft, then
                                surface both drafts
plan synthesize <id>   Primary  scaffold plan.md (confidence-tagged + contribution)
plan archive <id>      Primary  archive the round; state=idle; implement next
```

## The contribution signal (the Phase-2 gate)

`plan.md` records what the Secondary's independent draft added: `net_new_options`,
`caught_risks`, and a `contribution: added_value | no_new_value` verdict. Repeated
`no_new_value` is a **convergence-collapse alarm** — the two models aren't a diverse
pairing, or planning isn't earning its cost. This is the evidence that gates any
future move to adaptive triggering (Phase 2). Don't advance on frequency alone;
advance on plan *quality* added.

## Blindness — honest limits

The seal timestamp makes the *ordering* verifiable (the Primary committed its draft
before the Secondary's exists). It does **not** physically prevent the Secondary from
reading `primary-draft.md` on a shared filesystem — the protocol relies on the
Secondary reviewing `problem.md` only. Pair *different* model families to make the
independence meaningful; two instances of one model is theater (see
[`THREAT_MODEL.md`](THREAT_MODEL.md): convergence collapse).

## Safety invariants (unchanged)

The Primary initiates every round, owns the turn, and decides; the Secondary only
drafts in response to a published problem. Rounds are bounded (a planning round is a
single draft exchange, not a loop). `human_required` still pauses everything.
