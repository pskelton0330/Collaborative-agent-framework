# Example Workflow, Demo & Extensions

A concrete walk-through of the framework in action, followed by a sample
transcript and ideas for extending it. Read [`PROTOCOL.md`](PROTOCOL.md) first if
you haven't.

---

## 1. Worked example — a normal audit cycle

Scenario: the user asks the Primary to add token-based session auth, and the
Primary wants a security review before committing.

```
PRIMARY (you drive)                      SECONDARY (watching)
-------------------                      --------------------
implement the auth code
new-request --type security
fill in <id1>.md.draft
submit-request <id1>        ──request──▶  watch returns <id1>; read request
                                          review ONLY the listed files
                                          stage <id1>.response.md.tmp (BLOCKED)
watch --response <id1>      ◀─response──  complete-request -> response_ready
read findings; apply fixes
cycle.review_cycles += 1
new-request (re-audit, thread: <id1>)
fill draft; submit-request <id2> ─req──▶  review again
                                          complete-request (APPROVED)
archive-request <id1> <id2>               (thread closed; state -> idle)
```

Step by step:

1. **Primary implements** the auth code.
2. **Primary requests a review:** `new-request --type security --files
   "src/auth/session.ts,src/auth/token.ts"` creates a *draft* and prints
   `REQ-...-security`. The Primary fills in context/questions/`expected_output`,
   then `submit-request REQ-...-security` validates and publishes it.
   `status.json` → `state: request_pending`, `owner: secondary`.
3. **Secondary** (running `scripts/watch`) gets the id, reads the request, reviews
   only those two files, and finds tokens are written to a debug log. It stages
   `responses/REQ-...-security.response.md.tmp` with `approval: BLOCKED` and a
   `high`-severity finding, then `complete-request` validates and atomically
   publishes it. `status.json` → `state: response_ready`, `owner: primary`.
4. **Primary** reads the response, removes the token logging, increments
   `cycle.review_cycles` to 1, and issues a re-audit (a fresh request id with
   `thread:` set to the first request's id).
5. **Secondary** re-reviews, now `approval: APPROVED`, `risk: low`.
6. **Primary** archives the whole thread in one call —
   `scripts/archive-request <id1> <id2>` — which sets `state: idle`, and tells the
   user: *"Auth added. Review caught tokens being written to the debug log; I
   removed that. Now APPROVED, low risk."*

---

## 2. Worked example — escalation → human handoff

Scenario: the Primary keeps failing to make a flaky integration test pass.

1. Primary attempts a fix → test fails. `cycle.retry_count = 1`.
2. Second attempt → fails. `retry_count = 2`.
3. Third attempt → fails. `retry_count = 3 == max_retries`.
   The Primary **stops blind retrying** and escalates: `new-request --type
   escalation` + `submit-request`. Publishing bumps `cycle.escalation_level` to 1
   and sets `state: escalated`.
4. The escalation request lays out what was tried and two candidate approaches.
   The **Secondary** does a deeper review and proposes a third approach (the test
   is racing on a shared fixture; isolate it). Writes a response.
5. Primary tries the proposed approach → still failing in CI only.
   It escalates again → `escalation_level = 2`, which equals
   `max_escalation_cycles`. No further escalation is allowed — a third
   `new-request --type escalation` is refused (exit 3).
6. **Stopping condition reached.** Primary performs the human handoff
   (`PROTOCOL.md §11`): sets `state: human_required`, `human_required: true`,
   appends a `HUMAN_REQUIRED` log entry summarizing the goal, the three attempts,
   and the suspected CI-only race, with two options for the human. It then stops
   automating and asks the user how to proceed. The Secondary sees
   `human_required` and stays idle.

This is the safety net: bounded retries → bounded escalations → a clear,
summarized handoff instead of an infinite loop.

---

## 3. Demo interaction (sample transcript)

**Terminal 1 — Primary**

```
user> [pastes templates/primary-startup-prompt.md with task "add a /healthz endpoint"]

primary> Read PROTOCOL.md and PRIMARY_AGENT.md. Initialized status.json (idle).
         Here is the Secondary startup prompt — paste it in a second terminal:

         ┌─ copy ─────────────────────────────────────────────┐
         │ You are the SECONDARY AGENT ...                     │
         │ framework: /path/to/project/agent-framework/       │
         │ ...                                                 │
         └─────────────────────────────────────────────────────┘

         Now implementing the /healthz endpoint.
         ...done. Requesting a pre-commit review (REQ-20260528-101501-pre-commit).

primary> Review came back APPROVED_WITH_CONCERNS (risk: low): suggests returning
         503 when the DB ping fails instead of always 200. I'll apply that —
         it's a real correctness point — then archive.
         Done. /healthz now returns 503 on DB failure. Archived. Anything else?
```

**Terminal 2 — Secondary**

```
secondary> Read PROTOCOL.md and SECONDARY_AGENT.md. Monitoring for requests.
           (idle…)
           Request detected: REQ-20260528-101501-pre-commit. Reviewing
           src/routes/health.ts.
           Wrote response: APPROVED_WITH_CONCERNS, risk low. One concern: always
           returns 200 even when the dependency check fails.
           Back to monitoring. (idle…)
```

---

## 4. Try it yourself (with the scripts)

From the project root, you can dry-run the mechanics without two live agents:

```sh
# 1. See state
agent-framework/scripts/status

# 2. Create a request DRAFT (prints the id). Pass --files so it will validate.
id=$(agent-framework/scripts/new-request --type bug-risk --files "README.md")

# 3. Fill in the draft (requests/$id.md.draft), then publish it:
agent-framework/scripts/submit-request "$id"

# 4. The "Secondary" detection step now returns the id immediately
agent-framework/scripts/watch          # prints $id, exits 0

# 5. Stage a response (responses/$id.response.md.tmp) from the template, then:
agent-framework/scripts/complete-request "$id"

# 6. Close it out
agent-framework/scripts/archive-request "$id"
agent-framework/scripts/status         # idle, archived: 1
```

(A variant of this sequence is what was used to smoke-test the framework.)

---

## 5. Future extension ideas

Kept out of the v1 on purpose — add only if you actually need them:

- **`git`-aware requests.** Have `new-request` default `--files` from
  `git diff --name-only` so the Primary doesn't list files by hand.
- **Response-driven status.** A tiny file-watch hook that flips `status.json`
  the instant a response file appears (today the Secondary or `complete-request`
  does it explicitly).
- **Severity gates.** Refuse to archive while an unresolved `high`/`critical`
  finding exists, unless the Primary records an explicit override in the log.
- **More roles.** A third "tester" agent that only runs the suite and reports,
  using the same request/response contract.
- **Structured findings.** Emit a machine-readable `findings.json` alongside the
  Markdown response for tooling/metrics.
- **Metrics.** A `scripts/report` that scans `archive/` to show review counts,
  approval-rate, average cycles-to-approval, escalation frequency.
- **Lock files.** If you ever run more than two agents, add advisory lock files
  around `status.json` writes (the v1 relies on the single-owner rule instead).
- **Notification hook.** Fire a desktop/Slack notification when `state` becomes
  `human_required`, so the human knows automation paused.

Keep the spirit of the framework: plain files, single source of truth, bounded
loops, and a human who can read every byte of state.
