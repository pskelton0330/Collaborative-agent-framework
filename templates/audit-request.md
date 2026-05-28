---
request_id: REQ-YYYYMMDD-HHMMSS-type
created_at: YYYY-MM-DDTHH:MM:SSZ
type: security            # security | architecture | bug-risk | regression | test-coverage | performance | pre-commit
files:                    # explicit scope — Secondary reviews ONLY these (PROTOCOL §5)
  - path/to/file-a
  - path/to/file-b
retry_count: 0            # snapshot of status.json cycle.retry_count
escalation_level: 0       # snapshot of status.json cycle.escalation_level
review_cycle: 1           # = status.cycle.review_cycles + 1
thread: null              # null for a fresh thread; else the root request id this re-audits
human_review_required: false
expected_output: |
  <Describe what a good answer looks like. e.g. "Confirm no secrets are logged;
   flag any plaintext token storage; severity per finding; explicit APPROVED/
   APPROVED_WITH_CONCERNS/BLOCKED.">
---

## Context summary
<Background the reviewer needs. Make this self-contained — the Secondary should
NOT have to read the master log. What is this code for? What user goal does it
serve? What constraints apply?>

## What changed / what to review
<The specific diffs, functions, or behaviors to examine. Paste short snippets or
point to exact symbols. If this is a re-audit, link the prior request id and say
what you changed since.>

## Specific questions
1. <Concrete question 1>
2. <Concrete question 2>
3. <...>

## Out of scope
<Optional: things you do NOT want reviewed this round, to keep it focused.>
