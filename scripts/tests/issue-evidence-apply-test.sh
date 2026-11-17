#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# issue-evidence-apply-test.sh — fixture suite for scripts/issue-evidence-apply.sh,
# the GitHub-facing half of the issue-evidence bot (3-practice/ISSUE-EVIDENCE.adoc).
#
# A fake `gh` on PATH serves each API path from a fixture file, can be told to
# fail a path (exit 1 with an error body, as gh does on an HTTP error), logs
# every call, and records every close and reopen instead of performing it. No
# test reaches the network.
#
# What the fake cannot prove: that GitHub's real responses have the shapes the
# fixtures give them. The script's header lists the endpoints and fields it
# relies on.
#
# Run: bash scripts/tests/issue-evidence-apply-test.sh
# ISSUE_EVIDENCE_APPLY_SH overrides the script under test.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IA="${ISSUE_EVIDENCE_APPLY_SH:-$SCRIPT_DIR/../issue-evidence-apply.sh}"
WORK="$(mktemp -d)"
if [ -n "${IA_KEEP:-}" ]; then echo "keeping $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else ko "$label (exit $RC; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|'))"; fi
}

R="o/r"
BOT="github-actions[bot]"
FIX="$WORK/fix"
BIN="$WORK/bin"
mkdir -p "$BIN"

# --- the fake gh -------------------------------------------------------------
cat >"$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
key() { printf '%s' "$1" | tr '/?&=' '____'; }
printf '%s\n' "$*" >>"$GH_FIX/CALLS.log"
case "${1:-}" in
  api)
    shift
    JQF="" P=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --jq) JQF="$2"; shift 2 ;;
        -H | -X | -f | -F) shift 2 ;;
        -*) shift ;;
        *) [ -n "$P" ] || P="$1"; shift ;;
      esac
    done
    k="$(key "$P")"
    if [ -f "$GH_FIX/$k.fail" ]; then
      cat "$GH_FIX/$k.fail"
      echo "gh: API rate limit exceeded (HTTP 403)" >&2
      exit 1
    fi
    [ -f "$GH_FIX/$k.json" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [ -n "$JQF" ]; then jq -r "$JQF" "$GH_FIX/$k.json"; else cat "$GH_FIX/$k.json"; fi
    ;;
  issue)
    sub="$2" n="$3"
    shift 3
    repo="" body="" reason=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --comment) body="$2"; shift 2 ;;
        --reason) reason="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$sub" in
      view) jq -r '.state | ascii_upcase' "$GH_FIX/$(key "repos/$repo/issues/$n").json" ;;
      close | reopen)
        printf '%s %s %s\n' "$sub" "$n" "$reason" >>"$GH_FIX/ACTIONS.log"
        printf '%s' "$body" >"$GH_FIX/body-$sub-$n.txt"
        # A test can make the default branch move as a side effect of a write.
        if [ -f "$GH_FIX/MOVE_HEAD_TO" ]; then
          printf '{"object":{"sha":"%s","type":"commit"},"ref":"refs/heads/main"}\n' "$(cat "$GH_FIX/MOVE_HEAD_TO")" \
            >"$GH_FIX/$(key "repos/$repo/git/ref/heads/main").json"
        fi
        ;;
    esac
    ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 64 ;;
esac
SHIM
chmod +x "$BIN/gh"

reset_fix() {
  rm -rf "$FIX"
  mkdir -p "$FIX"
  : >"$FIX/CALLS.log"
  head_is "$SHA_A"
}
fkey() { printf '%s' "$1" | tr '/?&=' '____'; }
# fx PATH JSON: GitHub answers PATH with JSON.
fx() { printf '%s\n' "$2" >"$FIX/$(fkey "$1").json"; }
# fx_fail PATH BODY: GitHub answers PATH with an HTTP error carrying BODY.
fx_fail() { printf '%s\n' "$2" >"$FIX/$(fkey "$1").fail"; }
RATE='{"message":"API rate limit exceeded for installation ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}'
HASH="$(printf 'row' | sha256sum | cut -d' ' -f1)"
# The evaluated commit, and another one the default branch can move to.
SHA_A="$(printf a%.0s {1..40})"
SHA_B="$(printf b%.0s {1..40})"
# head_is SHA: the live head of the default branch (main) is SHA.
head_is() {
  fx "repos/$R" "{\"default_branch\":\"main\",\"full_name\":\"$R\"}"
  fx "repos/$R/git/ref/heads/main" "{\"object\":{\"sha\":\"$1\",\"type\":\"commit\"},\"ref\":\"refs/heads/main\"}"
}

# Timeline items. ITEMS is a JSON array built from these words, oldest first:
#   mark      a comment by the bot carrying the bot's marker
#   note:WHO  a comment by WHO without a marker
#   closed:WHO / reopened:WHO
timeline() {
  local w out="[]" i=0 item
  for w in "$@"; do
    i=$((i + 1))
    case "$w" in
      mark) item="$(jq -c -n --arg b "$BOT" --arg h "$HASH" --argjson i "$i" \
        '{id: $i, event: "commented", user: {login: $b}, actor: {login: $b}, body: ("**issue-evidence:** closing.\n\n<!-- issue-evidence-bot: row-sha256=" + $h + " -->")}')" ;;
      note:*) item="$(jq -c -n --arg u "${w#note:}" --argjson i "$i" \
        '{id: $i, event: "commented", user: {login: $u}, actor: {login: $u}, body: "a remark"}')" ;;
      closed:* | reopened:*) item="$(jq -c -n --arg e "${w%%:*}" --arg u "${w#*:}" '{event: $e, actor: {login: $u}}')" ;;
      *) echo "bad timeline word $w" >&2; return 1 ;;
    esac
    out="$(jq -c --argjson it "$item" --argjson i "$i" \
      '. + [$it + {created_at: ("2026-01-01T00:00:" + (if $i < 10 then "0" else "" end) + ($i | tostring) + "Z")}]' <<<"$out")"
  done
  printf '%s\n' "$out"
}
# issue N STATE TIMELINE-JSON: fixtures for issue N in every shape the script
# may read (the issue, its timeline, and the comments and events derived from
# the same history).
issue() {
  local n="$1" state="$2" tl="$3" closer
  closer="$(jq -r --arg s "$state" 'if $s == "closed" then ([.[] | select(.event == "closed")] | last | .actor.login // "") else "" end' <<<"$tl")"
  fx "repos/$R/issues/$n" "$(jq -c -n --argjson n "$n" --arg s "$state" --arg c "$closer" \
    '{number: $n, state: $s} + (if $c == "" then {closed_by: null} else {closed_by: {login: $c}} end)')"
  fx "repos/$R/issues/$n/timeline?per_page=100" "$tl"
  fx "repos/$R/issues/$n/comments?per_page=100" "$(jq -c 'map(select(.event == "commented") | {id, user, body})' <<<"$tl")"
  fx "repos/$R/issues/$n/events?per_page=100" "$(jq -c 'map(select(.event == "closed" or .event == "reopened") | {event, actor})' <<<"$tl")"
}
evaluated() { # N... -> an evaluate-records file naming those issues
  local n
  for n in "$@"; do
    jq -c -n --argjson n "$n" --arg r "$R" '{disposition: "landed", failed: [], holds: true, issue: $n, repo: $r, unevaluated: []}'
  done >"$WORK/evaluated.jsonl"
}

run() {
  RC=0
  PATH="$BIN:$PATH" GH_FIX="$FIX" GITHUB_STEP_SUMMARY="$WORK/summary.md" "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}
rc_is() { [ "$RC" = "$1" ]; }
state_of() { # N -> the states element for N, or "absent"
  jq -c --argjson n "$1" '(map(select(.number == $n)) | if length == 0 then "absent" else .[0] end)' <<<"$OUT"
}
actions() { cat "$FIX/ACTIONS.log" 2>/dev/null || true; }
called() { grep -qF -- "$1" "$FIX/CALLS.log"; }
# did_action "close N": that action was performed. no_action: it was not.
did_action() { actions | grep -q "^$1\\( \\|\$\\)"; }
no_action() { ! did_action "$1"; }
not_called() { ! called "$1"; }
err_has() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
not_out_has() { ! out_has "$1"; }

# --- states: the decide input ------------------------------------------------
reset_fix
issue 1 open "$(timeline)"
issue 2 closed "$(timeline mark closed:"$BOT")"
issue 3 closed "$(timeline closed:alice)"
issue 4 open "$(timeline mark closed:"$BOT" reopened:alice)"
issue 5 open "$(timeline mark closed:"$BOT" reopened:"$BOT")"
fx "repos/$R/issues/6" '{"number":6,"state":"open","pull_request":{"url":"x"}}'
evaluated 1 2 3 4 5 6
run bash "$IA" states --repo "$R" --evaluated "$WORK/evaluated.jsonl"
check "states: exits 0 on a full read" rc_is 0
check "states: an untouched open issue is plain open" \
  test "$(state_of 1)" = '{"number":1,"state":"open","closed_by_bot":false,"reopened_by_human":false}'
check "states: closed by the bot with its marker is closed_by_bot" \
  test "$(state_of 2)" = '{"number":2,"state":"closed","closed_by_bot":true,"reopened_by_human":false}'
check "states: closed by a person is not closed_by_bot" \
  test "$(state_of 3)" = '{"number":3,"state":"closed","closed_by_bot":false,"reopened_by_human":false}'
check "states: a person's reopen after the bot's close is reopened_by_human" \
  test "$(state_of 4)" = '{"number":4,"state":"open","closed_by_bot":false,"reopened_by_human":true}'
check "states: the bot's own reopen is not reopened_by_human" \
  test "$(state_of 5)" = '{"number":5,"state":"open","closed_by_bot":false,"reopened_by_human":false}'
check "states: a pull request is never listed" test "$(state_of 6)" = '"absent"'

reset_fix
fx_fail "repos/$R/issues/1" "$RATE"
evaluated 1
run bash "$IA" states --repo "$R" --evaluated "$WORK/evaluated.jsonl"
check "states: an unreadable issue is a refusal (non-zero exit)" test "$RC" -ne 0

# --- C1: a failed marker lookup is a refusal, never a count of zero --------------
# Issue 41 was closed by the bot and reopened by a person. Read correctly it is
# reopened_by_human, which stops the bot closing it again; a lookup that fails
# and is read as "no markers" would make it a plain open issue.
c1_case() { # LABEL MODE: fail (HTTP error) | body (200 with an error object)
  reset_fix
  issue 41 open "$(timeline mark closed:"$BOT" reopened:alice)"
  local p
  for p in "repos/$R/issues/41/timeline?per_page=100" "repos/$R/issues/41/comments?per_page=100"; do
    rm -f "$FIX/$(fkey "$p").json"
    if [ "$2" = fail ]; then fx_fail "$p" "$RATE"; else fx "$p" "$RATE"; fi
  done
  evaluated 41
  run bash "$IA" states --repo "$R" --evaluated "$WORK/evaluated.jsonl"
  check "C1: $1: states exits non-zero" test "$RC" -ne 0
  check "C1: $1: ... says it refuses" err_has "refusing to act"
  check "C1: $1: ... and emits no states" test -z "$OUT"
}
c1_case "the marker lookup fails (HTTP error)" fail
c1_case "the marker lookup answers 200 with a rate-limit body" body

reset_fix
issue 42 open "$(timeline)"
evaluated 42
run bash "$IA" states --repo "$R" --evaluated "$WORK/evaluated.jsonl"
check "C1: a successful empty history is zero markers (plain open)" \
  test "$(state_of 42)" = '{"number":42,"state":"open","closed_by_bot":false,"reopened_by_human":false}'

reset_fix
issue 43 open "$(timeline mark closed:"$BOT")"
evaluated 43
run bash "$IA" states --repo "$R" --evaluated "$WORK/evaluated.jsonl"
check "C1: an issue whose history disagrees with its state is left out (no action)" \
  test "$(state_of 43)" = '"absent"'
check "C1: ... with a warning" err_has "disagrees"

# --- select: the cap ---------------------------------------------------------
decisions() { # ACTION... -> decisions file, issue numbers from 11
  local a n=10
  for a in "$@"; do
    n=$((n + 1))
    jq -c -n --argjson n "$n" --arg a "$a" --arg r "$R" '{action: $a, disposition: "landed", issue: $n, reason: "x", repo: $r}'
  done >"$WORK/decisions.jsonl"
}
reset_fix
decisions close none close reopen
run bash "$IA" select --decisions "$WORK/decisions.jsonl" --max-actions 2 --counts "$WORK/counts"
check "select: at most max_actions actions, in order, none-actions dropped" \
  test "$(jq -r .issue <<<"$OUT" | tr '\n' ' ')" = "11 13 "
check "select: counts are TOTAL PLANNED" test "$(cat "$WORK/counts")" = "3 2"
run bash "$IA" select --decisions "$WORK/decisions.jsonl" --max-actions 51
check "select: max_actions above 50 is invalid input" rc_is 2

# --- apply ---------------------------------------------------------------------
plan() { # ACTION:N... -> plan file
  local w
  for w in "$@"; do
    jq -c -n --arg a "${w%%:*}" --argjson n "${w#*:}" \
      '{issue: $n, action: $a, close_reason: "completed", body: ("body for " + ($n | tostring))}'
  done | jq -c -s . >"$WORK/plan.json"
}
reset_fix
issue 21 open "$(timeline)"
issue 22 closed "$(timeline mark closed:"$BOT")"
plan close:21 reopen:22
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "apply: exits 0" rc_is 0
check "apply: closes an open issue and reopens a bot-closed one" \
  test "$(actions | tr '\n' ' ')" = "close 21 completed reopen 22  "
check "apply: the comment is the planned body" test "$(cat "$FIX/body-close-21.txt")" = "body for 21"

reset_fix
issue 21 closed "$(timeline closed:alice)"
issue 22 open "$(timeline mark closed:"$BOT" reopened:alice)"
plan close:21 reopen:22
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "apply: no close of an issue a person closed since, no reopen of an open one" test -z "$(actions)"

reset_fix
issue 21 open "$(timeline)"
plan close:21 close:21 close:21
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 2
check "apply: a plan over max_actions is refused" rc_is 1
check "apply: ... and nothing is done" test -z "$(actions)"

# --- C2/C3: who acted last is re-read just before each action ------------------
# The plan was made from an earlier read; these fixtures are the issue as it
# stands when the apply job reaches it.
reset_fix
issue 31 closed "$(timeline mark closed:"$BOT" reopened:alice closed:alice)"
issue 32 closed "$(timeline mark closed:"$BOT" reopened:alice closed:"$BOT")"
issue 33 open "$(timeline mark closed:"$BOT" reopened:alice)"
plan reopen:31 reopen:32 close:33
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C2: no reopen of an issue a person reopened and closed again since the plan" \
  no_action "reopen 31"
check "C2: no reopen when the bot account's latest close carries no marker after the last reopen" \
  no_action "reopen 32"
check "C3: no close of an issue a person reopened after the bot closed it" \
  no_action "close 33"
check "C2/C3: the run still exits 0 (a skip is not a failure)" rc_is 0

reset_fix
issue 34 open "$(timeline note:alice closed:alice reopened:alice)"
issue 35 open "$(timeline mark closed:"$BOT" reopened:"$BOT")"
issue 36 closed "$(timeline mark closed:"$BOT" reopened:alice closed:alice reopened:"$BOT" mark closed:"$BOT")"
plan close:34 close:35 reopen:36
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C3: an issue the bot never touched is closed even if a person once reopened it" \
  did_action "close 34"
check "C3: an issue the bot itself reopened (a regression) is closed again" \
  did_action "close 35"
check "C2: the bot's latest marked close is reopened" did_action "reopen 36"

reset_fix
issue 37 open "$(timeline)"
fx_fail "repos/$R/issues/37/timeline?per_page=100" "$RATE"
plan close:37
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C2/C3: an unreadable history before an action is a refusal (exit 1)" rc_is 1
check "C2/C3: ... with a message that says so" err_has "refusing to act"
check "C2/C3: ... and nothing is done" test -z "$(actions)"

# The timeline is paginated: a history split across pages is read whole.
reset_fix
issue 38 open "$(timeline)"
printf '%s\n%s\n' "$(timeline mark)" "$(jq -c 'map(.created_at = "2026-01-02T00:00:00Z")' <<<"$(timeline closed:"$BOT" reopened:alice)")" \
  >"$FIX/$(fkey "repos/$R/issues/38/timeline?per_page=100").json"
plan close:38
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C3: a person's reopen on the second page of the timeline is seen" test -z "$(actions)"

# --- C4: a removed row reopens the issue the bot closed on it ---------------------
# A ledger history: #61..#65 had rows; the second commit removes every row but
# #62. #63's row was for another repository.
GREPO="$WORK/repo"
mkdir -p "$GREPO/.machine_readable"
git -C "$GREPO" init -q
git -C "$GREPO" config user.email t@example.invalid
git -C "$GREPO" config user.name test
LEDGER_PATH=".machine_readable/issue-evidence.jsonl"
row() { jq -c -n --argjson n "$1" --arg r "$2" '{issue: $n, repo: $r}'; }
{ row 61 "$R"; row 62 "$R"; row 63 x/y; row 64 "$R"; row 65 O/R; } >"$GREPO/$LEDGER_PATH"
git -C "$GREPO" add -A && git -C "$GREPO" commit -q -m rows
row 62 "$R" >"$GREPO/$LEDGER_PATH"
git -C "$GREPO" commit -q -am "remove rows"
GHEAD="$(git -C "$GREPO" rev-parse HEAD)"
# Runs in this shell (not a subshell), so RC, OUT and ERR reach the checks.
removed_rows() {
  cd "$GREPO" || return 1
  run bash "$IA" removed-rows --repo "$R" --ledger "$LEDGER_PATH" --commit "$GHEAD"
  cd "$OLDPWD" || return 1
}

reset_fix
issue 61 closed "$(timeline mark closed:"$BOT")"
issue 64 closed "$(timeline mark closed:"$BOT" reopened:alice closed:alice)"
issue 65 open "$(timeline mark closed:"$BOT" reopened:alice)"
removed_rows
check "C4: removed-rows exits 0" rc_is 0
check "C4: the bot-closed issue whose row was removed is planned for reopening" \
  test "$(jq -r '"\(.action) \(.issue)"' <<<"$OUT" | tr '\n' ' ')" = "reopen 61 "
check "C4: ... with a comment that says the row was removed" \
  out_has "the row was removed"
check "C4: ... ending with the bot's marker for the row it closed on" \
  test "$(jq -r .body <<<"$OUT" | tail -n 1)" = "<!-- issue-evidence-bot: row-sha256=$HASH -->"
check "C4: an issue a person closed (after the bot) is never touched" not_called "issues/64/timeline"
check "C4: an issue that is still open is not planned" not_out_has "\"issue\":65"
check "C4: an issue whose row is still there is not read" not_called "issues/62"
check "C4: a removed row of another repository is not read" not_called "issues/63"

reset_fix
issue 61 closed "$(timeline mark closed:"$BOT")"
issue 64 closed "$(timeline closed:alice)"
issue 65 open "$(timeline)"
fx_fail "repos/$R/issues/61/timeline?per_page=100" "$RATE"
removed_rows
check "C4: a failed read while listing bot-closed issues is a refusal (exit 1)" rc_is 1
check "C4: ... with no partial list" test -z "$OUT"

# F5: the first read of a candidate answers 200 but with a body that is not an
# issue (an error object, or not JSON). It is a refusal, as in read_issue,
# never a silent skip that would leave the issue closed on a removed row.
for peek in "$RATE" 'not json' '[]' '{"number":61,"state":"locked"}'; do
  reset_fix
  issue 61 closed "$(timeline mark closed:"$BOT")"
  issue 64 closed "$(timeline closed:alice)"
  issue 65 open "$(timeline)"
  fx "repos/$R/issues/61" "$peek"
  removed_rows
  check "F5: removed-rows refuses a 200 peek that is not an issue ($(printf '%s' "$peek" | head -c 24))" rc_is 1
  check "F5: ... says it refuses" err_has "refusing to act"
  check "F5: ... with no partial list" test -z "$OUT"
done
# The shape check comes before the filter: a well-formed issue the bot did
# not close is still skipped without a refusal.
reset_fix
issue 61 closed "$(timeline closed:alice)"
issue 64 closed "$(timeline closed:alice)"
issue 65 open "$(timeline)"
removed_rows
check "F5: a well-formed issue closed by a person is still skipped (exit 0, nothing listed)" \
  test "$RC/$OUT" = "0/"

# The removed-row reopen shares the cap with the ledger's own actions.
reset_fix
decisions close close
jq -c -n --arg r "$R" '{issue: 61, action: "reopen", close_reason: "not planned", body: "row removed", repo: $r}' >"$WORK/removed.jsonl"
run bash "$IA" select --decisions "$WORK/decisions.jsonl" --removed "$WORK/removed.jsonl" --max-actions 2 --counts "$WORK/counts"
check "C4: a removed-row reopen counts toward max_actions (cap 2: not planned)" \
  test "$(jq -r .issue <<<"$OUT" | tr '\n' ' ')/$(cat "$WORK/counts")" = "11 12 /3 2"
run bash "$IA" select --decisions "$WORK/decisions.jsonl" --removed "$WORK/removed.jsonl" --max-actions 3
check "C4: ... and is planned when the cap allows" test "$(jq -r .issue <<<"$OUT" | tr '\n' ' ')" = "11 12 61 "

reset_fix
issue 61 closed "$(timeline mark closed:"$BOT")"
jq -c -s . "$WORK/removed.jsonl" >"$WORK/plan.json"
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C4: apply reopens it with the removed-row comment" \
  test "$(actions)/$(cat "$FIX/body-reopen-61.txt" 2>/dev/null)" = "reopen 61 /row removed"

# --- C5: nothing is applied from a commit that is no longer the branch head ------
reset_fix
issue 51 open "$(timeline)"
head_is "$SHA_B"
plan close:51
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C5: a moved default branch exits 0" rc_is 0
check "C5: ... reports stale; nothing done" grep -qF "stale; nothing done" "$WORK/summary.md"
check "C5: ... and acts on nothing" test -z "$(actions)"
check "C5: ... without reading any issue" not_called "issues/"

reset_fix
issue 51 open "$(timeline)"
plan close:51
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C5: an unmoved default branch proceeds" did_action "close 51"

reset_fix
issue 51 open "$(timeline)"
fx_fail "repos/$R/git/ref/heads/main" "$RATE"
plan close:51
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "C5: an unreadable branch head is a refusal (exit 1)" rc_is 1
check "C5: ... and nothing is done" test -z "$(actions)"
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "C5: apply without --commit is invalid input" rc_is 2

# F6: the default branch moves after the first write. The head is re-read
# before every write, so the loop stops there: the first action stays done,
# the second is not performed, and the summary says so.
reset_fix
issue 71 open "$(timeline)"
issue 72 open "$(timeline)"
printf '%s\n' "$SHA_B" >"$FIX/MOVE_HEAD_TO"
plan close:71 close:72
: >"$WORK/summary.md"
run bash "$IA" apply --repo "$R" --commit "$SHA_A" --plan "$WORK/plan.json" --max-actions 10
check "F6: a branch that moves mid-run exits 0" rc_is 0
check "F6: ... the action before the move stays done" did_action "close 71"
check "F6: ... the action after the move is not performed" no_action "close 72"
check "F6: ... the summary says the run stopped and what was done" \
  grep -qF "stopped: main moved from $SHA_A to $SHA_B after 1 of 2 planned action(s)" "$WORK/summary.md"

# --- F1/F2: the plan hand-off (plan, verify-plan) --------------------------------
# A caller repository whose ledger holds #81 (holds: close), #82 (a check
# fails and the bot closed it: regression reopen) and, in its history only,
# #83 (the bot closed it; the row was removed: removed-row reopen).
IE="$REPO_ROOT/scripts/issue-evidence.sh"
VREPO="$WORK/vrepo"
mkdir -p "$VREPO/.machine_readable"
git -C "$VREPO" init -q -b main
git -C "$VREPO" config user.email t@example.invalid
git -C "$VREPO" config user.name test
git -C "$VREPO" config commit.gpgsign false
printf '= x\n' >"$VREPO/README.adoc"
full_row() { # N DISPOSITION CHECKS
  jq -c -S -n --argjson n "$1" --arg d "$2" --argjson c "$3" --arg r "$R" \
    '{issue: $n, repo: $r, disposition: $d, claim: "Row \($n) for @someone.", checks: $c,
      evidence: ["e\($n)"], added: "2026-11-17"}'
}
V81="$(full_row 81 landed '[{"kind":"path-present","path":"README.adoc"}]')"
V82="$(full_row 82 moot '[{"kind":"path-present","path":"gone.txt"},{"kind":"path-present","path":"README.adoc"}]')"
V83="$(full_row 83 superseded '[{"kind":"path-present","path":"README.adoc"}]')"
printf '%s\n' "$V81" "$V82" "$V83" >"$VREPO/$LEDGER_PATH"
git -C "$VREPO" add -A && git -C "$VREPO" commit -q -m rows
printf '%s\n' "$V81" "$V82" >"$VREPO/$LEDGER_PATH"
git -C "$VREPO" commit -q -am "remove row 83"
VSHA="$(git -C "$VREPO" rev-parse HEAD)"
hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
CONTENTS="repos/$R/contents/$LEDGER_PATH?ref=$VSHA"
v_fixtures() { # the GitHub side: issue states, the head, and the ledger by API
  reset_fix
  head_is "$VSHA"
  local save="$HASH"
  issue 81 open "$(timeline)"
  HASH="$(hash_of "$V82")"; issue 82 closed "$(timeline mark closed:"$BOT")"
  HASH="$(hash_of "$V83")"; issue 83 closed "$(timeline mark closed:"$BOT")"
  HASH="$save"
  git -C "$VREPO" show "$VSHA:$LEDGER_PATH" >"$FIX/$(fkey "$CONTENTS").json"
}
v_fixtures
# The evaluate job's half, run in the caller's checkout.
(cd "$VREPO" && bash "$IE" evaluate --repo "$R" --no-scripts "$LEDGER_PATH") >"$WORK/v-evaluated.jsonl"
printf '%s\n' '[{"number":81,"state":"open"},{"number":82,"state":"closed","closed_by_bot":true}]' >"$WORK/v-open.json"
(cd "$VREPO" && bash "$IE" decide --repo "$R" --open "$WORK/v-open.json" --evaluated "$WORK/v-evaluated.jsonl" "$LEDGER_PATH") >"$WORK/v-decisions.jsonl"
cd "$VREPO" || exit 2
run bash "$IA" removed-rows --repo "$R" --ledger "$LEDGER_PATH" --commit HEAD
cd "$REPO_ROOT" || exit 2
printf '%s\n' "$OUT" >"$WORK/v-removed.jsonl"
check "removed-rows: the record carries the marker's row hash" \
  test "$(jq -r .hash "$WORK/v-removed.jsonl")" = "$(hash_of "$V83")"
run bash "$IA" select --decisions "$WORK/v-decisions.jsonl" --removed "$WORK/v-removed.jsonl" --max-actions 10
printf '%s\n' "$OUT" >"$WORK/v-selected.jsonl"
cd "$VREPO" || exit 2
run bash "$IA" plan --repo "$R" --selected "$WORK/v-selected.jsonl" --evaluated "$WORK/v-evaluated.jsonl" \
  --ledger "$LEDGER_PATH" --commit HEAD
cd "$REPO_ROOT" || exit 2
WANT_PLAN="$(jq -c -n --arg h81 "$(hash_of "$V81")" --arg h82 "$(hash_of "$V82")" --arg h83 "$(hash_of "$V83")" '[
  {action: "close", close_reason: "completed", failed: [], hash: $h81, issue: 81, reason: "evidence-holds", unevaluated: []},
  {action: "reopen", close_reason: "not planned", failed: [0], hash: $h82, issue: 82, reason: "regression", unevaluated: []},
  {action: "reopen", close_reason: "not planned", failed: [], hash: $h83, issue: 83, reason: "row-removed", unevaluated: []}]')"
check "plan: per action only issue, action, close reason, row hash and check indices" test "$OUT" = "$WANT_PLAN"
check "plan: ... and no free text from the ledger" test -z "$(grep -F 'someone' <<<"$OUT" || true)"
printf '%s\n' "$OUT" >"$WORK/v-plan.json"
# Over the cap: 300 removed-row reopens (select would stop at 50; plan does
# not rely on it).
for n in $(seq 1000 1299); do
  jq -c -n --argjson n "$n" --arg r "$R" --arg h "$HASH" '{action: "reopen", hash: $h, issue: $n, reason: "row-removed", repo: $r}'
done >"$WORK/v-many.jsonl"
cd "$VREPO" || exit 2
run bash "$IA" plan --repo "$R" --selected "$WORK/v-many.jsonl" --evaluated "$WORK/v-evaluated.jsonl" --ledger "$LEDGER_PATH"
cd "$REPO_ROOT" || exit 2
check "plan: over the 32,768-byte cap it refuses, with a message, and prints nothing" \
  test "$RC/${OUT:-}" = "1/"
check "plan: ... the message names the cap" err_has "over the 32768-byte cap"

verify() { # PLAN-FILE [MAX]
  run bash "$IA" verify-plan --repo "$R" --commit "$VSHA" --ledger "$LEDGER_PATH" --plan "$1" \
    --max-actions "${2:-10}" --evaluator "$IE"
}
v_fixtures
verify "$WORK/v-plan.json"
check "verify-plan: a plan that matches the fetched ledger passes" rc_is 0
check "verify-plan: ... reading the ledger by API at the evaluated commit" called "$CONTENTS"
printf '%s\n' "$OUT" >"$WORK/v-full.json"
body_of() { jq -r --argjson n "$1" '.[] | select(.issue == $n) | .body' "$WORK/v-full.json"; }
old81="$(cd "$VREPO" && bash "$IE" render-comment --issue 81 --action close --repo "$R" --evaluated "$WORK/v-evaluated.jsonl" "$LEDGER_PATH")"
old82="$(cd "$VREPO" && bash "$IE" render-comment --issue 82 --action reopen --repo "$R" --evaluated "$WORK/v-evaluated.jsonl" "$LEDGER_PATH")"
check "verify-plan: the close comment is byte-identical to the evaluate-job rendering" test "$(body_of 81)" = "$old81"
check "verify-plan: the regression reopen comment is byte-identical too" test "$(body_of 82)" = "$old82"
check "verify-plan: the removed-row comment is byte-identical to removed-rows'" \
  test "$(body_of 83)" = "$(jq -r .body "$WORK/v-removed.jsonl")"
run bash "$IA" apply --repo "$R" --commit "$VSHA" --plan "$WORK/v-full.json" --max-actions 10
check "apply: the verified plan is performed" test "$(actions | tr '\n' '|')" = "close 81 completed|reopen 82 |reopen 83 |"
check "apply: ... with the rendered comments" test "$(cat "$FIX/body-close-81.txt")" = "$old81"
v_fixtures
jq -c '.[0].body = null' "$WORK/v-full.json" >"$WORK/v-nobody.json"
run bash "$IA" apply --repo "$R" --commit "$VSHA" --plan "$WORK/v-nobody.json" --max-actions 10
check "apply: an entry without a comment body is invalid input, and nothing is done" test "$RC/$(actions)" = "2/"

# Every way a plan can disagree with the ledger refuses the WHOLE run.
bad_plan() { # LABEL NEEDLE JQ-ON-THE-PLAN [MAX]
  v_fixtures
  jq -c "$3" "$WORK/v-plan.json" >"$WORK/v-bad.json"
  verify "$WORK/v-bad.json" "${4:-10}"
  check "verify-plan refuses $1" test "$RC/${OUT:-}" = "1/"
  check "... saying so" err_has "$2"
}
bad_plan "a wrong row hash" "the hash is not that of the row" '.[0].hash = ("0" * 64)'
bad_plan "an issue with no row" "has no row in the ledger" '.[0].issue = 999'
bad_plan "a removed-row reopen of an issue whose row is present" "so it is no removed row" '.[2].issue = 81 | del(.[0])'
bad_plan "an extra field in an entry" "the fields must be exactly" '.[0].body = "PWNED"'
bad_plan "a missing field" "the fields must be exactly" 'del(.[0].hash)'
bad_plan "a close with a failed check" "a close needs every check to hold" '.[0].failed = [0]'
bad_plan "a regression with no failed check" "needs a failed check" '.[1].failed = []'
bad_plan "a check index out of range" "out of range" '.[1].failed = [0, 5]'
bad_plan "a close reason that does not follow the disposition" "close_reason does not follow" '.[0].close_reason = "not planned"'
bad_plan "an action and reason that do not go together" "is not a planned action" '.[0].action = "reopen"'
bad_plan "the same issue twice" "appears twice" '. + [.[0]]'
bad_plan "more actions than max_actions" "more than max_actions" '.' 2
bad_plan "unsorted check indices" "sorted lists" '.[1].failed = [1, 0]'
v_fixtures
head -c 40000 /dev/zero | tr '\0' ' ' >"$WORK/v-huge.json"
verify "$WORK/v-huge.json"
check "verify-plan refuses a plan over the 32,768-byte cap" test "$RC/${OUT:-}" = "1/"
v_fixtures
rm -f "$FIX/$(fkey "$CONTENTS").json"
verify "$WORK/v-plan.json"
check "verify-plan refuses when the ledger cannot be read at the commit" test "$RC/${OUT:-}" = "1/"
v_fixtures
printf 'not a ledger\n' >"$FIX/$(fkey "$CONTENTS").json"
verify "$WORK/v-plan.json"
check "verify-plan refuses a ledger that does not validate" test "$RC/${OUT:-}" = "1/"
run bash "$IA" verify-plan --repo "$R" --commit "$VSHA" --ledger "../x" --plan "$WORK/v-plan.json" --max-actions 10 --evaluator "$IE"
check "verify-plan refuses a ledger path with a .. component" rc_is 2

# A removed-row reopen undoes the bot's close on that row only.
v_fixtures
issue 83 closed "$(timeline mark closed:"$BOT")"
jq -c '[.[] | select(.issue == 83)]' "$WORK/v-full.json" >"$WORK/v-83.json"
run bash "$IA" apply --repo "$R" --commit "$VSHA" --plan "$WORK/v-83.json" --max-actions 10
check "apply: no removed-row reopen when the bot's marker names another row" no_action "reopen 83"

# --- one definition of the marker ------------------------------------------------
marker="$(sed -n "s/^MARKER='\\(.*\\)'\$/\\1/p" "$IA")"
check "marker: the applier's marker is the one issue-evidence.sh writes" \
  grep -qF -- "${marker:-<none>}" "$REPO_ROOT/scripts/issue-evidence.sh"

if [ -z "${IA_NEGATIVE_CONTROL:-}" ]; then
  # NEGATIVE CONTROL: the suite, run against an applier whose verify-plan no
  # longer compares the row hash, must report failures.
  BROKEN="$WORK/broken-issue-evidence-apply.sh"
  # shellcheck disable=SC2016  # a sed program over jq text
  sed 's/^          elif \$r\.hash != \$e\.hash then /          elif false then /' "$IA" >"$BROKEN"
  if cmp -s "$IA" "$BROKEN"; then
    ko "negative control: the mutation did not apply (the text changed?)"
  else
    nc_rc=0
    nc_out="$(ISSUE_EVIDENCE_APPLY_SH="$BROKEN" IA_NEGATIVE_CONTROL=1 bash "$SCRIPT_DIR/$(basename "$0")" 2>&1)" || nc_rc=$?
    nc_fail="$(printf '%s\n' "$nc_out" | grep -c '^FAIL:' || true)"
    if [ "$nc_rc" -ne 0 ] && [ "$nc_fail" -gt 0 ]; then
      ok "negative control: verify-plan without its hash check makes the suite fail ($nc_fail failures)"
    else
      ko "negative control: the suite passed against verify-plan without its hash check (exit $nc_rc)"
    fi
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
