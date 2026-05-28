---
request_id: REQ-YYYYMMDD-HHMMSS-escalation
created_at: YYYY-MM-DDTHH:MM:SSZ
type: escalation
files:
  - path/to/file-a
retry_count: 3            # snapshot of status.json — usually at/over a limit
escalation_level: 1       # the escalation level this request establishes
review_cycle: 1           # = status.cycle.review_cycles + 1
thread: null              # null for a fresh thread; else the root request id
human_review_required: false
expected_output: |
  A deeper review than a normal audit: challenge my assumptions, propose at least
  one alternate approach, and weigh trade-offs. End with an explicit
  recommendation and approval state.
---

## Why this escalated
<Which trigger fired: max_retries hit / max_review_cycles hit / repeated BLOCKED /
pre-commit BLOCKED. State the counters.>

## The goal
<What I'm ultimately trying to achieve, in plain terms.>

## What I tried
<Each attempt and its outcome. Be honest about what failed and how.>
1. Attempt 1 → result
2. Attempt 2 → result
3. ...

## Approaches I'm weighing
<The competing options I see, with my current read on each.>
- Option A — pros / cons
- Option B — pros / cons

## What I need from you
<e.g. "Is my framing wrong? Is there an option I'm missing? Which option would
you take and why?">
