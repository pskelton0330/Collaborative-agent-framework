# AGENTS.md — for AI coding agents

This repository is the **agent-collaboration framework**: a file-based, two-agent
(Primary/Secondary) review-and-planning protocol with bounded loops.

## If the user asks you to "install" or "set this up"
1. Place this folder at `~/agent-framework` (clone or copy it there). The `/collab`
   launcher and other tooling default to that path.
2. Make the helper scripts executable: `chmod +x scripts/*`.
3. Verify: `scripts/doctor` — it should report "healthy".
4. Dependencies: POSIX shell + standard Unix tools (required); `jq` and `git`
   (recommended). On Windows, run under WSL or Git Bash.

That's the whole install — the scripts resolve their own location and need no build.

## If the user asks you to USE it
Read `PROTOCOL.md` (the authoritative contract), then `PRIMARY_AGENT.md` /
`SECONDARY_AGENT.md` (role manuals) and `README.md` (quick start). For collaborative
planning see `PLANNING.md`; for the cooperative-agent stance see `THREAT_MODEL.md`.

## Do not
- Commit runtime state under `shared/` (the live `requests/`, `responses/`,
  `escalation/`, `archive/`, `plans/`, and the live `status.json` / `master-log.md`).
  Those are working state, not source — `.gitignore` already excludes the volatile
  parts. Never paste secrets into requests, responses, logs, or commits.
