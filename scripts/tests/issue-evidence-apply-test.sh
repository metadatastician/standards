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
trap 'rm -rf "$WORK"' EXIT
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
}
fkey() { printf '%s' "$1" | tr '/?&=' '____'; }
# fx PATH JSON: GitHub answers PATH with JSON.
fx() { printf '%s\n' "$2" >"$FIX/$(fkey "$1").json"; }
# fx_fail PATH BODY: GitHub answers PATH with an HTTP error carrying BODY.
fx_fail() { printf '%s\n' "$2" >"$FIX/$(fkey "$1").fail"; }
RATE='{"message":"API rate limit exceeded for installation ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}'
HASH="$(printf 'row' | sha256sum | cut -d' ' -f1)"

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
err_has() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }

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
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "apply: exits 0" rc_is 0
check "apply: closes an open issue and reopens a bot-closed one" \
  test "$(actions | tr '\n' ' ')" = "close 21 completed reopen 22  "
check "apply: the comment is the planned body" test "$(cat "$FIX/body-close-21.txt")" = "body for 21"

reset_fix
issue 21 closed "$(timeline closed:alice)"
issue 22 open "$(timeline mark closed:"$BOT" reopened:alice)"
plan close:21 reopen:22
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "apply: no close of an issue a person closed since, no reopen of an open one" test -z "$(actions)"

reset_fix
issue 21 open "$(timeline)"
plan close:21 close:21 close:21
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 2
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
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
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
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "C3: an issue the bot never touched is closed even if a person once reopened it" \
  did_action "close 34"
check "C3: an issue the bot itself reopened (a regression) is closed again" \
  did_action "close 35"
check "C2: the bot's latest marked close is reopened" did_action "reopen 36"

reset_fix
issue 37 open "$(timeline)"
fx_fail "repos/$R/issues/37/timeline?per_page=100" "$RATE"
plan close:37
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "C2/C3: an unreadable history before an action is a refusal (exit 1)" rc_is 1
check "C2/C3: ... with a message that says so" err_has "refusing to act"
check "C2/C3: ... and nothing is done" test -z "$(actions)"

# The timeline is paginated: a history split across pages is read whole.
reset_fix
issue 38 open "$(timeline)"
printf '%s\n%s\n' "$(timeline mark)" "$(jq -c 'map(.created_at = "2026-01-02T00:00:00Z")' <<<"$(timeline closed:"$BOT" reopened:alice)")" \
  >"$FIX/$(fkey "repos/$R/issues/38/timeline?per_page=100").json"
plan close:38
run bash "$IA" apply --repo "$R" --plan "$WORK/plan.json" --max-actions 10
check "C3: a person's reopen on the second page of the timeline is seen" test -z "$(actions)"

# --- one definition of the marker ------------------------------------------------
marker="$(sed -n "s/^MARKER='\\(.*\\)'\$/\\1/p" "$IA")"
check "marker: the applier's marker is the one issue-evidence.sh writes" \
  grep -qF -- "${marker:-<none>}" "$REPO_ROOT/scripts/issue-evidence.sh"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
