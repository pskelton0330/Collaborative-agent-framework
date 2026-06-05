#!/bin/sh
# Smoke harness for the agent-framework scripts. Self-contained: it copies the
# framework into a throwaway sandbox, drives the helper scripts, and asserts on their
# behaviour. No network; no external deps beyond the POSIX userland the scripts already
# require. jq is NOT required to run the harness — its own state setup is jq-free, and
# the no-jq cases build a jq-free PATH on the fly to exercise the fallback paths.
#
#   sh tests/run-tests.sh          # run all; exit 0 iff every test passed
#
# Designed to run under a STRICT /bin/sh (macOS bash-3.2 and Linux dash), which is the
# whole point — it is the regression net for the BSD/GNU portability traps. The harness
# therefore uses ONLY POSIX features itself (no find -delete/-mindepth/-maxdepth, etc.).
set -u

here=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$here/.." && pwd)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in: $3" ;; esac; }
# refused <label> <needle> <cmd...> — a refusal must BOTH exit nonzero AND print the
# diagnostic. (Substring-only would pass a broken guard that prints the message but
# still succeeds.) Mutation-resistant assertion for the publish/validation guards.
refused() {
  lbl=$1; needle=$2; shift 2
  o=$("$@" 2>&1); r=$?
  if [ "$r" -eq 0 ]; then bad "$lbl" "expected nonzero exit, got 0; out=$o"; return; fi
  case "$o" in *"$needle"*) ok "$lbl" ;; *) bad "$lbl" "rc=$r but missing [$needle]: $o" ;; esac
}

SANDBOX=$(mktemp -d 2>/dev/null || mktemp -d -t aftest)
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
cp -R "$SRC/scripts" "$SRC/templates" "$SANDBOX/"
mkdir -p "$SANDBOX/shared/requests" "$SANDBOX/shared/responses" \
         "$SANDBOX/shared/escalation" "$SANDBOX/shared/archive"
echo "# log" > "$SANDBOX/shared/master-log.md"
FRAMEWORK_DIR="$SANDBOX"; export FRAMEWORK_DIR
SC="$SANDBOX/scripts"
SH="$SANDBOX/shared"
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
[ -n "${AF_DISABLE_JQ:-}" ] && have_jq=0   # honour the same force-fallback switch as the scripts

# --- jq-FREE state management (so the harness runs and sets up cases without jq) ---
write_status() {
  # Use the real pristine seed: it is the canonical ONE-KEY-PER-LINE format the
  # scripts' no-jq json_get and the set_* seds below both depend on (a compacted
  # cycle/limits block would make the grep fallback parse "2 }" instead of "2"). Copying
  # the seed also keeps the harness in sync with the shipped defaults.
  cp "$SRC/shared/status.json" "$SH/status.json"
}
set_num()  { sed 's/"'"$1"'":[[:space:]]*[0-9][0-9]*/"'"$1"'": '"$2"'/' "$SH/status.json" > "$SH/s.x" && mv "$SH/s.x" "$SH/status.json"; }
# NOTE: no `\|` alternation — that is a GNU-sed extension; BSD sed treats it literally.
# After reset_state a bool is always its default, so two literal substitutions suffice.
set_bool() { sed 's/"'"$1"'": true/"'"$1"'": '"$2"'/; s/"'"$1"'": false/"'"$1"'": '"$2"'/' "$SH/status.json" > "$SH/s.x" && mv "$SH/s.x" "$SH/status.json"; }
set_str()  { sed 's/"'"$1"'":[[:space:]]*"[^"]*"/"'"$1"'": "'"$2"'"/' "$SH/status.json" > "$SH/s.x" && mv "$SH/s.x" "$SH/status.json"; }

reset_state() {                       # POSIX-only cleanup (no non-POSIX find predicates)
  for d in requests responses escalation; do
    for f in "$SH/$d"/*; do [ -e "$f" ] && rm -f "$f"; done   # glob skips dotfiles (.gitkeep)
  done
  for d in "$SH/archive"/*; do [ -d "$d" ] && rm -rf "$d"; done
  write_status
}

fill_draft() {
  f=$1
  awk '
    /<Background the reviewer needs/{print "context filled."; skip=1; next}
    skip && /^##/{skip=0}
    skip{next}
    /<Concrete question 1>/{print "1. a real question?"; next}
    /<Concrete question 2>/{next} /<\.\.\.>/{next}
    /<Describe what a good answer/{print "  a good answer."; skip2=1; next}
    skip2 && /^---/{skip2=0; print; next}
    skip2{next}
    {print}
  ' "$f" > "$f.x" && mv "$f.x" "$f"
}

stage_response() {                    # complete, valid response (no progress block)
  id=$1; ap=${2:-APPROVED}; cyc=${3:-1}
  cat > "$SH/responses/$id.response.md.tmp" <<EOF
---
request_id: $id
responded_at: 2026-06-01T00:00:00Z
approval: $ap
risk: low
review_cycle: $cyc
---
## Findings
No issues found.
## Recommended fixes
none
## Risk assessment
low residual risk.
## Approval rationale
fine to proceed.
EOF
}

NOJQ=""
make_nojq() {
  # A PATH with every tool the scripts use EXCEPT jq. Resolve via explicit dir search
  # (NOT `command -v`, which can resolve to a shell alias/function and create a broken
  # symlink); include cp (new-request uses it). This is the no-jq fallback environment.
  NOJQ="$SANDBOX/nojq-bin"; mkdir -p "$NOJQ"
  for t in sh date grep sed awk head tail basename dirname mkdir mv rm cat cp sleep sort tr wc cut expr test; do
    for dir in /bin /usr/bin; do
      [ -x "$dir/$t" ] && { ln -sf "$dir/$t" "$NOJQ/$t"; break; }
    done
  done
}

echo "agent-framework smoke tests  (host jq present: $have_jq)"
echo "sandbox: $SANDBOX"

# =====================================================================================
echo "[1] happy path: new -> submit -> complete -> archive"
reset_state
id=$("$SC/new-request" --type security --files "a.ts,b.ts" 2>/dev/null)
fill_draft "$SH/requests/$id.md.draft"
out=$("$SC/submit-request" "$id" 2>&1); assert_contains "submit publishes" "Published $id" "$out"
[ -e "$SH/requests/$id.md" ] && ok "request file present" || bad "request file present"
if [ "$have_jq" -eq 1 ]; then assert_eq "state=request_pending" request_pending "$(jq -r .state "$SH/status.json")"; fi
stage_response "$id" APPROVED 1
out=$("$SC/complete-request" "$id" 2>&1); assert_contains "complete publishes" "Published response" "$out"
[ -e "$SH/responses/$id.response.md" ] && ok "response published" || bad "response published"
out=$("$SC/archive-request" "$id" 2>&1); assert_contains "archive moves exchange" "Archived $id" "$out"
[ -d "$SH/archive/$id" ] && ok "archive dir present" || bad "archive dir present"
if [ "$have_jq" -eq 1 ]; then assert_eq "state back to idle" idle "$(jq -r .state "$SH/status.json")"; fi

# =====================================================================================
echo "[2] refusals"
reset_state
"$SC/new-request" --type security --id "BADID" >/dev/null 2>&1; assert_eq "bad --id rejected" 2 "$?"
id=$("$SC/new-request" --type security --files "x.ts" 2>/dev/null)
"$SC/submit-request" "$id" >/dev/null 2>&1; assert_eq "incomplete draft rejected" 1 "$?"
reset_state
id=$("$SC/new-request" --type security --files "x.ts" 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"
"$SC/submit-request" "$id" >/dev/null 2>&1
stage_response "$id" APPROVED 9
"$SC/complete-request" "$id" >/dev/null 2>&1; assert_eq "review_cycle mismatch rejected" 1 "$?"
reset_state
echo "junk" > "$SH/responses/REQ-20260601-000000-security.response.md.tmp"
"$SC/complete-request" REQ-20260601-000000-security >/dev/null 2>&1; assert_eq "complete w/o request rejected" 1 "$?"

# =====================================================================================
echo "[3] single-active invariant (file-authoritative)"
reset_state
a=$("$SC/new-request" --type bug-risk --files "x" 2>/dev/null); fill_draft "$SH/requests/$a.md.draft"; "$SC/submit-request" "$a" >/dev/null 2>&1
b=$("$SC/new-request" --type bug-risk --files "y" 2>/dev/null); fill_draft "$SH/requests/$b.md.draft"
refused "2nd publish refused" "single-active" "$SC/submit-request" "$b"
[ -e "$SH/requests/$b.md" ] && bad "2nd request NOT published" "but $b.md exists" || ok "2nd request NOT published"
set_str state idle; set_str active_request null      # drift the cache (jq-free)
refused "refused even when status drifted" "single-active" "$SC/submit-request" "$b"

# =====================================================================================
echo "[4] escalation cap (hard, with and without jq) — setup is jq-free"
reset_state
set_num escalation_level 2; set_num max_escalation_cycles 2
if [ "$have_jq" -eq 1 ]; then
  "$SC/new-request" --type escalation --files "x" >/dev/null 2>&1; assert_eq "escalation cap exit 3 (jq)" 3 "$?"
fi
make_nojq
PATH="$NOJQ" "$SC/new-request" --type escalation --files "x" >/dev/null 2>&1; assert_eq "escalation cap exit 3 (no jq)" 3 "$?"

# =====================================================================================
echo "[5] human_required pause gate (with and without jq) — setup is jq-free"
reset_state
set_bool human_required true
set_num max_idle_seconds 2     # safety: a detection failure times out fast, never hangs
if [ "$have_jq" -eq 1 ]; then
  "$SC/watch" >/dev/null 2>&1; assert_eq "watch paused exit 3 (jq)" 3 "$?"
fi
PATH="$NOJQ" "$SC/watch" >/dev/null 2>&1; assert_eq "watch paused exit 3 (no jq)" 3 "$?"

# =====================================================================================
echo "[6] id-collision: rapid auto ids are unique"
reset_state
i1=$("$SC/new-request" --type bug-risk --files x 2>/dev/null)
i2=$("$SC/new-request" --type bug-risk --files x 2>/dev/null)
i3=$("$SC/new-request" --type bug-risk --files x 2>/dev/null)
u=$(printf '%s\n%s\n%s\n' "$i1" "$i2" "$i3" | sort -u | wc -l | tr -d ' ')
assert_eq "3 rapid auto ids unique" 3 "$u"

# =====================================================================================
echo "[7] thread-root validation (incl. F7 regression cases)"
# A non-root id that merely EXISTS (draft / tmp / lone response) must NOT be accepted
# as a thread root — switching back to id_in_use would reintroduce the bypass.
mkfresh() { reset_state; x=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$x.md.draft"; printf '%s' "$x"; }
point_thread() { sed 's/^thread:.*/thread: '"$2"'/' "$SH/requests/$1.md.draft" > "$SH/requests/$1.md.draft.x" && mv "$SH/requests/$1.md.draft.x" "$SH/requests/$1.md.draft"; }

# nonexistent
d=$(mkfresh); point_thread "$d" REQ-20990101-000000-bug-risk
refused "nonexistent thread root refused" "thread root" "$SC/submit-request" "$d"
# draft-only id
d=$(mkfresh); draftonly=REQ-20990102-000000-bug-risk; printf -- '---\nrequest_id: %s\nthread: null\n---\n' "$draftonly" > "$SH/requests/$draftonly.md.draft"
point_thread "$d" "$draftonly"; refused "draft-only id refused as root" "thread root" "$SC/submit-request" "$d"
# response-tmp-only id
d=$(mkfresh); tmponly=REQ-20990103-000000-bug-risk; printf 'partial\n' > "$SH/responses/$tmponly.response.md.tmp"
point_thread "$d" "$tmponly"; refused "tmp-only id refused as root" "thread root" "$SC/submit-request" "$d"
# lone final-response id (no request)
d=$(mkfresh); loneresp=REQ-20990104-000000-bug-risk; stage_response "$loneresp" APPROVED 1; mv "$SH/responses/$loneresp.response.md.tmp" "$SH/responses/$loneresp.response.md"
point_thread "$d" "$loneresp"; refused "lone response id refused as root" "thread root" "$SC/submit-request" "$d"
# real archived root accepted
reset_state
root=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$root.md.draft"; "$SC/submit-request" "$root" >/dev/null 2>&1; "$SC/archive-request" "$root" >/dev/null 2>&1
d=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$d.md.draft"; point_thread "$d" "$root"
out=$("$SC/submit-request" "$d" 2>&1); assert_contains "archived root accepted" "Published" "$out"

# =====================================================================================
echo "[8] response-readiness validation (validate_response_file)"
reset_state
id=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"; "$SC/submit-request" "$id" >/dev/null 2>&1
cat > "$SH/responses/$id.response.md.tmp" <<EOF
---
request_id: $id
responded_at: 2026-06-01T00:00:00Z
approval: APPROVED
risk: low
review_cycle: 1
---
## Findings
none
## Approval rationale
ok
EOF
refused "missing sections rejected" "Recommended fixes" "$SC/complete-request" "$id"
stage_response "$id" APPROVED 1
sed 's/^risk: low$/risk: low\nrisk: high/' "$SH/responses/$id.response.md.tmp" > "$SH/responses/$id.response.md.tmp.x" && mv "$SH/responses/$id.response.md.tmp.x" "$SH/responses/$id.response.md.tmp"
refused "duplicate key rejected" "duplicated" "$SC/complete-request" "$id"
[ -e "$SH/responses/$id.response.md" ] && bad "invalid response NOT published" "but final exists" || ok "invalid response NOT published"
stage_response "$id" APPROVED 1
"$SC/complete-request" "$id" >/dev/null 2>&1; assert_eq "valid response publishes" 0 "$?"

# =====================================================================================
echo "[9] F6 regression: old-format publish is SILENT + fm_count returns one integer"
reset_state
id=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"; "$SC/submit-request" "$id" >/dev/null 2>&1
stage_response "$id" APPROVED 1                      # old-format, no progress block
err=$("$SC/complete-request" "$id" 2>&1 >/dev/null)  # capture STDERR only
# The F6 bug printed "integer expression expected"; assert specifically THAT is absent.
# (Without jq there is a legitimate "jq not found" notice on stderr, which is fine.)
case "$err" in
  *"integer expression"*) bad "old-format complete: no integer-expr noise (F6)" "stderr: $err" ;;
  *) ok "old-format complete: no integer-expr noise (F6)" ;;
esac
# direct fm_count unit: absent key must be exactly "0" (the F6 double-print bug gave "0\n0")
printf -- '---\nrequest_id: R\napproval: APPROVED\n---\nbody\n' > "$SH/fmcount.md"
cnt=$( . "$SC/_common.sh"; fm_count "$SH/fmcount.md" unresolved )
assert_eq "fm_count absent key = single 0" "0" "$cnt"

# =====================================================================================
echo "[10] progress block: atomic + strict + front-matter-scoped"
reset_state
id=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"; "$SC/submit-request" "$id" >/dev/null 2>&1
mkblock() {
  cat > "$SH/responses/$id.response.md.tmp" <<EOF
---
request_id: $id
responded_at: 2026-06-01T00:00:00Z
approval: APPROVED
risk: low
review_cycle: 1
unresolved:     [$1]
resolved_since: []
new_this_cycle: []
movement: $2
progress_continuity: $3
---
## Findings
n
## Recommended fixes
n
## Risk assessment
l
## Approval rationale
ok
EOF
}
mkblock "F1abc" false unknown; refused "bad id token rejected" "non-id token" "$SC/complete-request" "$id"
mkblock "F1" maybe unknown;    refused "bad movement rejected" "movement" "$SC/complete-request" "$id"
mkblock "F1" false sorta;      refused "bad continuity rejected" "progress_continuity" "$SC/complete-request" "$id"
# partial block (only unresolved present)
cat > "$SH/responses/$id.response.md.tmp" <<EOF
---
request_id: $id
responded_at: 2026-06-01T00:00:00Z
approval: APPROVED
risk: low
review_cycle: 1
unresolved:     [F1]
---
## Findings
n
## Recommended fixes
n
## Risk assessment
l
## Approval rationale
ok
EOF
refused "partial block rejected" "partial" "$SC/complete-request" "$id"
# valid full block publishes (still on the same un-published id)
mkblock "F1" false ok; "$SC/complete-request" "$id" >/dev/null 2>&1; assert_eq "valid block publishes" 0 "$?"
# front-matter scoping: a BODY line starting `unresolved:` must NOT be read as a block.
# Fresh request id (the one above is now published).
reset_state
id2=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$id2.md.draft"; "$SC/submit-request" "$id2" >/dev/null 2>&1
cat > "$SH/responses/$id2.response.md.tmp" <<EOF
---
request_id: $id2
responded_at: 2026-06-01T00:00:00Z
approval: APPROVED
risk: low
review_cycle: 1
---
## Findings
The code path \`unresolved:\` and a line
movement: here in the body must be ignored.
## Recommended fixes
n
## Risk assessment
l
## Approval rationale
ok
EOF
"$SC/complete-request" "$id2" >/dev/null 2>&1; assert_eq "body 'unresolved:'/'movement:' ignored (publishes)" 0 "$?"

# =====================================================================================
echo "[11] watch --response readiness gating (F8)"
reset_state
set_num idle_poll_seconds 1; set_num max_idle_seconds 2
want=REQ-20260601-200000-bug-risk
printf -- '---\nrequest_id: %s\nreview_cycle: 1\nthread: null\n---\n' "$want" > "$SH/requests/$want.md"
# partial final (front-matter only) must NOT unblock -> times out exit 2
printf -- '---\nrequest_id: %s\napproval: APPROVED\nrisk: low\nreview_cycle: 1\n' "$want" > "$SH/responses/$want.response.md"
"$SC/watch" --response "$want" >/dev/null 2>&1; assert_eq "partial final times out" 2 "$?"
# valid but WRONG embedded request_id must NOT unblock -> times out
stage_response REQ-20260601-299999-bug-risk APPROVED 1; mv "$SH/responses/REQ-20260601-299999-bug-risk.response.md.tmp" "$SH/responses/$want.response.md"
"$SC/watch" --response "$want" >/dev/null 2>&1; assert_eq "wrong embedded request_id times out" 2 "$?"
# valid matching final -> unblocks exit 0 and prints the id
stage_response "$want" APPROVED 1; mv "$SH/responses/$want.response.md.tmp" "$SH/responses/$want.response.md"
out=$("$SC/watch" --response "$want" 2>/dev/null); rc=$?
assert_eq "valid matching final unblocks (exit)" 0 "$rc"
assert_eq "valid matching final unblocks (id)" "$want" "$out"

# =====================================================================================
echo "[11b] watch --max-idle per-call override (chunked waits)"
reset_state
set_num idle_poll_seconds 1; set_num max_idle_seconds 60
want=REQ-20260601-210000-bug-risk
printf -- '---\nrequest_id: %s\nreview_cycle: 1\nthread: null\n---\n' "$want" > "$SH/requests/$want.md"
# the override shortens THIS call: exit 2 in ~1s, not status.json's 60s
t0=$(date +%s)
"$SC/watch" --response "$want" --max-idle 1 >/dev/null 2>&1; rc=$?
t1=$(date +%s); el=$((t1 - t0))
assert_eq "--max-idle 1 times out (exit 2)" 2 "$rc"
if [ "$el" -le 15 ]; then ok "--max-idle overrides 60s limit (${el}s)"; else bad "--max-idle override ignored" "took ${el}s (status limit was 60s)"; fi
# poll interval is clamped to the deadline: interval 8 with --max-idle 1 must not
# sleep a full 8s chunk before noticing the deadline
set_num idle_poll_seconds 8
t0=$(date +%s)
"$SC/watch" --response "$want" --max-idle 1 >/dev/null 2>&1; rc=$?
t1=$(date +%s); el=$((t1 - t0))
assert_eq "clamped interval still exits 2" 2 "$rc"
if [ "$el" -le 5 ]; then ok "interval clamped to deadline (${el}s)"; else bad "interval not clamped" "took ${el}s (unclamped sleep would be 8s)"; fi
# a ready response still unblocks immediately under a short --max-idle
stage_response "$want" APPROVED 1; mv "$SH/responses/$want.response.md.tmp" "$SH/responses/$want.response.md"
out=$("$SC/watch" --response "$want" --max-idle 1 2>/dev/null); rc=$?
assert_eq "ready response unblocks under --max-idle (exit)" 0 "$rc"
assert_eq "ready response unblocks under --max-idle (id)" "$want" "$out"
# bad values are refused with a diagnostic
refused "--max-idle rejects non-numeric" "positive integer" "$SC/watch" --max-idle abc
refused "--max-idle rejects 0" "positive integer" "$SC/watch" --max-idle 0

# =====================================================================================
echo "[12] check-progress verdicts"
reset_state
R=REQ-20260601-100001-bug-risk; C=REQ-20260601-100002-bug-risk
mkreq() { printf -- '---\nrequest_id: %s\nreview_cycle: %s\nthread: %s\n---\nx\n' "$1" "$2" "$3" > "$SH/requests/$1.md"; }
mkresp() {
  cat > "$SH/responses/$1.response.md" <<EOF
---
request_id: $1
responded_at: 2026-06-01T00:00:00Z
approval: $3
risk: low
review_cycle: $2
unresolved:     [$4]
resolved_since: [$5]
new_this_cycle: [$6]
movement: true
progress_continuity: $7
---
## Findings
x
## Recommended fixes
x
## Risk assessment
x
## Approval rationale
x
EOF
}
cpv() { "$SC/check-progress" "$R" 2>/dev/null; }
mkreq $R 1 null; mkresp $R 1 BLOCKED "F1, F2, F3" "" "F1, F2, F3" ok
mkreq $C 2 $R;   mkresp $C 2 APPROVED_WITH_CONCERNS "F1" "F2, F3" "" ok
# Degradation: the overlay needs jq; without it check-progress returns insufficient-data
# (so the count guard governs). Verify that explicitly, regardless of host jq.
make_nojq
assert_eq "no-jq -> insufficient-data (overlay off)" insufficient-data "$(PATH="$NOJQ" "$SC/check-progress" "$R" 2>/dev/null)"
# The actual verdict logic requires jq; guard it so the harness is jq-optional.
if [ "$have_jq" -eq 1 ]; then
  assert_eq "productive (count down)" productive "$(cpv)"
  mkresp $R 1 BLOCKED "F1" "" "F1" ok; mkresp $C 2 BLOCKED "F1" "" "" ok
  assert_eq "impasse (stalled same set)" impasse "$(cpv)"
  mkresp $C 2 BLOCKED "F2" "F1" "F2" ok
  assert_eq "swap-churn -> impasse" impasse "$(cpv)"
  mkresp $C 2 BLOCKED "F2" "" "" ok
  assert_eq "unexplained churn -> insufficient-data" insufficient-data "$(cpv)"
  mkresp $C 2 BLOCKED "F1" "" "" unknown
  assert_eq "continuity unknown -> insufficient-data" insufficient-data "$(cpv)"
  mkresp $R 1 BLOCKED "F1" "" "F1" ok; mkresp $C 2 APPROVED_WITH_CONCERNS "F1" "" "" ok
  assert_eq "approval improved -> productive" productive "$(cpv)"
  rm -f "$SH/responses/$C.response.md" "$SH/requests/$C.md"
  assert_eq "single response -> insufficient-data" insufficient-data "$(cpv)"
else
  printf '  ..   check-progress verdict tests skipped (no jq on host)\n'
fi

# =====================================================================================
echo "[13] reopen-archived blocked"
reset_state
id=$("$SC/new-request" --type security --files a 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"; "$SC/submit-request" "$id" >/dev/null 2>&1
stage_response "$id" APPROVED 1; "$SC/complete-request" "$id" >/dev/null 2>&1; "$SC/archive-request" "$id" >/dev/null 2>&1
"$SC/new-request" --type security --id "$id" >/dev/null 2>&1; assert_eq "cannot reopen archived id" 1 "$?"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
