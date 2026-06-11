---
request_id: REQ-YYYYMMDD-HHMMSS-type
responded_at: YYYY-MM-DDTHH:MM:SSZ
approval: APPROVED            # APPROVED | APPROVED_WITH_CONCERNS | BLOCKED
risk: low                     # low | medium | high
review_cycle: 1               # must match the request's review_cycle
# --- progress overlay (PROTOCOL §6/§10). Fill on every re-audit. The default below is
#     SAFE (continuity unknown => overlay disabled): only set `ok` once you've filled
#     real ids and mapped them to the prior cycle. Ids are short stable tokens (F1, F2…);
#     REUSE an id for the SAME concern across the thread — a still-open problem keeps its
#     id even after a fix attempt. Either fill all five fields or delete all five. ---
unresolved:     []            # finding ids you STILL consider open
resolved_since: []            # ids the Primary's last fix actually closed this cycle
new_this_cycle: []            # ids you are raising for the first time this cycle
movement: false               # advisory only — did anything change vs the last cycle?
progress_continuity: unknown  # set 'ok' ONLY when ids are filled & mapped to prior cycle
# --- reviewed_shas (optional): enables scripts/review-gate. One line, space- or
#     comma-separated `path=sha` tokens, where sha = `git hash-object <path>` of the
#     content you reviewed. The commit gate treats a staged file as "covered" only
#     if its current blob hash matches one recorded here, so a file changed after
#     review reads as uncovered. Omit if you don't use the gate. A path with a space
#     or comma can't be represented and reads as uncovered (fail-safe). ---
reviewed_shas:   # e.g. scripts/doctor=<sha> scripts/review-gate=<sha>
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
