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

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

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
