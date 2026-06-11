#!/bin/sh
# Shared helpers for agent-framework scripts. SOURCED by the others, not run.
# Keeps path resolution, timestamps, logging, and atomic status writes in one
# place. No hard dependency on jq — JSON edits are skipped (with a notice) when
# jq is absent, and the agent updates status.json itself.

_resolve_framework_dir() {
  # $1 = the calling script's $0
  sp=$1
  case "$sp" in
    /*) : ;;
    *) sp="$(pwd)/$sp" ;;
  esac
  sd=$(cd "$(dirname "$sp")" && pwd)
  cd "$sd/.." && pwd
}

FRAMEWORK_DIR=${FRAMEWORK_DIR:-$(_resolve_framework_dir "$0")}
SHARED="$FRAMEWORK_DIR/shared"
REQUESTS="$SHARED/requests"
RESPONSES="$SHARED/responses"
ESCALATION="$SHARED/escalation"
ARCHIVE="$SHARED/archive"
TEMPLATES="$FRAMEWORK_DIR/templates"
STATUS="$SHARED/status.json"
LOG="$SHARED/master-log.md"

# The live status.json / master-log.md are runtime state (gitignored), so real use
# never dirties the repo. On first use (e.g. a fresh clone), initialize them from the
# committed pristine seeds. Cheap no-op once they exist.
# Atomic (temp + mv in the same dir) so a concurrent first-use never reads a
# half-copied file; absent seed degrades silently to json_get defaults.
[ -f "$STATUS" ] || { [ -f "$SHARED/status.seed.json" ] && cp "$SHARED/status.seed.json" "$STATUS.tmp.$$" && mv "$STATUS.tmp.$$" "$STATUS"; }
[ -f "$LOG" ]    || { [ -f "$SHARED/master-log.seed.md" ] && cp "$SHARED/master-log.seed.md" "$LOG.tmp.$$" && mv "$LOG.tmp.$$" "$LOG"; }

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
# Force the jq-free fallback path even when jq is installed — for exercising/debugging
# the no-jq behaviour (the CI no-jq leg uses this, since jq can't be removed from a
# read-only /usr/bin on macOS).
[ -n "${AF_DISABLE_JQ:-}" ] && HAVE_JQ=0

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# json_get <jq-path> <default> — read a scalar from status.json. Uses jq when
# present; otherwise falls back to a portable grep on the LEAF key name (every leaf
# key in status.json is unique, so this is unambiguous). The fallback is what keeps
# safety gates (human_required, escalation limit) enforced when jq is absent.
json_get() {
  [ -f "$STATUS" ] || { printf '%s' "$2"; return 0; }
  if [ "$HAVE_JQ" -eq 1 ]; then
    v=$(jq -r "$1 // empty" "$STATUS" 2>/dev/null) || v=""
  else
    leaf=${1##*.}
    v=$(grep -E "\"$leaf\"[[:space:]]*:" "$STATUS" 2>/dev/null | head -1 \
        | sed -E "s/.*\"$leaf\"[[:space:]]*:[[:space:]]*//; s/[[:space:]]*,?[[:space:]]*\$//; s/^\"//; s/\"\$//")
    [ "$v" = "null" ] && v=""
  fi
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$2"
}

# log_append <AGENT> <EVENT> <message> [ref]
log_append() {
  {
    printf '\n## %s — %s — %s\n' "$(now_iso)" "$1" "$2"
    printf '%s\n' "$3"
    [ -n "${4:-}" ] && printf -- '- ref: %s\n' "$4"
  } >> "$LOG"
}

# status_set <jq-assignment> [more...]  — atomic; requires jq. Returns 1 if no jq.
# Always refreshes updated_at. Example: status_set '.state="idle"' '.owner="primary"'
status_set() {
  [ "$HAVE_JQ" -eq 1 ] || return 1
  [ -f "$STATUS" ] || return 1
  filter='.updated_at=$ts'
  for a in "$@"; do filter="$filter | $a"; done
  tmp="$STATUS.tmp.$$"
  if jq --arg ts "$(now_iso)" "$filter" "$STATUS" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATUS"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# valid_id <id> — 0 if id is REQ-YYYYMMDD-HHMMSS-<known-type>. Strict on purpose:
# ids are interpolated into paths and jq filters, so the charset must stay safe
# (digits, hyphens, and a fixed set of type words only).
valid_id() {
  case "$1" in
    REQ-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*) : ;;
    *) return 1 ;;
  esac
  case "${1#REQ-????????-??????-}" in
    security|architecture|bug-risk|regression|test-coverage|performance|pre-commit|escalation) return 0 ;;
    *) return 1 ;;
  esac
}

# id_in_use <id> — 0 if the id exists ANYWHERE (open, staged, or archived),
# including draft/tmp variants. Keeps ids globally unique and blocks reopening
# an archived id.
id_in_use() {
  i=$1
  [ -e "$REQUESTS/$i.md" ] && return 0
  [ -e "$REQUESTS/$i.md.draft" ] && return 0
  [ -e "$ESCALATION/$i.escalation.md" ] && return 0
  [ -e "$ESCALATION/$i.escalation.md.draft" ] && return 0
  [ -e "$RESPONSES/$i.response.md" ] && return 0
  [ -e "$RESPONSES/$i.response.md.tmp" ] && return 0
  [ -d "$ARCHIVE/$i" ] && return 0
  return 1
}

# --- Front-matter helpers: parse the YAML front-matter REGION ONLY, never the body. ---
# fm_region <file> — print the lines strictly between the opening '---' (line 1) and
# the next '---'. A response/request body line that merely starts with `unresolved:`
# (e.g. inside a code block) is therefore never mistaken for front-matter.
fm_region() {
  awk 'NR==1{ if($0!="---") exit; next } /^---[[:space:]]*$/{ exit } { print }' "$1" 2>/dev/null
}
# fm_value <file> <key> — scalar value of <key> in the front-matter (first occurrence).
fm_value() { fm_region "$1" | grep -m1 "^$2:" | sed "s/^$2:[[:space:]]*//;s/[[:space:]]*#.*//"; }
# fm_count <file> <key> — how many times <key> appears in the front-matter (for
# duplicate-key rejection; grep -m1 silently hides duplicates otherwise). Uses awk so
# the output is ALWAYS exactly one integer with exit 0 — `grep -c` prints 0 AND exits
# nonzero on no match, which (with a `|| echo 0` fallback) double-prints "0\n0".
fm_count() { fm_region "$1" | awk -v k="$2:" 'index($0,k)==1{n++} END{print n+0}'; }

# thread_root_exists <id> — 0 iff <id> is a real thread ROOT: a PUBLISHED request (or
# archived thread) whose OWN `thread:` is null. Deliberately NARROWER than id_in_use
# (true for drafts/tmp/lone responses) AND than mere existence — requiring `thread: null`
# stops `thread:` from pointing at a mid-thread re-audit id, which would split history.
thread_root_exists() {
  trf=""
  for cand in "$REQUESTS/$1.md" "$ESCALATION/$1.escalation.md" \
              "$ARCHIVE/$1/request.md" "$ARCHIVE/$1/escalation.md"; do
    [ -e "$cand" ] && { trf=$cand; break; }
  done
  [ -n "$trf" ] || return 1
  [ "$(fm_value "$trf" thread)" = "null" ]
}

# unprocessed_ids — list ids of every PUBLISHED request/escalation with no matching
# final response (the file-authoritative "active work" signal; ignores status.json).
# Shared by submit-request's single-active guard.
unprocessed_ids() {
  for f in "$REQUESTS"/*.md "$ESCALATION"/*.escalation.md; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      .gitkeep) continue ;;
      *.escalation.md) i=${b%.escalation.md} ;;
      *.md) i=${b%.md} ;;
      *) continue ;;
    esac
    [ -e "$RESPONSES/$i.response.md" ] && continue
    printf '%s\n' "$i"
  done
}

# validate_response_file <file> — 0 iff <file> satisfies the FULL response contract
# (PROTOCOL §6), not just front-matter presence. Prints a reason to stderr on failure.
# Used by complete-request before publishing AND by watch --response before treating a
# final file as ready — so a partial/hand-written final cannot unblock the wait.
validate_response_file() {
  f=$1; v=""
  [ -f "$f" ] || { echo "missing file" >&2; return 1; }
  [ "$(head -1 "$f" 2>/dev/null)" = "---" ] || { echo "no opening front-matter" >&2; return 1; }
  # closing delimiter must exist (region is non-degenerate)
  awk 'NR==1{next} /^---[[:space:]]*$/{found=1; exit} END{exit !found}' "$f" || { echo "no closing front-matter '---'" >&2; return 1; }
  for k in request_id approval risk review_cycle; do
    c=$(fm_count "$f" "$k")
    [ "$c" -eq 1 ] || v="$v; $k missing or duplicated ($c)"
  done
  case "$(fm_value "$f" approval)" in APPROVED|APPROVED_WITH_CONCERNS|BLOCKED) : ;; *) v="$v; bad/absent approval" ;; esac
  case "$(fm_value "$f" risk)" in low|medium|high) : ;; *) v="$v; bad/absent risk" ;; esac
  case "$(fm_value "$f" review_cycle)" in ''|*[!0-9]*) v="$v; bad/absent review_cycle" ;; esac
  # All four PROTOCOL §6 sections required, including the TRAILING one with non-empty
  # content — since a sanctioned response is written top-to-bottom, the last section's
  # presence makes a partial-final unblock very unlikely (defense in depth, not a proof).
  for h in '## Findings' '## Recommended fixes' '## Risk assessment' '## Approval rationale'; do
    grep -qF "$h" "$f" || v="$v; missing section '$h'"
  done
  rat=$(awk '/^## Approval rationale/{s=1;next} s&&NF{print;exit}' "$f")
  [ -n "$rat" ] || v="$v; '## Approval rationale' is empty"
  [ -z "$v" ] && return 0
  echo "invalid response contract:${v}" >&2
  return 1
}
