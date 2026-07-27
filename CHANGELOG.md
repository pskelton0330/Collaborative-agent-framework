# Changelog

All notable changes to this framework are recorded here. Dates are UTC.

## [Unreleased]

### Changed
- **Headless review speed.** Two framework-induced costs made each codex review take
  5-7 min vs a bare codex query: (1) `secondary-agent` inherited the user's global
  `model_reasoning_effort` (often `ultra` = max depth); it now defaults to **`high`**
  (noticeably faster than ultra — a full review pipeline dropped from 485s to 50s at
  `medium` on the same task; `high` sits between — while keeping strong review depth),
  overridable via `SECONDARY_REASONING_EFFORT` / `--effort ultra|high|medium|low` (drop to
  `medium`/`low` for quick iteration, or `ultra` for a deliberate deep audit). (2) The
  reviewer prompt told the agent to read `PROTOCOL.md` (566 lines) + `SECONDARY_AGENT.md`
  every review — ~40K of internal docs not needed to review code; the prompt now tells it
  NOT to (the contract is inline). Working directory was ruled out (trivial codex call:
  3.6s in the 6.6M framework dir vs 3.7s empty). Also fixes the reviewer prompt to use
  `$SHARED` instead of a hardcoded `shared/`, so a review in an isolated `AF_STATE_DIR`
  reads/writes the correct paths.

### Fixed
- **`secondary-loop` accepted a review by file existence alone.** It now requires the final
  response to pass `validate_response_file` AND carry a matching `request_id` before
  logging it as complete — so an agent that writes a truncated, malformed, or wrong-id file
  directly (by accident or via prompt injection in reviewed material), bypassing
  `complete-request`, no longer falsely completes a review; such a file is discarded rather
  than left to masquerade as "processed" and block the request's retries.
- **A rotation failure could kill the watcher.** `maybe_rotate_conv` returns nonzero on
  failure and was called bare under `set -e`, so a non-regular `conversation.md.1` (or any
  `mv` failure) aborted the Secondary. Now called with `|| true` — the failure warns but
  reviews continue, as documented.

### Added
- **Concurrent multi-session support (`AF_STATE_DIR`).** Two Primaries sharing one
  `shared/` collide on the single-owner state machine (one `active_request`/owner). Set
  `AF_STATE_DIR` to give a session its OWN isolated coordination-state tree (bootstrapped
  automatically, seeded from the framework) so several `/collab` sessions run at once with
  zero cross-talk — the framework CODE stays shared, only live state is per-session. The
  `/collab` skill sets a unique `shared/runs/<id>/` per session automatically. Backstop: a
  **single-watcher lock** (`$AF_STATE_DIR/.watcher.pid`) makes a second persistent
  `secondary-loop` on the same state dir refuse (exit 5) instead of double-processing; a
  crashed watcher's lock is reclaimed on next start; `doctor` reports the lock (and flags a
  stale one) plus the active state dir. Default (unset) behavior is unchanged. 8 new tests
  (isolation, fresh-dir bootstrap, lock refusal, stale/live lock detection).
- **Archival-hygiene sweep + operational `doctor` warnings.** Long sessions left dozens
  of resolved reviews un-archived in `shared/responses/`, plus oversized append-only
  logs and stray work artifacts in the coordination dir — none of which `doctor` saw.
  New: `scripts/archive-resolved`, a wind-down sweep that archives every
  resolved-but-un-archived exchange in one call (delegating the moves to
  `archive-request` for its two-phase safety). It is fail-closed: it refuses unless the
  system is provably quiescent — a strict `jq` idle-tuple predicate (`state=idle`,
  `active_request=null`, `human_required=false`) plus a file-authoritative
  `unprocessed_ids`-empty backstop — so a partial/stale/corrupt status cannot license a
  sweep, and the active *thread* (root + all its re-audit/escalation members) is held
  back so a live thread is never split. `--dry-run` previews. `scripts/doctor` gains
  three warnings: resolved-but-un-archived backlog, oversized runtime logs
  (`conversation.md`/`*.out`/rotated `.1`, cap `AF_LOG_WARN_KB`), and stray non-protocol
  files in `shared/`. New shared helpers `resolved_unarchived_ids`, `active_thread_root`,
  `thread_of`. 13 new tests (jq / no-jq / dash). Built and reviewed *through the
  framework itself* (4 Secondary review cycles; see the archived
  `REQ-20260727-133454` thread).
- **`secondary-loop` conversation.md rotation.** The headless transcript is rotated to
  `conversation.md.1` (one rolling backup) at watcher startup when it exceeds a cap
  (`AF_CONV_MAX_KB`, default 512 KB), bounding on-disk size to ~2× the cap so the
  transcript can't grow unbounded across sessions.
- **Persistent headless Secondary + conversation transcript.** `scripts/secondary-loop`
  is the headless equivalent of leaving a Secondary in a second terminal: it blocks on
  `scripts/watch`, and on each published request runs a headless review via
  `scripts/secondary-agent` (provider-agnostic: `codex exec` or `claude -p`), then
  appends the exchange (request summary + verdict/findings/rationale) to
  `shared/conversation.md` — a readable companion to `master-log.md`. Reproduces the
  two-terminal auto-detection ergonomic; works in either pairing direction. Stop via
  `shared/.stop-secondary`; exits 3 when paused. 5 new tests (loop/transcript verified
  with a stub agent, across jq/no-jq/dash).
- **Collaborative planning (ADAPTIVE_COLLABORATION Phase 1)** — a pre-implementation
  planning phase where both agents draft a plan independently and blind, then the
  Primary reveals and synthesizes. New `scripts/plan` CLI (new/seal/submit/reveal/
  synthesize/archive/status), `shared/plans/` artifacts, three templates
  (plan-problem/plan-draft/plan-synthesis), the `planning` state, and the spec in
  `PLANNING.md`. Verdict vocab `READY_TO_BUILD/NEEDS_WORK/REFRAME`; commit-reveal
  blindness is timestamp-verifiable; the synthesized plan records a **contribution
  signal** (the Phase-2 gate / convergence-collapse alarm). Built as a *parallel*
  subsystem — it does not touch the review request/response scripts. 14 new tests
  (jq, no-jq, and dash legs).
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
- **`secondary-loop` graceful-stop latency decoupled from the Primary's patience
  budget.** The persistent watcher only re-checks the `.stop-secondary` sentinel
  between `watch` calls, but a `--idle`-less loop inherited `status.max_idle_seconds`
  (default **900s**) as its idle window — so a graceful stop (or a dead-Secondary
  cleanup) could take up to ~15 min to take effect. `max_idle_seconds` is overloaded:
  it is also the Primary's *much longer* "declare the Secondary dead" budget, which
  must stay above the slowest legitimate review, so it can't simply be lowered. The
  loop now defaults its own idle window to `min(120, max_idle_seconds)` (explicit
  `--idle` still wins), so the sentinel is checked within ~2 min regardless of the
  Primary budget — with **no** effect on request pickup latency (`watch` returns the
  instant work appears). Startup line now reports the active idle window; +1 test.
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
