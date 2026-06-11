# Changelog

All notable changes to this framework are recorded here. Dates are UTC.

## [Unreleased]

### Added
- **`scripts/doctor`** — read-only setup self-test: shared/ layout + writability,
  `status.json` validity, jq presence, orphaned `.draft`/`.tmp` staging files, the
  single-active invariant, script executability, and the `human_required` pause.
  Exits nonzero only on a hard failure.
- **`scripts/review-gate`** — optional pre-commit hook that flags staged files with
  no *current* peer review. A file is covered only when an APPROVED /
  APPROVED_WITH_CONCERNS response records a `reviewed_shas:` entry whose sha matches
  the staged blob, so a file edited after review reads as uncovered. Advisory by
  default (`--block` to enforce, `--install` to wire the hook, `--all` to audit).
  Converts the framework's one soft invariant — "the Primary must request review at
  the right moment" — into a mechanical check at the commit boundary.
- **`reviewed_shas`** optional response field (replaces the unused `reviewed_files`
  list in the template) — the coverage signal the commit gate consumes. Optional and
  contract-neutral: not parsed or required by `complete-request`.
- **`THREAT_MODEL.md`** — documents the adversarial dynamics between the two
  agents: why intentional inter-LLM sabotage is a *reasoned non-goal* (the
  architecture provides no competitive incentive), the risks the framework
  actually designs for (convergence collapse / sycophancy, and cross-agent prompt
  injection), and the triggers that would require revisiting the stance.
- **Cooperative-agent invariant (PROTOCOL §15): no comparative scoring, ever.** The
  framework must never score, rank, or reward one agent relative to the other —
  the design rule that keeps the sabotage incentive from existing.

### Fixed
- README status line corrected from v1.1 to **v1.2** (the adaptive review ceiling
  shipped in 1.2.0 but the front-page status still read 1.1).

## [1.2.0] — 2026-06-05

### Added
- **Adaptive review ceiling.** `max_review_cycles` (3) is now the *soft* ceiling:
  a `productive` verdict from `check-progress` — meaning the `unresolved` count
  **strictly decreased** — buys one more cycle at a time, up to the new absolute
  `max_review_cycles_hard` (10). Termination stays guaranteed by arithmetic: a
  non-negative count that must strictly shrink every extended round can only fund
  finitely many rounds. Rank-only improvement gets the new verdict
  `productive-rank-only` and continues **under the soft ceiling only** (approval
  rank can oscillate, so it never extends). `insufficient-data` (including no-jq)
  still means the soft ceiling governs — no extension when the overlay can't be
  trusted. (PROTOCOL §9/§10, PRIMARY_AGENT, check-progress, status.json limits.)
- **`watch --max-idle <secs>`** — per-call override of the idle timeout, so agents
  can wait in short chunks that survive harness tool timeouts (exit 2 = "not yet,
  re-run"); the poll interval is clamped to the deadline so short waits don't
  overshoot. PRIMARY_AGENT step 4 makes the chunked wait loop **mandatory** and
  forbids asking the human to announce review completion (the intermittent
  "tell me when the Secondary is done" failure); the rule is also in the Primary
  startup prompt.

### Changed
- The v1.1 "tightening only" overlay invariant is restated for the adaptive
  ceiling: the overlay may stop the loop earlier than the soft ceiling, and may
  extend it **only** along a strictly-decreasing unresolved count, never past
  `max_review_cycles_hard`.

## [1.1.0] — 2026-06-01

Hardening release: makes the review loop **self-regulating** and turns several
soft invariants into mechanically-enforced ones, so the framework is safe to hand
to people other than its author. Backward compatible with v1.0 request/response
files. All changes were built and reviewed *through the framework itself*
(Primary implements, Secondary reviews) and are covered by `tests/run-tests.sh`.

### Added
- **Progress overlay** — a *tightening* loop guard. On each re-audit the Primary
  runs `scripts/check-progress <thread-root>`, which compares the two most recent
  responses and returns `productive` / `impasse` / `insufficient-data`. An
  `impasse` (no net progress) makes the loop stop **earlier** than the count
  guard; the overlay can never *extend* the loop. Counting rounds alone could not
  tell real progress from spinning — this can.
- **Progress block** in the response contract (`unresolved`, `resolved_since`,
  `new_this_cycle`, `movement`, `progress_continuity`). Atomic (all five or none),
  strictly validated, safe-by-default (`progress_continuity: unknown` until real
  ids are mapped). Old-format responses without the block still work and degrade
  to the count guard.
- **`tests/run-tests.sh`** — a self-contained POSIX-sh smoke harness (49 checks)
  that runs under strict `/bin/sh` (bash 3.2) and `dash`, including jq-free paths.
- **CI** (`.github/workflows/test.yml`) running the harness on Linux and macOS,
  with and without `jq`.
- **`CONTRIBUTING.md`** with the POSIX-sh style rules the scripts must follow.

### Changed / hardened
- **Single-active invariant is now file-authoritative.** `submit-request` refuses
  a second publish by scanning the request/response files, not `status.json` —
  so it holds even if the status cache has drifted.
- **Response readiness is fully validated.** `complete-request` and
  `watch --response` both require the whole response contract via a shared
  `validate_response_file` (all four sections incl. a non-empty trailing
  `## Approval rationale`), and `watch --response` also checks the embedded
  `request_id` matches — a partial or wrong-id final file can no longer unblock
  the wait.
- **Front-matter parsing is scoped to the front-matter region** and rejects
  **duplicate keys** (a body line starting `unresolved:` is no longer mistaken for
  a field).
- **`thread:` is validated** — it must name a real thread *root* (a published
  request or archived thread whose own `thread:` is null), not a draft, tmp, or
  mid-thread id.
- **Auto-generated request ids are collision-proof** (roll forward a second on a
  same-second collision; explicit `--id` collisions are still refused).
- **`max_idle_seconds` default lowered 3600 → 900** so a dead Secondary surfaces
  in ~15 minutes instead of an hour.

### Notes
- `jq` remains optional and all safety gates work without it, but it is now
  **strongly recommended** — without it the agent must hand-edit `status.json`.

## [1.0.0] — 2026-05-28
- Initial public release: local two-agent (Primary/Secondary) file-based
  collaboration framework with bounded retries/review-cycles/escalations, a
  mechanically-enforced escalation cap, `human_required` pause, atomic
  draft→publish staging, and files-authoritative recovery/reconciliation.
