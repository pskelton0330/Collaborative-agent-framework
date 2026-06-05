# Changelog

All notable changes to this framework are recorded here. Dates are UTC.

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
