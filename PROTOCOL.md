# PROTOCOL

The contract both agents follow. If `PRIMARY_AGENT.md` or `SECONDARY_AGENT.md`
ever seems to conflict with this file, **this file wins**.

---

## 1. Roles and ownership

- **Primary Agent** owns the *workflow* and the *implementation*. It is the only
  agent that creates requests, increments counters, decides when a cycle ends,
  and edits project files.
- **Secondary Agent** owns *reviews*. It only ever: reads a request, inspects the
  files the request lists, and writes a response. It never creates requests,
  never edits project files, and never re-reviews a request it has already
  answered.

There is exactly **one turn owner** at any moment, tracked by
`status.json → owner` (`primary` | `secondary` | `human`). Only the owner mutates
shared state, with exactly two exceptions: (a) the Secondary writing its response
and flipping `state`/`owner` for *its own* `in_review → response_ready`
transition; and (b) the Primary performing **reconciliation** on startup (§14).
**Reconciliation is Primary-only** — the Secondary never reconciles global state.
When `human_required: true`, automation is paused and this **overrides** any
file-derived work (§11, §14): neither agent resumes work or reconciles until a
human clears the pause.

---

## 2. The state machine

`status.json → state` is the authoritative indicator of the current *phase /
turn*. For whether a unit of work *exists or is complete*, the **files** are
authoritative, not `status.json` (see §14). If the two ever disagree, reconcile
from the files — but reconciliation is **Primary-only** and is skipped entirely
while `human_required: true` (§14).

```
        ┌─────────────────────────────────────────────────────┐
        │                                                       │
        ▼                                                       │
     ┌──────┐  Primary creates request   ┌──────────────────┐  │
     │ idle │ ─────────────────────────▶ │ request_pending  │  │
     └──────┘                            └──────────────────┘  │
        ▲                                          │           │
        │                          Secondary picks │ up        │
        │                                          ▼           │
        │                                  ┌──────────────┐    │
        │                                  │  in_review   │    │
        │                                  └──────────────┘    │
        │                                          │           │
        │                      Secondary writes    │ response  │
        │                                          ▼           │
        │  Primary archives          ┌──────────────────────┐  │
        └──────────────────────────  │   response_ready     │  │
                                      └──────────────────────┘  │
                                                 │              │
                       Primary needs deeper help │ (limit hit)  │
                                                 ▼              │
                                        ┌──────────────┐        │
                                        │  escalated   │ ───────┘ (re-review)
                                        └──────────────┘
                                                 │
                            all limits exhausted │
                                                 ▼
                                       ┌──────────────────┐
                                       │  human_required  │ (automation paused)
                                       └──────────────────┘
```

Valid `state` values: `idle`, `request_pending`, `in_review`, `response_ready`,
`escalated`, `human_required`.

---

## 3. status.json schema

Keep this file **small**. Agents read/write it with their normal file tools.

```jsonc
{
  "schema_version": 1,
  "updated_at": "2026-05-28T14:30:22Z",   // ISO-8601 UTC, set on every write
  "updated_by": "primary",                 // primary | secondary | human | system
  "owner": "primary",                      // who may act next
  "state": "idle",                         // see state machine
  "active_request": null,                  // request id string, or null when idle

  "cycle": {                               // counters for the CURRENT task/thread
    "task_label": null,                    // short human label of what Primary is attempting
    "retry_count": 0,                      // failed implementation attempts at this task
    "review_cycles": 0,                    // audit→fix→re-audit loops on this thread
    "escalation_level": 0                  // how many times this task has escalated
  },

  "limits": {                              // stop conditions (tune per project)
    "max_retries": 3,
    "max_review_cycles": 3,                // SOFT review ceiling (governs unless extended, §10)
    "max_review_cycles_hard": 10,          // ABSOLUTE review ceiling; nothing extends past it
    "max_escalation_cycles": 2,
    "idle_poll_seconds": 8,                // how often the watcher polls
    "max_idle_seconds": 900                // watcher returns "still idle" after this
                                           // (~15 min; a dead Secondary surfaces fast)
  },

  "human_required": false,                 // true => automation paused, await human
  "notes": null                            // one-line free text, optional
}
```

**Rules**

- Always update `updated_at` and `updated_by` on every write.
- `active_request` is `null` when `state` is `idle`. When `state` is
  `human_required` it MAY name the blocking request (for context) or be `null`.
  In every other state it names the active request.
- The `cycle` block resets to zeros + new `task_label` when the Primary starts a
  genuinely new task. It is **not** reset for a re-audit of the same task.

---

## 4. Identifiers and file naming

Request id format: `REQ-<UTC-YYYYMMDD>-<HHMMSS>-<type>`
(e.g. `REQ-20260528-143022-security`). It is sortable, self-describing, and
*intended* to be unique — but a second-resolution timestamp is not inherently
collision-proof, so `new-request` refuses any id that already exists anywhere (open
or archived) and the creator must pick another (or pass an explicit `--id`).

| Artifact | Path |
|---|---|
| Request | `shared/requests/<request-id>.md` |
| Response | `shared/responses/<request-id>.response.md` |
| Escalation request | `shared/escalation/<request-id>.escalation.md` |
| Archived exchange | `shared/archive/<request-id>/` (contains `request.md`, `response.md`, and `escalation.md` if any) |

**Pairing rule:** a request and its response share the same `<request-id>` stem.
A request is **unprocessed** iff its file exists in `requests/` (or `escalation/`)
and no matching `responses/<request-id>.response.md` exists. This single rule is
how the Secondary avoids double-processing — it never needs extra bookkeeping.

**Atomic writes — no partial file ever counts.** Drafts and in-progress responses
are written under a staging name that the pairing rule does NOT match, then
atomically renamed into place:

- A new request is staged as `requests/<id>.md.draft` (or
  `escalation/<id>.escalation.md.draft`) and only becomes real when
  `submit-request` renames it to the final path. `watch` ignores `*.draft`.
- A response is staged as `responses/<id>.response.md.tmp` and only counts once
  `complete-request` renames it to `responses/<id>.response.md`.

So a crash mid-write leaves only a `.draft`/`.tmp` that nothing acts on — the work
is simply re-done. The final, non-staging file is the authoritative signal.

---

## 5. Request file contract

Every request (normal or escalation) MUST contain, in YAML front-matter plus a
body, at least:

```markdown
---
request_id: REQ-20260528-143022-security
created_at: 2026-05-28T14:30:22Z
type: security            # security | architecture | bug-risk | regression | test-coverage | performance | pre-commit | escalation
files:                    # explicit scope — see "Review scope" below
  - src/auth/session.ts
  - src/auth/token.ts
retry_count: 0            # snapshot of status.json counters at request time
escalation_level: 0       # (status.json stays authoritative; these are context)
review_cycle: 1           # = status.cycle.review_cycles + 1 at request time
thread: null              # null for a fresh thread; else the root request id this re-audits
human_review_required: false
expected_output: |        # what a good response looks like for this request
  Confirm tokens are never logged; flag any plaintext storage; severity per finding.
---

## Context summary
Enough background that the reviewer does NOT need to read the master log.

## What changed / what to review
Specific diffs, functions, or behaviors.

## Specific questions
1. ...
2. ...
```

A request must be **self-contained**. If the Secondary has to guess, the request
is underspecified — that is a Primary bug.

**Counters are a snapshot.** `retry_count`, `escalation_level`, and `review_cycle`
in the front-matter are a convenience copy of `status.json` at request time, for
the reviewer's context only; `status.json` is authoritative if they ever differ.
`review_cycle` is defined as `status.cycle.review_cycles + 1`. **Escalation
exception:** on an escalation request, `escalation_level` records the level the
escalation *establishes* — i.e. `status.cycle.escalation_level + 1`, since
publishing the escalation increments it (`new-request --type escalation` pre-fills
this). Normal requests snapshot the current `escalation_level` unchanged.

**Review scope (binding on the Secondary).** The Secondary reviews **only** the
files in `files:`. It MAY open an unlisted file *solely to read a definition it
needs to judge a listed file*, but it MUST NOT report findings on unlisted files —
instead it notes "outside reviewed scope" and, if important, recommends the
Primary open a follow-up request. This keeps scope deterministic across different
reviewer models.

**Re-audits and threads.** A re-audit uses a NEW request id and sets `thread:` to
the root request id of the thread (the id of the first request in the chain). The
Primary archives every id in a thread together when the thread resolves
(`archive-request <id1> <id2> ...`).

---

## 6. Response file contract

The Secondary writes the response to the staging path
`responses/<id>.response.md.tmp`, then runs `complete-request <id>`, which
validates the front-matter and atomically publishes it to
`responses/<id>.response.md`. Every response MUST contain:

```markdown
---
request_id: REQ-20260528-143022-security
responded_at: 2026-05-28T14:41:10Z
approval: APPROVED            # APPROVED | APPROVED_WITH_CONCERNS | BLOCKED
risk: low                     # low | medium | high
review_cycle: 1               # which cycle of this thread this answers
unresolved:     [F1, F3]      # progress overlay (optional cycle 1; fill on re-audits)
resolved_since: [F2]          # ids the Primary's last fix closed THIS cycle
new_this_cycle: [F4]          # ids raised for the first time THIS cycle
movement: true                # advisory only — NOT trusted by the gate
progress_continuity: ok       # ok | unknown
---

## Findings
For each: severity (info | low | medium | high | critical), file:line, what, why.

## Recommended fixes
Actionable, ordered. Reference files and lines.

## Risk assessment
One short paragraph on residual risk.

## Approval rationale
Why APPROVED / APPROVED_WITH_CONCERNS / BLOCKED.
```

**Approval semantics**

- `APPROVED` — safe to proceed. Any notes are optional/non-blocking.
- `APPROVED_WITH_CONCERNS` — proceed allowed, but listed concerns should be
  weighed. The Primary may accept and move on **without** another review cycle.
- `BLOCKED` — do not proceed. The response must list concrete blockers.

**Progress overlay (the `unresolved`/`resolved_since`/`new_this_cycle`/`movement`/
`progress_continuity` block).** This feeds the *tightening overlay* on the loop guard
(§10) — a structured, machine-checkable signal of whether a re-audit actually moved.

- **Finding ids** are short stable tokens (`F1`, `F2`, …). An id names **one concern
  for the whole thread**. **Reuse the same id for the same concern across cycles** —
  if the Primary attempts a fix and the Secondary still sees an equivalent problem,
  it is **still that id in `unresolved`**, not a new one. This is what lets the
  overlay tell real progress from churn that merely renames the same disagreement.
- **`unresolved`** = ids still open after this review. **`resolved_since`** = ids the
  Primary's last fix actually closed this cycle. **`new_this_cycle`** = ids raised for
  the first time this cycle. Every change to the `unresolved` set across two cycles
  must be explained: ids that left `unresolved` appear in this response's
  `resolved_since`; ids that entered appear in its `new_this_cycle`.
- **`progress_continuity`** is `ok` only when the Secondary is confident it has mapped
  its ids to the prior cycle's. If it cannot (a restart with no memory, ambiguous
  equivalence, missing prior ids), it MUST be `unknown` — which makes the overlay fall
  back to the count backstop. **Uncertain identity must never read as progress.**
- **`movement` is advisory only.** The verdict is computed mechanically from the set
  diff + algebra by `check-progress`, never from this bit.
- The block is **atomic and safe-by-default**: include all five fields or none (a
  partial block is rejected at publish). Omitting it (cycle-1, old-format) degrades to
  the count guard — backward compatible. The template default is
  `progress_continuity: unknown`, which the overlay treats as untrusted; both compared
  responses must assert `ok` for a `productive`/`productive-rank-only`/`impasse`
verdict, and any malformed id
  list also reads as `insufficient-data`. **Placeholder or malformed data never
  produces a verdict.**

---

## 7. Request lifecycle (happy path)

1. **Primary** finishes a chunk of work and decides a checkpoint is warranted.
2. **Primary** creates a draft (`new-request`), fills it in, then publishes it
   (`submit-request`). Publishing renames the draft into `requests/<id>.md`, sets
   `status.json` to `state: request_pending`, `owner: secondary`,
   `active_request: <id>`, and appends a `REQUEST` entry to the master log.
3. **Secondary** (watching) detects the unprocessed request, sets
   `state: in_review`, `updated_by: secondary` (owner stays `secondary`).
4. **Secondary** reviews only the listed files (see "Review scope", §5), writes
   the response to `responses/<id>.response.md.tmp`, then runs `complete-request`,
   which validates and atomically renames it to `responses/<id>.response.md`, sets
   `state: response_ready`, `owner: primary`, and appends a concise `RESPONSE`
   entry (approval + risk) to the log.
5. **Primary** reads the response:
   - `APPROVED` → apply optional notes, go to step 7.
   - `APPROVED_WITH_CONCERNS` → decide: accept (go to 7) or address concerns
     (go to 6).
   - `BLOCKED` → address blockers (go to 6).
6. **Primary** applies fixes, increments `cycle.review_cycles`, and either issues
   a re-audit (new request id with `thread:` set to the thread's root id) or — if
   a limit is hit — escalates (§9). Re-audits return to step 2.
7. **Primary** archives the whole thread (`archive-request <id> [<id>...]`), which
   resets `state: idle`, `owner: primary`, `active_request: null` when the active
   id is among them, appends `ARCHIVE` (+ a `RESOLVED` note) to the log, and
   reports the outcome to the user.

---

## 8. Retry tracking (implementation attempts)

Distinct from review cycles. `cycle.retry_count` counts **failed attempts by the
Primary to make its own work pass** (tests failing, the same bug recurring, the
same approach not converging). The Primary increments it each time it retries the
*same* task.

- The Primary should increment `retry_count` when: the same test set fails again,
  the same error recurs after a fix attempt, or it notices it is looping on one
  approach.
- When `retry_count >= max_retries`, the Primary must **stop retrying blind** and
  escalate (§9) to get a second opinion / alternative approach, rather than
  attempting the same thing again.

---

## 9. Escalation rules

Escalation is for when normal review isn't enough — the Primary is stuck, or a
review thread keeps failing.

**Triggers (any one):**

- `retry_count >= max_retries` (stuck implementing).
- The review loop stopped without approval — the **effective ceiling** (§10) was
  reached: the soft ceiling with no extension in force, or the hard ceiling.
- The Secondary returned `BLOCKED` on the same concern across two consecutive
  cycles.
- A `pre-commit` review came back `BLOCKED`.

**Procedure:**

1. Primary creates an escalation draft (`new-request --type escalation`), fills in
   what was tried, what failed, and the competing approaches, then publishes it
   (`submit-request`). Publishing sets `state: escalated`, increments
   `cycle.escalation_level`, `owner: secondary`, and logs `ESCALATION`.
2. Secondary performs a **deeper** peer review: it may propose alternate
   approaches, challenge assumptions, and weigh trade-offs (it still does not edit
   project files). It writes a normal response.
3. Primary then chooses exactly one: **accept** the recommendation, **revise** the
   implementation, **request one more audit**, or — if the escalation limit is
   reached — **hand off to the human** (§11).

**Limit semantics.** `max_escalation_cycles` is the number of escalations
*allowed*. Each published escalation increments `escalation_level`. Once
`escalation_level` has reached `max_escalation_cycles`, the Primary MUST hand off
to the human instead of escalating again. This is enforced mechanically:
`new-request --type escalation` refuses (exit 3) when
`escalation_level >= max_escalation_cycles`.

---

## 10. Anti-infinite-loop safeguards

These are mandatory. The Primary enforces all of them.

| Guard | Limit (default) | What happens when hit |
|---|---|---|
| Implementation retries | `max_retries` = 3 | Stop retrying; escalate (§9). |
| Review cycles per thread (soft) | `max_review_cycles` = 3 | Stop re-auditing — **unless** the latest `check-progress` verdict is `productive` (strict count decrease), which permits one more cycle, re-checked every cycle. |
| Review cycles per thread (hard) | `max_review_cycles_hard` = 10 | Absolute ceiling. Stop re-auditing no matter what the overlay says; accept `APPROVED_WITH_CONCERNS`, escalate, or go human. |
| Progress overlay | `check-progress` verdict | `impasse` stops the loop *earlier* than the soft ceiling (human handoff). `productive` extends it past the soft ceiling, bounded by the hard ceiling and by arithmetic (below). |
| Escalation cycles per task | `max_escalation_cycles` = 2 | When `escalation_level` reaches the limit, hand off to human; `new-request` refuses further escalations. |
| Idle wait | `max_idle_seconds` = 900 | Watcher returns "still idle" (~15 min); agent reports idle to its human (and a stalled wait surfaces a dead Secondary) instead of busy-spinning. |

**The progress overlay (adaptive ceiling).** Counting rounds can't tell real progress
from spinning, and never catches frictionless fake agreement. So on each re-audit the
Primary runs `check-progress <thread-root>`, which reads the two most recent responses
in the thread and returns one verdict:

- `productive` — the `unresolved` count **strictly decreased**. Continue; past the
  soft ceiling this is the *only* verdict that permits the next cycle (up to the
  hard ceiling).
- `productive-rank-only` — no count decrease, but the approval rank improved
  (e.g. `BLOCKED` → `APPROVED_WITH_CONCERNS`). Continue **under the soft ceiling
  only** — rank can oscillate, so it never extends the loop.
- `impasse` — continuity `ok`, the set-algebra is clean, but there was **no** net
  improvement. A deliberately **conservative early-stop heuristic** (a real fix paired
  with an unrelated equal-size new finding can also trip it — not semantic certainty);
  the Primary does the **human handoff now**, earlier than the count would.
- `insufficient-data` — fewer than two responses, a missing/old-format block,
  `progress_continuity: unknown`, or unexplained churn. The overlay can't be trusted,
  so the **soft count ceiling governs** (exactly v1.0 behavior — no extension).

**Why extension is safe (termination is arithmetic, not heuristic).** The extension
signal is **well-founded**: the unresolved count is a non-negative integer that must
strictly decrease on *every* extended cycle, so a thread that hits the soft ceiling
with N unresolved findings can extend at most N more cycles before the count hits 0
(review complete) or stalls (verdict ≠ `productive` → stop). A fooled detector can
only end the loop *early* (fabricated resolutions drive the count to 0 — the
fake-agreement failure mode, which the old fixed ceiling never protected against
either); it cannot make the loop run unboundedly. `max_review_cycles_hard` is
defense-in-depth on top of the proof, and the **effective ceiling** referenced in §9
is: the soft ceiling when no `productive` extension is in force, else the hard
ceiling.

**Invariant (v1.2 restatement).** The overlay may stop the loop earlier than the soft
ceiling (`impasse`), and may extend it **only** along a strictly-decreasing unresolved
count, never past `max_review_cycles_hard`. Whenever the overlay cannot be trusted
(`insufficient-data`, including the no-`jq` case), the soft ceiling governs and no
extension is possible — so safety never depends on the overlay.

**Hard ownership constraints (never violated):**

- The **Secondary never creates request or escalation files.** It cannot start a
  loop. It only responds to existing requests.
- The **Secondary never re-reviews a request that already has a response** (the
  pairing rule, §4). To get another look, the Primary must create a *new* request
  id.
- The **Primary is the only agent that decides a cycle is over** and the only one
  that archives.
- The Primary must not reopen an archived request; it opens a fresh one that
  references the old id if needed.

---

## 11. Stopping conditions → human handoff

When `escalation_level` has reached `max_escalation_cycles` (no further escalation
allowed), or the Primary otherwise determines it cannot safely proceed, it
performs the **human handoff**:

1. Set `status.json`: `state: human_required`, `human_required: true`,
   `owner: human`. `active_request` MAY be kept to name the blocker, or set null.
2. Append a `HUMAN_REQUIRED` entry to the master log that summarizes, in plain
   language: the goal, what was tried, why it's blocked, and 1–3 concrete options
   for the human.
3. **Stop automating.** Tell the user directly and wait for instructions. Do not
   create more requests.

The Secondary, if it sees `state: human_required`, stays idle and does nothing.

---

## 12. Concurrency & integrity notes

- The two agents run as separate CLI sessions; true simultaneous writes are rare
  but possible. Mitigations:
  - Ownership (`owner` field) means only one side should be mutating at a time.
  - Status writes should be a single atomic file replacement (write temp file,
    then move into place) — the `scripts/` helpers do this where they touch
    `status.json`.
  - The master log is **append-only**; appending is safe and conflicts are
    obvious if they ever occur.
- If an agent reads a `status.json` whose `owner` is not itself and whose `state`
  doesn't invite its action, it must do nothing and wait/poll.

---

## 13. Quick reference — who does what

| Action | Primary | Secondary |
|---|---|---|
| Edit project files | ✅ | 🚫 |
| Create request / escalation | ✅ | 🚫 |
| Write response | 🚫 | ✅ |
| Increment counters | ✅ | 🚫 |
| Archive | ✅ | 🚫 |
| Append to master log | ✅ | ✅ (concise review notes only) |
| Set `human_required` | ✅ | 🚫 |
| Decide a cycle is done | ✅ | 🚫 |

---

## 14. Recovery & reconciliation

All state is on disk, so any agent can crash and restart. For *work existence and
completion* the **files are authoritative** and `status.json` is a fast advisory
cache for phase/turn. Recovery means making `status.json` agree with the files —
governed by two hard rules:

- **Reconciliation is Primary-only.** The Secondary never reconciles global state.
  On startup the Secondary only: (a) stays idle if `human_required: true`;
  (b) deletes any leftover `*.response.md.tmp` it was writing before a crash (a
  half-written response must not count as done); then (c) runs `watch`. It never
  edits `status.json` except its own `in_review → response_ready` transition.
- **`human_required` has precedence.** While `human_required: true`, automation is
  paused: neither agent performs file-derived work *or* reconciliation. Only a
  human (or the Primary acting on human instruction) clears the pause. Recovery
  never resumes a human-paused system.

**Primary reconciliation on startup** (skip entirely if `human_required: true`):

1. Derive the true situation from files, ignoring staging leftovers (`*.draft`,
   `*.response.md.tmp`), which are NOT real work:
   - *Unprocessed request* — `requests/<id>.md` (or `escalation/<id>.escalation.md`)
     exists with no `responses/<id>.response.md`.
   - *Completed review* — `responses/<id>.response.md` exists.
2. If `status.json` disagrees, fix it to match the files and append a `RECONCILE`
   entry to the master log. The files win.

**Specific cases** (Primary acts, unless noted):

| Symptom | Truth | Action |
|---|---|---|
| `responses/<id>.response.md` exists but `state` ≠ `response_ready` | review is done | set `state: response_ready`, `owner: primary`, `active_request: <id>`, then read it. |
| status claims a review is done/under way but only `*.response.md.tmp` exists | review NOT done (partial) | delete the `.tmp`; request stays unprocessed; it is reviewed again. |
| `requests/<id>.md` exists with no matching response and `state: idle` | request published, status drifted | set `state: request_pending`, `owner: secondary`, `active_request: <id>`. |
| `requests/<id>.md` and `responses/<id>.response.md` both exist, unarchived | review completed; Primary decision pending (unless already resolved in log/context) | set/keep `state: response_ready`, `owner: primary`, `active_request: <id>`; the Primary reads the response and follows approval semantics (§6). Archive **only** after APPROVED or an accepted APPROVED_WITH_CONCERNS (or the thread is otherwise resolved). |
| `active_request` names an id with no request/response/archive | dangling pointer | clear it (`active_request: null`, `state: idle`). |
| **Multiple** unprocessed requests exist at once | invariant broken (Primary keeps ≤1 active) | Primary sets `active_request` to the one it means, archives/deletes the strays; until then the **Secondary** processes only the `active_request` id and leaves the rest. |
| `<id>.md.draft` exists, never submitted | not a real request | Primary finishes it + `submit-request`, or deletes the draft. |
| `human_required: true` | automation paused | both agents stay idle; **no** reconciliation; wait for a human. |

**Single-active invariant.** The Primary keeps **at most one** unprocessed
(active) request at a time. If the Secondary's `watch` ever surfaces more than one
unprocessed id, it reviews only the one equal to `active_request` and leaves the
rest for the Primary — it never guesses or processes multiple.

Staging files left by a crash are always safe to delete. The non-staging file is
the source of truth.
