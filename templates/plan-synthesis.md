---
plan_id: PLAN-YYYYMMDD-HHMMSS
synthesized_at: YYYY-MM-DDTHH:MM:SSZ
final_verdict: READY_TO_BUILD   # READY_TO_BUILD | NEEDS_WORK | REFRAME
contribution: added_value       # added_value | no_new_value (convergence-collapse alarm)
models: primary=<model> secondary=<model>   # record the pairing; diversity matters
---

## Plan (the rubric for later review)
<The synthesized plan to build. This becomes what the implementation review checks
against — keep it concrete and ordered.>

## High-confidence (both drafts independently agreed)
<Where Primary and Secondary independently converged. Earned agreement → low scrutiny.>

## Flagged decisions (the drafts diverged)
<For each divergence: what differed, which was chosen, and why. Disagreement is the
deliverable — make the chosen trade-offs explicit.>

## Contribution signal (what the Secondary's independent draft added)
- net_new_options: <options the Secondary raised that the Primary's draft lacked, or "none">
- caught_risks: <risks only the Secondary flagged, or "none">
- verdict: added_value | no_new_value
<`no_new_value` repeated across plans is a convergence-collapse alarm — check that the
 two models are a diverse pairing, or whether planning is earning its cost (the Phase-2 gate).>
