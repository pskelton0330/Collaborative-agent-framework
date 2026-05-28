---
request_id: REQ-YYYYMMDD-HHMMSS-type
responded_at: YYYY-MM-DDTHH:MM:SSZ
approval: APPROVED            # APPROVED | APPROVED_WITH_CONCERNS | BLOCKED
risk: low                     # low | medium | high
review_cycle: 1               # must match the request's review_cycle
reviewed_files:
  - path/to/file-a
  - path/to/file-b
---

## Findings
<For each finding:>
- **[severity]** `path/to/file:line` — <what is wrong / notable>.
  Why it matters: <impact>.
<severity ∈ info | low | medium | high | critical. If none: "No issues found.">

## Recommended fixes
<Ordered, actionable. Reference files and lines. Smallest correct change first.>
1. ...
2. ...

## Risk assessment
<One short paragraph: residual risk if the Primary proceeds as-is, and the
blast radius of the riskiest finding.>

## Approval rationale
<Why this approval state. For BLOCKED, list the concrete blockers that must be
resolved. For APPROVED_WITH_CONCERNS, list which concerns are non-blocking and
why it's safe to proceed.>
