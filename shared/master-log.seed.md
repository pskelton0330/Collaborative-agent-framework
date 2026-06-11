# Master Log

Human-readable, append-only timeline of collaboration between the Primary and
Secondary agents. Newest entries go at the **bottom**. Never rewrite history —
only append.

Each entry follows this shape:

```
## <ISO-8601 timestamp> — <AGENT> — <event>
<one short paragraph: what happened, why it matters, what changed>
- ref: <request-id / response-id / file paths, if any>
```

Event types you will see: `INIT`, `RECONCILE`, `REQUEST`, `REVIEW`, `RESPONSE`,
`FIX`, `RETRY`, `ESCALATION`, `ARCHIVE`, `HUMAN_REQUIRED`, `RESOLVED`.

Keep entries concise. The log is for traceability and shared reasoning, not a
transcript. Detailed findings belong in the request/response files.

---

## 1970-01-01T00:00:00Z — SYSTEM — INIT
Framework installed. Awaiting Primary Agent initialization.
