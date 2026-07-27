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
  # Copy the committed PRISTINE seed (status.seed.json — the live status.json is now
  # gitignored runtime). It is the canonical ONE-KEY-PER-LINE format the scripts' no-jq
  # json_get and the set_* seds below both depend on (a compacted cycle/limits block
  # would make the grep fallback parse "2 }" instead of "2"), and it keeps the harness
  # in sync with the shipped defaults.
  cp "$SRC/shared/status.seed.json" "$SH/status.json"
  # Defense-in-depth: normalize the volatile runtime fields to defaults so the suite's
  # outcome never depends on a stray edit to the seed. (set_* are defined just below;
  # sh resolves them at call time, and reset_state calls this later.)
  set_num review_cycles 0; set_num retry_count 0; set_num escalation_level 0
  set_bool human_required false
  set_str state idle; set_str owner primary; set_str updated_by system
  sed 's/"active_request":[[:space:]]*"[^"]*"/"active_request": null/; s/"task_label":[[:space:]]*"[^"]*"/"task_label": null/' \
    "$SH/status.json" > "$SH/s.x" && mv "$SH/s.x" "$SH/status.json"
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
# bad values are refused with a diagnostic. Leading zeros matter: 08/09 would
# pass a naive digit check and then crash $(( )) as invalid octal once the
# interval clamp copies them into INTERVAL; 00 is a zero timeout in disguise.
refused "--max-idle rejects non-numeric" "positive integer" "$SC/watch" --max-idle abc
refused "--max-idle rejects 0" "positive integer" "$SC/watch" --max-idle 0
refused "--max-idle rejects 00" "positive integer" "$SC/watch" --max-idle 00
refused "--max-idle rejects leading zero (octal trap)" "positive integer" "$SC/watch" --max-idle 08
refused "--max-idle rejects out-of-range (>7 digits)" "positive integer" "$SC/watch" --max-idle 999999999999999999999

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
  # v1.2 verdict split: rank-only improvement continues under the soft ceiling but
  # must never extend past it (rank can oscillate; only a strict count decrease is
  # well-founded), so it gets its own verdict.
  mkresp $R 1 BLOCKED "F1" "" "F1" ok; mkresp $C 2 APPROVED_WITH_CONCERNS "F1" "" "" ok
  assert_eq "rank up, count flat -> productive-rank-only" productive-rank-only "$(cpv)"
  # strict count decrease wins even if the approval rank got WORSE (well-founded
  # metric governs extension eligibility)
  mkresp $R 1 APPROVED_WITH_CONCERNS "F1, F2" "" "F1, F2" ok; mkresp $C 2 BLOCKED "F1" "F2" "" ok
  assert_eq "count down, rank down -> productive" productive "$(cpv)"
  # count down AND rank up is plain productive (count checked first)
  mkresp $R 1 BLOCKED "F1, F2" "" "F1, F2" ok; mkresp $C 2 APPROVED_WITH_CONCERNS "F1" "F2" "" ok
  assert_eq "count down, rank up -> productive" productive "$(cpv)"
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

# =====================================================================================
echo "[14] collaborative planning (Phase 1, commit-reveal)"
rm -rf "$SH/plans"
pid=$("$SC/plan" new "test plan" 2>/dev/null)
assert_contains "plan new mints a PLAN id" "PLAN-" "$pid"
pd="$SH/plans/$pid"
assert_eq "plan new scaffolds problem.md" 1 "$([ -f "$pd/problem.md" ] && echo 1 || echo 0)"
# seal refuses before a filled primary draft exists
"$SC/plan" seal "$pid" >/dev/null 2>&1; assert_eq "seal refuses unfilled primary draft" 1 "$?"
cat > "$pd/primary-draft.md" <<EOF
---
plan_id: $pid
author: primary
drafted_at: 2026-06-11T00:00:00Z
verdict: READY_TO_BUILD
---
## Approach
Do A.
## Key risks
None.
## Open questions
None.
EOF
# blindness: a Secondary draft present BEFORE the seal must be refused
printf 'x\n' > "$pd/secondary-draft.md.tmp"
refused "seal refuses when Secondary drafted first (blindness)" "blindness" "$SC/plan" seal "$pid"
rm -f "$pd/secondary-draft.md.tmp"
"$SC/plan" seal "$pid" >/dev/null 2>&1; assert_eq "seal succeeds with a blind primary draft" 0 "$?"
assert_eq "seal records .sealed" 1 "$([ -f "$pd/.sealed" ] && echo 1 || echo 0)"
# submit refuses a bad verdict, then accepts a valid one
cat > "$pd/secondary-draft.md.tmp" <<EOF
---
plan_id: $pid
author: secondary
drafted_at: 2026-06-11T00:00:01Z
verdict: MAYBE
---
## Approach
Do B.
## Key risks
None.
## Open questions
None.
EOF
refused "submit refuses a bad verdict" "verdict must be" "$SC/plan" submit "$pid"
sed 's/verdict: MAYBE/verdict: NEEDS_WORK/' "$pd/secondary-draft.md.tmp" > "$pd/s.x" && mv "$pd/s.x" "$pd/secondary-draft.md.tmp"
"$SC/plan" submit "$pid" >/dev/null 2>&1; assert_eq "submit publishes the Secondary draft" 0 "$?"
assert_eq "Secondary draft published" 1 "$([ -f "$pd/secondary-draft.md" ] && echo 1 || echo 0)"
"$SC/plan" reveal "$pid" >/dev/null 2>&1; assert_eq "reveal ok after submit" 0 "$?"
"$SC/plan" synthesize "$pid" >/dev/null 2>&1; assert_eq "synthesize scaffolds plan.md" 0 "$?"
# archive refuses while plan.md is still the unfilled scaffold
"$SC/plan" archive "$pid" >/dev/null 2>&1; assert_eq "archive refuses an unfilled plan" 1 "$?"
cat > "$pd/plan.md" <<EOF
---
plan_id: $pid
synthesized_at: 2026-06-11T00:00:02Z
final_verdict: READY_TO_BUILD
contribution: added_value
models: primary=a secondary=b
---
## Plan (the rubric for later review)
A then B.
## High-confidence (both drafts independently agreed)
A.
## Flagged decisions (the drafts diverged)
B.
## Contribution signal (what the Secondary's independent draft added)
- net_new_options: B
- caught_risks: none
- verdict: added_value
EOF
"$SC/plan" archive "$pid" >/dev/null 2>&1; assert_eq "archive moves a filled plan" 0 "$?"
assert_eq "plan archived" 1 "$([ -d "$SH/plans/archive/$pid" ] && echo 1 || echo 0)"
# filled() must ignore back-ticked angle-bracket prose (regression for the <id>
# false positive; this draft has a back-ticked `PLAN <id>` but no real placeholder)
bpid=$("$SC/plan" new "backtick filled regression" 2>/dev/null); bpd="$SH/plans/$bpid"
cat > "$bpd/primary-draft.md" <<'EOF'
---
plan_id: PLAN-00000000-000000
author: primary
drafted_at: 2026-06-11T00:00:00Z
verdict: READY_TO_BUILD
---
## Approach
The watcher prints a line like `PLAN <id>` for routing.
## Key risks
None.
## Open questions
None.
EOF
"$SC/plan" seal "$bpid" >/dev/null 2>&1; assert_eq "seal accepts back-ticked <id> prose (filled fix)" 0 "$?"

# =====================================================================================
echo "[15] persistent headless secondary (secondary-loop + transcript)"
# A stub 'secondary agent' that writes a valid response + publishes it (no real LLM).
# Quoted heredoc: it resolves paths from $FRAMEWORK_DIR at run time (exported by the harness).
stub="$SANDBOX/stub-secondary"
cat > "$stub" <<'STUB'
#!/bin/sh
id=$1; sh="$FRAMEWORK_DIR/shared"; sc="$FRAMEWORK_DIR/scripts"
{
  echo '---'; echo "request_id: $id"; echo 'responded_at: 2026-06-11T00:00:00Z'
  echo 'approval: APPROVED'; echo 'risk: low'; echo 'review_cycle: 1'
  echo 'unresolved: []'; echo 'resolved_since: []'; echo 'new_this_cycle: []'
  echo 'movement: false'; echo 'progress_continuity: unknown'; echo '---'
  echo '## Findings'; echo 'stub: none.'; echo '## Recommended fixes'; echo 'none.'
  echo '## Risk assessment'; echo 'low.'; echo '## Approval rationale'; echo 'stub approval.'
} > "$sh/responses/$id.response.md.tmp"
"$sc/complete-request" "$id" >/dev/null 2>&1
STUB
chmod +x "$stub"

reset_state; rm -f "$SH/conversation.md"
hid=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hid.md.draft"; "$SC/submit-request" "$hid" >/dev/null 2>&1
SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; rc=$?
assert_eq "secondary-loop --once handled a request (exit 0)" 0 "$rc"
assert_eq "headless secondary published a response" 1 "$([ -f "$SH/responses/$hid.response.md" ] && echo 1 || echo 0)"
assert_eq "conversation transcript captured the exchange" 1 "$([ -f "$SH/conversation.md" ] && grep -q "$hid" "$SH/conversation.md" && echo 1 || echo 0)"

# Default idle window is decoupled from (capped at 120s below) max_idle_seconds, so a
# graceful stop is noticed promptly even though the Primary's patience budget is 900s.
# A request is pending, so watch returns at once (fast test); we assert the startup line
# reports the capped 120s window rather than inheriting 900s.
reset_state
hidc=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hidc.md.draft"; "$SC/submit-request" "$hidc" >/dev/null 2>&1
out=$(SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once 2>&1); rc=$?
assert_eq "secondary-loop default (no --idle) handles a request" 0 "$rc"
assert_eq "default idle window capped at 120s (decoupled from max_idle=900)" 1 "$(printf '%s' "$out" | grep -qF 'idle window 120s' && echo 1 || echo 0)"

reset_state
SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "secondary-loop --once idle exits 0" 0 "$?"

reset_state
hid2=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hid2.md.draft"; "$SC/submit-request" "$hid2" >/dev/null 2>&1
set_bool human_required true
SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "secondary-loop exits 3 when paused" 3 "$?"

# a child that publishes nothing must NOT look successful (F2): --once exits nonzero,
# and no transcript entry is written for the failed review.
failstub="$SANDBOX/fail-secondary"; printf '#!/bin/sh\nexit 0\n' > "$failstub"; chmod +x "$failstub"
reset_state
hid3=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hid3.md.draft"; "$SC/submit-request" "$hid3" >/dev/null 2>&1
SECONDARY_AGENT_CMD="$failstub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "secondary-loop exits nonzero when no response is published" 1 "$?"
assert_eq "no transcript entry for a failed review" 0 "$([ -f "$SH/conversation.md" ] && grep -q "$hid3" "$SH/conversation.md" && echo 1 || echo 0)"
# option operand validation (F4)
"$SC/secondary-loop" --provider >/dev/null 2>&1; assert_eq "secondary-loop --provider with no value exits 2" 2 "$?"
# --idle must be a positive integer, rejected BEFORE reaching watch (F5)
"$SC/secondary-loop" --idle abc --once >/dev/null 2>&1; assert_eq "secondary-loop --idle abc exits 2 (not treated as idle)" 2 "$?"

# validate-on-accept: an agent that writes an INVALID final response directly (bypassing
# complete-request, or via prompt injection) must NOT be accepted as a completed review —
# and the garbage file is discarded so it can't masquerade as "processed" and block retries.
badstub="$SANDBOX/bad-secondary"
printf '#!/bin/sh\nprintf "garbage, not a valid response\\n" > "$FRAMEWORK_DIR/shared/responses/$1.response.md"\n' > "$badstub"; chmod +x "$badstub"
reset_state; rm -f "$SH/conversation.md"
bid=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$bid.md.draft"; "$SC/submit-request" "$bid" >/dev/null 2>&1
SECONDARY_AGENT_CMD="$badstub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "invalid direct-written response NOT accepted (exit 1)" 1 "$?"
assert_eq "invalid response discarded (won't block the queue)" 0 "$([ -f "$SH/responses/$bid.response.md" ] && echo 1 || echo 0)"
assert_eq "no transcript entry for an invalid response" 0 "$([ -f "$SH/conversation.md" ] && grep -q "$bid" "$SH/conversation.md" && echo 1 || echo 0)"
# a structurally-VALID response but for the WRONG request_id is also rejected + discarded
wrongstub="$SANDBOX/wrongid-secondary"
cat > "$wrongstub" <<'WS'
#!/bin/sh
{ echo ---; echo "request_id: REQ-20200101-000000-bug-risk"; echo "responded_at: 2026-01-01T00:00:00Z"
  echo "approval: APPROVED"; echo "risk: low"; echo "review_cycle: 1"; echo ---
  echo "## Findings"; echo x; echo "## Recommended fixes"; echo x
  echo "## Risk assessment"; echo x; echo "## Approval rationale"; echo x; } > "$FRAMEWORK_DIR/shared/responses/$1.response.md"
WS
chmod +x "$wrongstub"
reset_state
wid=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$wid.md.draft"; "$SC/submit-request" "$wid" >/dev/null 2>&1
SECONDARY_AGENT_CMD="$wrongstub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "wrong-request_id response rejected (exit 1)" 1 "$?"
assert_eq "wrong-id response discarded" 0 "$([ -f "$SH/responses/$wid.response.md" ] && echo 1 || echo 0)"

# =====================================================================================
echo "[16] init-from-seed (fresh clone bootstraps live runtime files from committed seeds)"
reset_state
cp "$SRC/shared/status.seed.json" "$SH/status.seed.json"
cp "$SRC/shared/master-log.seed.md" "$SH/master-log.seed.md"
rm -f "$SH/status.json" "$SH/master-log.md"     # simulate a fresh clone: live files absent
"$SC/status" >/dev/null 2>&1 || true            # any script sources _common.sh, which seeds them
assert_eq "status.json bootstrapped from seed"      1 "$([ -f "$SH/status.json" ] && echo 1 || echo 0)"
assert_eq "master-log.md bootstrapped from seed"    1 "$([ -f "$SH/master-log.md" ] && echo 1 || echo 0)"
assert_eq "bootstrapped status matches the seed"    1 "$(diff -q "$SH/status.json" "$SH/status.seed.json" >/dev/null 2>&1 && echo 1 || echo 0)"
assert_eq "no leftover .tmp from atomic seeding"    0 "$(ls "$SH"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
# absent live file AND seed (broken install) degrades silently: a real entry point
# still runs off json_get defaults rather than crashing.
reset_state; rm -f "$SH/status.json" "$SH/status.seed.json"
"$SC/new-request" --type bug-risk --files x >/dev/null 2>&1
assert_eq "no live file + no seed degrades gracefully (new-request works off defaults)" 0 "$?"

# =====================================================================================
echo "[17] archival-hygiene sweep (archive-resolved / resolved_unarchived_ids / doctor)"
# set state=idle + active_request=null (JSON null) WITHOUT wiping request/response files
set_idle() { sed 's/"state":[[:space:]]*"[^"]*"/"state": "idle"/; s/"active_request":[[:space:]]*"[^"]*"/"active_request": null/' "$SH/status.json" > "$SH/s.x" && mv "$SH/s.x" "$SH/status.json"; }
# mkresolved <id> [approval] — a published request + published response, left un-archived
mkresolved() {
  "$SC/new-request" --type bug-risk --id "$1" --files a >/dev/null 2>&1
  fill_draft "$SH/requests/$1.md.draft"
  "$SC/submit-request" "$1" >/dev/null 2>&1
  stage_response "$1" "${2:-APPROVED}" 1
  "$SC/complete-request" "$1" >/dev/null 2>&1
}
reset_state
mkresolved REQ-20990201-000000-bug-risk
mkresolved REQ-20990202-000000-bug-risk
set_idle

# doctor counts the backlog (independent of jq — grep fallback works)
assert_contains "doctor warns on un-archived backlog" "2 resolved exchange(s)" "$("$SC/doctor" 2>&1)"
# F6: extra/unknown arg is rejected (not silently ignored)
"$SC/archive-resolved" --dry-run junk >/dev/null 2>&1; assert_eq "archive-resolved rejects extra arg (F6)" 2 "$?"
# no-jq: the sweep refuses (its idle assertion needs reliable parsing)
AF_DISABLE_JQ=1 "$SC/archive-resolved" --dry-run >/dev/null 2>&1; assert_eq "archive-resolved refuses without jq" 4 "$?"

if [ "$have_jq" -eq 1 ]; then
  # happy path: idle + resolved backlog → dry-run lists both, then real sweep archives them
  assert_contains "dry-run lists the backlog" "Would archive 2" "$("$SC/archive-resolved" --dry-run 2>&1)"
  # F5: a partial status (missing keys) must fail the strict idle-tuple predicate
  printf '{"state":"idle"}' > "$SH/status.json"
  refused "partial status refused (F5)" "not a clean idle tuple" "$SC/archive-resolved" --dry-run
  set_idle 2>/dev/null || true
  # rebuild a clean idle status (seed) but keep the resolved files
  cp "$SRC/shared/status.seed.json" "$SH/status.json"; set_idle
  # F5: an outstanding unprocessed request (stale idle) must refuse
  "$SC/new-request" --type bug-risk --id REQ-20990203-000000-bug-risk --files a >/dev/null 2>&1
  fill_draft "$SH/requests/REQ-20990203-000000-bug-risk.md.draft"
  "$SC/submit-request" REQ-20990203-000000-bug-risk >/dev/null 2>&1
  set_idle   # status says idle but the request above is unprocessed
  refused "stale-idle w/ unprocessed refused (F5)" "unprocessed request" "$SC/archive-resolved" --dry-run
  # resolve it, back to clean idle, then the REAL sweep archives all resolved ids
  stage_response REQ-20990203-000000-bug-risk APPROVED 1; "$SC/complete-request" REQ-20990203-000000-bug-risk >/dev/null 2>&1
  set_idle
  # snapshot live artifact BYTES before the sweep, to prove the archive preserves them exactly
  for aid in REQ-20990201-000000-bug-risk REQ-20990202-000000-bug-risk REQ-20990203-000000-bug-risk; do
    cp "$SH/requests/$aid.md" "$SANDBOX/snap.$aid.req"; cp "$SH/responses/$aid.response.md" "$SANDBOX/snap.$aid.resp"
  done
  "$SC/archive-resolved" >/dev/null 2>&1; assert_eq "sweep exits 0 when idle" 0 "$?"
  n=0; for d in "$SH/archive"/REQ-2099020*; do [ -d "$d" ] && n=$((n+1)); done
  assert_eq "sweep archived all 3 resolved exchanges" 3 "$n"
  # content-preservation: each archive holds the BYTE-IDENTICAL request+response; live gone
  intact=1
  for aid in REQ-20990201-000000-bug-risk REQ-20990202-000000-bug-risk REQ-20990203-000000-bug-risk; do
    cmp -s "$SH/archive/$aid/request.md"  "$SANDBOX/snap.$aid.req"  || intact=0
    cmp -s "$SH/archive/$aid/response.md" "$SANDBOX/snap.$aid.resp" || intact=0
    [ -e "$SH/requests/$aid.md" ] && intact=0
    [ -e "$SH/responses/$aid.response.md" ] && intact=0
  done
  assert_eq "archives are byte-identical to originals; live pairs removed" 1 "$intact"
  "$SC/doctor" >/dev/null 2>&1; assert_eq "doctor exits 0 after sweep" 0 "$?"
  assert_eq "no backlog warning after sweep" 0 "$("$SC/doctor" 2>&1 | grep -c 'resolved exchange(s) not archived')"
  # F5: refuse while a thread is in flight (active_request set, response_ready) — and prove
  # the REAL (non-dry-run) refusal mutates NOTHING (a guard that prints but still moves fails).
  reset_state
  id=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$id.md.draft"; "$SC/submit-request" "$id" >/dev/null 2>&1
  stage_response "$id" APPROVED 1; "$SC/complete-request" "$id" >/dev/null 2>&1   # active_request=$id, response_ready
  refused "in-flight thread refused (F5)" "not a clean idle tuple" "$SC/archive-resolved" --dry-run
  "$SC/archive-resolved" >/dev/null 2>&1; rc=$?
  assert_eq "in-flight: real sweep refused (nonzero)" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "in-flight: response NOT moved by refusal" 1 "$([ -f "$SH/responses/$id.response.md" ] && echo 1 || echo 0)"
  assert_eq "in-flight: no archive created by refusal" 0 "$([ -d "$SH/archive/$id" ] && echo 1 || echo 0)"
  # F5: paused system — the REAL (non-dry-run) sweep must refuse AND mutate nothing.
  reset_state; mkresolved REQ-20990301-000000-bug-risk; set_idle; set_bool human_required true
  "$SC/archive-resolved" >/dev/null 2>&1; prc=$?
  assert_eq "paused: real sweep refused (nonzero)"       1 "$([ "$prc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "paused: response NOT moved by refusal"      1 "$([ -f "$SH/responses/REQ-20990301-000000-bug-risk.response.md" ] && echo 1 || echo 0)"
  assert_eq "paused: no archive created by refusal"      0 "$([ -d "$SH/archive/REQ-20990301-000000-bug-risk" ] && echo 1 || echo 0)"
fi

# =====================================================================================
echo "[18] secondary-loop conversation.md rotation"
reset_state
rm -f "$SH/conversation.md" "$SH/conversation.md.1" "$SH/conv.orig"
awk 'BEGIN{for(i=0;i<40;i++) print "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' > "$SH/conversation.md"  # ~2KB
cp "$SH/conversation.md" "$SH/conv.orig"                              # snapshot original bytes
# F1 regression: a human-paused system must NOT rotate (no automation while paused).
set_bool human_required true
AF_CONV_MAX_KB=1 "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "paused system does NOT rotate (F1)"        0 "$([ -f "$SH/conversation.md.1" ] && echo 1 || echo 0)"
assert_eq "paused: live conversation.md untouched"    0 "$(cmp -s "$SH/conversation.md" "$SH/conv.orig" && echo 0 || echo 1)"
# unpaused + over cap: rotates, and .1 holds the ORIGINAL bytes, live file is gone.
set_bool human_required false; set_str state idle
AF_CONV_MAX_KB=1 "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "over-cap rotated to .1"                    1 "$([ -f "$SH/conversation.md.1" ] && echo 1 || echo 0)"
assert_eq ".1 preserves the original bytes"           0 "$(cmp -s "$SH/conversation.md.1" "$SH/conv.orig" && echo 0 || echo 1)"
assert_eq "live conversation.md moved away"           0 "$([ -f "$SH/conversation.md" ] && echo 1 || echo 0)"
# under-cap: not rotated, live file byte-for-byte intact.
rm -f "$SH/conversation.md" "$SH/conversation.md.1" "$SH/conv.orig"
printf 'tiny\n' > "$SH/conversation.md"; cp "$SH/conversation.md" "$SH/conv.orig"
AF_CONV_MAX_KB=512 "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "under-cap not rotated"                     0 "$([ -f "$SH/conversation.md.1" ] && echo 1 || echo 0)"
assert_eq "under-cap live file unchanged"             0 "$(cmp -s "$SH/conversation.md" "$SH/conv.orig" && echo 0 || echo 1)"
# rotation FAILURE must WARN but NOT abort the watcher (regression: maybe_rotate_conv returns
# 1, and a bare call under set -e would kill the loop). Force failure: .1 is a non-regular file.
rm -f "$SH/conversation.md" "$SH/conversation.md.1"
awk 'BEGIN{for(i=0;i<40;i++) print "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"}' > "$SH/conversation.md"  # >1 KiB
mkdir -p "$SH/conversation.md.1/blocker"              # .1 is a directory → rotation cannot mv into it
AF_CONV_MAX_KB=1 "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "rotation failure warns but does NOT abort the watcher (exit 0)" 0 "$?"
rm -rf "$SH/conversation.md.1"
# F4 integration: a real review whose transcript APPEND crosses the cap must rotate. Starts
# UNDER cap (so startup rotation does not fire), then the stub's published response triggers
# append_transcript, which crosses 1 KiB and drives the in-loop rotation. Removing the
# per-append maybe_rotate_conv call makes this FAIL (that call is the thing under test).
reset_state; rm -f "$SH/conversation.md" "$SH/conversation.md.1"
head -c 1000 /dev/zero | tr '\0' y > "$SH/conversation.md"          # 1000 B < 1 KiB at startup
hidr=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hidr.md.draft"; "$SC/submit-request" "$hidr" >/dev/null 2>&1
AF_CONV_MAX_KB=1 SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "per-append rotation fires when a review crosses the cap (F4)" 1 "$([ -f "$SH/conversation.md.1" ] && echo 1 || echo 0)"
# F1 integration: a stub that PAUSES the system mid-review must leave the transcript/log
# unmutated for that review (post-agent pause re-check).
reset_state; rm -f "$SH/conversation.md"
pausestub="$SANDBOX/pause-secondary"
cat > "$pausestub" <<'PS'
#!/bin/sh
id=$1; sh="$FRAMEWORK_DIR/shared"; sc="$FRAMEWORK_DIR/scripts"
{ echo '---'; echo "request_id: $id"; echo 'responded_at: 2026-06-11T00:00:00Z'
  echo 'approval: APPROVED'; echo 'risk: low'; echo 'review_cycle: 1'
  echo 'unresolved: []'; echo 'resolved_since: []'; echo 'new_this_cycle: []'
  echo 'movement: false'; echo 'progress_continuity: unknown'; echo '---'
  echo '## Findings'; echo 'x'; echo '## Recommended fixes'; echo 'x'
  echo '## Risk assessment'; echo 'x'; echo '## Approval rationale'; echo 'x'
} > "$sh/responses/$id.response.md.tmp"
"$sc/complete-request" "$id" >/dev/null 2>&1
sed 's/"human_required": false/"human_required": true/' "$sh/status.json" > "$sh/s.x" && mv "$sh/s.x" "$sh/status.json"
PS
chmod +x "$pausestub"
hidp=$("$SC/new-request" --type bug-risk --files a 2>/dev/null); fill_draft "$SH/requests/$hidp.md.draft"; "$SC/submit-request" "$hidp" >/dev/null 2>&1
SECONDARY_AGENT_CMD="$pausestub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1
assert_eq "pause established mid-review → no transcript entry (F1)" 0 "$([ -f "$SH/conversation.md" ] && grep -q "$hidp" "$SH/conversation.md" && echo 1 || echo 0)"

# =====================================================================================
echo "[19] concurrent sessions: AF_STATE_DIR isolation + single-watcher lock"
reset_state   # clear any leftover master requests so the "untouched" assertion is meaningful
# seeds must exist in the framework's shared/ for a fresh AF_STATE_DIR to bootstrap from
cp "$SRC/shared/status.seed.json" "$SH/status.seed.json"
cp "$SRC/shared/master-log.seed.md" "$SH/master-log.seed.md"
rm -rf "$SH/runs"; A="$SH/runs/sessA"; B="$SH/runs/sessB"
# a fresh AF_STATE_DIR bootstraps its OWN layout + seeded status.json (from the framework seed)
AF_STATE_DIR="$A" "$SC/doctor" >/dev/null 2>&1
assert_eq "fresh AF_STATE_DIR created its own status.json" 1 "$([ -f "$A/status.json" ] && echo 1 || echo 0)"
assert_eq "fresh AF_STATE_DIR created requests/ layout"    1 "$([ -d "$A/requests" ] && echo 1 || echo 0)"
# two sessions create requests independently; neither sees the other; master shared/ untouched
ra=$(AF_STATE_DIR="$A" "$SC/new-request" --type bug-risk --files a 2>/dev/null)
rb=$(AF_STATE_DIR="$B" "$SC/new-request" --type security  --files b 2>/dev/null)
assert_eq "session A holds only its own request" 1 "$([ -f "$A/requests/$ra.md.draft" ] && [ ! -e "$B/requests/$ra.md.draft" ] && echo 1 || echo 0)"
assert_eq "session B holds only its own request" 1 "$([ -f "$B/requests/$rb.md.draft" ] && [ ! -e "$A/requests/$rb.md.draft" ] && echo 1 || echo 0)"
assert_eq "master shared/ untouched by isolated sessions" 0 "$(ls "$SH"/requests/REQ-* 2>/dev/null | wc -l | tr -d ' ')"
# single-watcher lock is an atomic mkdir of a DIRECTORY ($SHARED/.watcher.lock) holding the
# owner pid. A LIVE owner makes a second watcher refuse (exit 5, before the blocking loop —
# so a foreground call returns deterministically).
mkdir -p "$A/.watcher.lock"; echo $$ > "$A/.watcher.lock/pid"   # $$ = this shell, alive
AF_STATE_DIR="$A" "$SC/secondary-loop" --idle 1 >/dev/null 2>&1; assert_eq "2nd persistent watcher refused (exit 5)" 5 "$?"
# --once ALSO contends now (a --once review is not short if it runs a full agent review)
AF_STATE_DIR="$A" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "--once refused while a live watcher holds the lock" 5 "$?"
# doctor distinguishes a stale lock (dead owner) from a live one; 999999 is beyond the pid range
echo 999999 > "$A/.watcher.lock/pid"
assert_contains "doctor flags a stale watcher lock" "stale" "$(AF_STATE_DIR="$A" "$SC/doctor" 2>&1)"
echo $$ > "$A/.watcher.lock/pid"
assert_contains "doctor sees a live watcher"        "one watcher active" "$(AF_STATE_DIR="$A" "$SC/doctor" 2>&1)"
rm -rf "$A/.watcher.lock"
# NO auto-reclaim (race-free by construction): ANY existing lock dir makes a new watcher
# refuse — even a stale one. The operator clears it (doctor says how).
mkdir -p "$A/.watcher.lock"; echo 999999 > "$A/.watcher.lock/pid"        # stale (dead owner)
AF_STATE_DIR="$A" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "stale lock refused, not reclaimed (fail-closed)" 5 "$?"
# a lock dir with NO pid file (crash between mkdir and pid write) also refuses, not aborts
rm -f "$A/.watcher.lock/pid"
AF_STATE_DIR="$A" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "pid-less lock still refuses (exit 5, no set -e abort)" 5 "$?"
assert_contains "doctor flags a pid-less lock as stale" "stale" "$(AF_STATE_DIR="$A" "$SC/doctor" 2>&1)"
# after the operator clears the lock, a fresh --once claims, runs, and releases it
rm -rf "$A/.watcher.lock"
AF_STATE_DIR="$A" SECONDARY_AGENT_CMD="$stub" "$SC/secondary-loop" --once --idle 1 >/dev/null 2>&1; assert_eq "after clearing the lock, --once runs (exit 0)" 0 "$?"
assert_eq "owner released its lock on exit" 0 "$([ -d "$A/.watcher.lock" ] && echo 1 || echo 0)"
# F5: a RELATIVE AF_STATE_DIR is rejected (resolves differently per cwd)
AF_STATE_DIR="relative/notabs" "$SC/doctor" >/dev/null 2>&1; assert_eq "relative AF_STATE_DIR rejected (exit 2)" 2 "$?"
# F4: an UNUSABLE AF_STATE_DIR (parent is a file) fails fast rather than degrading
printf x > "$SH/notadir"; AF_STATE_DIR="$SH/notadir/sub" "$SC/doctor" >/dev/null 2>&1; assert_eq "unusable AF_STATE_DIR fails fast (exit 2)" 2 "$?"; rm -f "$SH/notadir"
rm -rf "$SH/runs" "$SH/status.seed.json" "$SH/master-log.seed.md"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
