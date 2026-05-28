# Agent Framework — Local Multi-Agent Collaboration

A portable, **file-based** framework that lets **two local CLI coding agents**
collaborate on a codebase with no APIs, servers, databases, or cloud services.
Everything coordinates through plain files in this folder.

- **Primary Agent** — does the implementation work, guided by you. Owns the
  workflow and is the only one that edits project files.
- **Secondary Agent** — a passive reviewer/auditor. It wakes only when the Primary
  asks for a review, writes a structured response, then goes idle again. It never
  edits your code.

The two agents talk by dropping Markdown files into shared directories and
updating one small JSON status file. **You normally only talk to the Primary.**

> Status: a practical **v1**. It has been self-reviewed (docs + scripts) but has
> limited real-world mileage — see **Safety & limits** before using it on
> something important.

---

## How it works (30 seconds)

1. The Primary implements something, then creates a **review request** (a Markdown
   file) at a checkpoint.
2. The Secondary is running a blocking watcher; it detects the request, reviews
   **only the files the request lists**, and writes a structured **response**
   (`APPROVED` / `APPROVED_WITH_CONCERNS` / `BLOCKED`).
3. The Primary reads the response, applies fixes, and either closes the thread or
   re-audits. Retries, review cycles, and escalations are all **bounded** so the
   loop can't run forever; when limits are hit it hands off to you.

Every exchange is a readable file you can inspect, edit, or commit.

---

## Requirements

- **Two CLI coding-agent sessions** (e.g. Claude Code, Aider, Cursor's agent, etc.)
  — one per role, ideally in two terminals.
- A **POSIX shell** (`/bin/sh`) and standard Unix tools: `grep`, `sed`, `awk`,
  `date`, `head`, `basename`, `dirname`, `mkdir`, `mv`, `rm`. Works on macOS
  (BSD userland) and Linux (GNU) — no GNU-only features are used.
- **`jq` is optional.** With `jq` the helper scripts edit `status.json` atomically;
  without it they fall back to a portable `grep` reader and print a notice. Safety
  gates (`human_required`, the escalation limit) work either way. Installing `jq`
  is recommended but not required.

No network access is needed or used.

---

## Install

Clone it, or copy the folder into your project:

```sh
# Option A: clone and copy into your project
git clone <this-repo-url> agent-framework-src
cp -R agent-framework-src/ /path/to/your-project/agent-framework

# Option B: just copy the folder you already have
cp -R agent-framework /path/to/your-project/
```

The framework is self-contained; the scripts resolve their own location, so it
works wherever you put it. The visible folder name (`agent-framework`) is just a
convention — rename it if you like.

---

## Quick start

1. **Copy** this `agent-framework/` folder into the root of your project.
2. **Launch the Primary Agent** and paste the contents of
   [`templates/primary-startup-prompt.md`](templates/primary-startup-prompt.md) as
   its first message (then describe your task). It will initialize shared state and
   print a filled-in **Secondary startup prompt** for you to copy.
3. **Launch the Secondary Agent** in a second terminal/session and paste that
   prompt. It reads the docs and enters monitoring mode.
4. **Work with the Primary as usual.** At meaningful checkpoints it creates review
   requests; the Secondary answers them; the Primary applies the feedback and
   reports back to you.

That's it — you mostly interact with the Primary.

---

## Recommended: run both agents in autonomous ("hands-off") mode

This framework is a **file-based loop**: the Primary writes files and runs the
helper scripts, and the Secondary blocks on a watcher and writes responses. If your
agent stops to ask permission on every file edit or command, the loop stalls
constantly and the "minimal human intervention" design is defeated.

**Strongly recommended:** put **both** agents in their tool's auto-accept /
autonomous mode so they can create files, run the `scripts/*` helpers, run tests,
and build **without prompting on every step**. For example:

- **Claude Code** — enable *auto-accept edits* mode (toggle with `Shift+Tab`), or
  start with a permissive permission mode.
- **Aider** — `--yes-always`.
- **Cursor** — turn on the agent's *auto-run* for commands/edits.

The Secondary especially should be fully hands-off — it only reads files and writes
responses, so it's low-risk to let it run unattended.

**Keep one hand on the wheel for irreversible actions.** Autonomy for the
edit/build/review loop is great; blanket autonomy for *destructive or external*
actions is not. So:

- Run on a **branch** off a clean, committed baseline.
- Do **not** let either agent auto-`push`, deploy, or run destructive commands
  unprompted — keep those gated, or simply don't grant those permissions.
- You still own the merge button. `APPROVED` means "a second agent didn't object,"
  not "verified correct."

---

## Folder layout

```
agent-framework/
  README.md                  ← you are here
  PROTOCOL.md                ← the contract: state machine, lifecycle, safeguards, recovery
  PRIMARY_AGENT.md           ← operating manual for the Primary Agent
  SECONDARY_AGENT.md         ← operating manual for the Secondary Agent
  EXAMPLE_WORKFLOW.md        ← worked examples + demo transcript + extension ideas

  shared/                    ← all mutable coordination state lives here
    status.json              ← small machine-readable state (owner, state, counters, limits)
    master-log.md            ← human-readable append-only timeline
    requests/                ← open requests   (Primary → Secondary)
    responses/               ← responses       (Secondary → Primary)
    escalation/              ← deeper-review escalation requests
    archive/                 ← completed exchanges, one folder per request id

  templates/                 ← copy-paste templates for requests/responses/startup prompts
    audit-request.md  audit-response.md  escalation-request.md
    primary-startup-prompt.md  secondary-startup-prompt.md

  scripts/                   ← optional portable POSIX-sh helpers
    new-request              ← create a request DRAFT from a template
    submit-request           ← validate a filled draft, then atomically publish it
    watch                    ← block until there's work (or a response), then return
    complete-request         ← validate + atomically publish a response
    archive-request          ← move finished exchange(s) into archive/
    status                   ← pretty-print status.json + a work summary
```

---

## The two coordination channels

The framework deliberately uses **two** channels so the human-readable log is never
the sole trigger:

| Channel | File(s) | Role |
|---|---|---|
| **Status** | `shared/status.json` | Fast, machine-readable: who owns the turn, current state, active request, retry/escalation counters, limits, the `human_required` stop flag. |
| **Log** | `shared/master-log.md` | Human-readable, append-only timeline: decisions, review summaries, escalations, human-intervention notices. |
| **Requests / Responses** | `shared/requests/*`, `shared/responses/*` | The actual work units — self-contained, so the Secondary need not read the whole log. |

See [`PROTOCOL.md`](PROTOCOL.md) for the authoritative rules.

---

## Safety & limits (read before trusting it with real work)

**What's low-risk by design:**
- Local-only and file-based — no network, no external blast radius.
- The Secondary is **read-only** — it reviews and writes responses, never edits code.
- Loops are **bounded**; the escalation limit is *mechanically* enforced, and
  `human_required` pauses everything.
- All state is on disk and inspectable; recovery is defined (see PROTOCOL §14).

**What to keep in mind:**
- The **Primary is still an autonomous coding agent** editing your files and running
  commands — the framework adds a review net but doesn't remove that inherent risk.
- The safety net is **soft**: it relies on the Primary following the protocol
  (only the escalation cap is hard-enforced). A confused agent can skip a review or
  proceed past a `BLOCKED`.
- The Secondary's reviews are **fallible LLM reviews** — a useful second opinion,
  not a correctness guarantee.
- This is a **v1 with limited real-world mileage.** Prove it on a low-stakes repo
  first; keep a human gate on commits/pushes/deploys.

---

## Embedding in your own repo

If you copy `agent-framework/` into a project under version control, the included
[`.gitignore`](.gitignore) already excludes the live coordination artifacts
(`requests/`, `responses/`, `escalation/`, `archive/` contents and `*.draft` /
`*.response.md.tmp` staging files). If you also don't want the mutable
`shared/status.json` and `shared/master-log.md` churning your history, add them to
your project's ignore list too (noted at the bottom of `.gitignore`).

---

## License

MIT — see [`LICENSE`](LICENSE).
