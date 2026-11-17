#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# issue-evidence-apply.sh — the GitHub-facing half of the issue-evidence bot
# (3-practice/ISSUE-EVIDENCE.adoc).
#
# scripts/issue-evidence.sh is a side-effect-free function of (ledger, tree).
# This script holds every read of GitHub's issue state and every close and
# reopen, so that the stateful decisions can be tested with a fake `gh` on
# PATH (scripts/tests/issue-evidence-apply-test.sh) instead of living as
# untestable shell inside .github/workflows/issue-evidence-reusable.yml.
#
# SUBCOMMANDS
#   states --repo OWNER/NAME --evaluated FILE
#       For each issue named by an evaluate record of FILE, one JSON array
#       element {number, state, closed_by_bot, reopened_by_human}: the --open
#       input of `issue-evidence.sh decide`. A pull request is never listed;
#       an issue whose newest close/reopen event disagrees with its state is
#       left out (so nothing is decided for it). Any failed or malformed read
#       prints nothing and exits 1: a lookup that failed is never read as
#       "no marker".
#   select --decisions FILE --max-actions N [--counts FILE]
#       The actions to plan this run: the decided closes and reopens, in
#       order, at most N of them (N from 0 to 50). --counts receives
#       "TOTAL PLANNED".
#   apply --repo OWNER/NAME --commit SHA --plan FILE --max-actions N
#       First re-reads the live head of the default branch: when it is not
#       SHA (the commit the plan was made at), reports "stale; nothing done"
#       and exits 0 without acting. Otherwise performs the plan (a JSON
#       array of {issue, action, close_reason, body}) with `gh issue close` /
#       `gh issue reopen`. Just before each action it re-reads the issue and
#       its timeline and skips the action when a person has closed or
#       reopened the issue since the plan.
#
# The bot's identity is one value, BOT below: the login the workflow's token
# acts as (github-actions[bot] for GITHUB_TOKEN). --bot LOGIN overrides it.
#
# GITHUB API RELIED ON (exercised here only against a fake `gh`)
#   GET repos/R/issues/N            .state (open|closed), has("pull_request")
#   GET repos/R/issues/N/timeline   paginated, oldest first; entries with
#       .event "commented" (.user.login or .actor.login, .body), "closed" and
#       "reopened" (.actor.login). `gh api --paginate` prints one JSON array
#       per page; they are read as one history.
#   GET repos/R                     .default_branch
#   GET repos/R/git/ref/heads/B     .object.sha, .object.type == "commit"
#
# EXIT
#   0  done
#   1  refused: a GitHub read or write failed, or the plan breaks the cap
#   2  invalid input (usage, malformed file)
set -euo pipefail
export LC_ALL=C

PROG="issue-evidence-apply.sh"
BOT="github-actions[bot]"
MARKER='<!-- issue-evidence-bot: row-sha256='

fail_input() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}
refuse() {
  printf '%s: refusing to act: %s\n' "$PROG" "$*" >&2
  exit 1
}

REPO="" EVAL_FILE="" DECISIONS="" MAX_ACTIONS="" COUNTS="" PLAN_FILE="" COMMIT=""
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || fail_input "--repo needs a value"; REPO="$2"; shift 2 ;;
      --bot) [ "$#" -ge 2 ] || fail_input "--bot needs a value"; BOT="$2"; shift 2 ;;
      --evaluated) [ "$#" -ge 2 ] || fail_input "--evaluated needs a value"; EVAL_FILE="$2"; shift 2 ;;
      --decisions) [ "$#" -ge 2 ] || fail_input "--decisions needs a value"; DECISIONS="$2"; shift 2 ;;
      --max-actions) [ "$#" -ge 2 ] || fail_input "--max-actions needs a value"; MAX_ACTIONS="$2"; shift 2 ;;
      --counts) [ "$#" -ge 2 ] || fail_input "--counts needs a value"; COUNTS="$2"; shift 2 ;;
      --plan) [ "$#" -ge 2 ] || fail_input "--plan needs a value"; PLAN_FILE="$2"; shift 2 ;;
      --commit) [ "$#" -ge 2 ] || fail_input "--commit needs a value"; COMMIT="$2"; shift 2 ;;
      *) fail_input "unknown argument: $1" ;;
    esac
  done
  if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    fail_input "--repo must be OWNER/NAME"
  fi
}
need_repo_opt() { [ -n "$REPO" ] || fail_input "$1 needs --repo OWNER/NAME"; }
need_max_actions() {
  if ! [[ "$MAX_ACTIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ACTIONS" -gt 50 ]; then
    fail_input "max_actions must be an integer from 0 to 50 (got '$MAX_ACTIONS')"
  fi
}

# FACTS_JQ: what the bot needs to know about one issue, from the issue object
# ($issue) and its whole timeline ($pages: the pages `gh api --paginate`
# returned, oldest first). Anything of the wrong shape is an error, never a
# default. Fields:
#   state             open | closed
#   pr                the number names a pull request
#   last_event/_actor the newest closed/reopened event and who performed it
#   markers           comments by BOT carrying MARKER
#   closed_by_bot     closed; the newest close was by BOT; and a marker
#                     comment by BOT follows the newest reopen (so a close by
#                     the same account for another reason does not count)
#   reopened_by_human open; BOT has marked it; the newest event is a reopen
#                     by someone other than BOT
#   consistent        the newest event agrees with the state
#   hash              the row-sha256 of the newest marker, or null
# shellcheck disable=SC2016  # jq program text, not shell
FACTS_JQ='
def login: (.user.login // .actor.login // "");
if ($issue | type) != "object" or (($issue.state != "open") and ($issue.state != "closed"))
  then error("the issue is not an issue object with state open or closed") else . end
| if ($pages | map(type == "array") | all | not) or ($pages | length) == 0
  then error("the timeline is not a list of events") else . end
| [ $pages[][] | if type != "object" then error("a timeline entry is not an object") else . end
    | select(.event == "commented" or .event == "closed" or .event == "reopened") ] as $ev
| ($ev | map(select(.event == "closed" or .event == "reopened")) | last) as $last
| ([$ev | to_entries[] | select(.value.event == "reopened") | .key] | max // -1) as $lastreopen
| [$ev | to_entries[] | select(.value.event == "commented" and (.value | login) == $bot
                              and ((.value.body // "") | type) == "string"
                              and ((.value.body // "") | contains($marker)))] as $marks
| ($issue.state) as $state
| ($last.event // null) as $le
| ($last | if . == null then null else login end) as $la
| { number: $n, state: $state, pr: ($issue | has("pull_request")),
    last_event: $le, last_actor: $la, markers: ($marks | length),
    closed_by_bot: ($state == "closed" and $le == "closed" and $la == $bot
                    and any($marks[]; .key > $lastreopen)),
    reopened_by_human: ($state == "open" and ($marks | length) > 0 and $le == "reopened" and $la != $bot),
    consistent: (if $le == null then $state == "open"
                 elif $le == "closed" then $state == "closed" else $state == "open" end),
    hash: ($marks | last | if . == null then null
           else (.value.body | [scan("issue-evidence-bot: row-sha256=([0-9a-f]{64})")] | last | if . == null then null else .[0] end) end) }
'

# read_issue N: sets FACTS (see FACTS_JQ) from a fresh read of issue N. A
# failed or malformed read is a refusal: the script exits 1, never guesses.
FACTS=""
read_issue() {
  local n="$1"
  gh api "repos/$REPO/issues/$n" >"$TMPD/issue.json" 2>"$TMPD/gh.err" ||
    refuse "could not read issue #$n: $(head -c 300 "$TMPD/gh.err")"
  # A pull request has no issue history to read; it is never acted on.
  if jq -e 'type == "object" and has("pull_request")' "$TMPD/issue.json" >/dev/null 2>&1; then
    FACTS='{"pr":true}'
    return 0
  fi
  gh api --paginate "repos/$REPO/issues/$n/timeline?per_page=100" >"$TMPD/timeline.json" 2>"$TMPD/gh.err" ||
    refuse "could not read the timeline of #$n: $(head -c 300 "$TMPD/gh.err")"
  FACTS="$(jq -c -n --argjson n "$n" --arg bot "$BOT" --arg marker "$MARKER" \
    --slurpfile issue "$TMPD/issue.json" --slurpfile pages "$TMPD/timeline.json" \
    '($issue[0]) as $issue | '"$FACTS_JQ" 2>"$TMPD/jq.err")" ||
    refuse "unreadable state for #$n: $(head -c 300 "$TMPD/jq.err")"
}
fact() { jq -r --arg k "$1" '.[$k]' <<<"$FACTS"; }

cmd_states() {
  local n
  parse_opts "$@"
  need_repo_opt states
  { [ -n "$EVAL_FILE" ] && [ -f "$EVAL_FILE" ]; } || fail_input "states needs --evaluated FILE (an existing file)"
  jq -r '.issue' "$EVAL_FILE" >"$TMPD/numbers" || fail_input "--evaluated: not JSON Lines"
  : >"$TMPD/states.jsonl"
  # Nothing is printed until every issue has been read: a failed read exits
  # (refuse) with no partial table, so `decide` never sees a guess.
  sort -n -u "$TMPD/numbers" >"$TMPD/numbers.sorted"
  while IFS= read -r n; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || fail_input "--evaluated: issue '$n' is not a positive integer"
    read_issue "$n"
    if [ "$(fact pr)" = true ]; then
      echo "::warning::ledger row #$n names a pull request, not an issue; it is never acted on." >&2
      continue
    fi
    if [ "$(fact consistent)" != true ]; then
      echo "::warning::#$n is $(fact state) but its newest close/reopen event is '$(fact last_event)': the history disagrees with the state, so nothing is decided for it this run." >&2
      continue
    fi
    jq -c '{number, state, closed_by_bot, reopened_by_human}' <<<"$FACTS" >>"$TMPD/states.jsonl"
  done <"$TMPD/numbers.sorted"
  jq -c -s . "$TMPD/states.jsonl"
}

cmd_select() {
  local total planned
  parse_opts "$@"
  need_max_actions
  { [ -n "$DECISIONS" ] && [ -f "$DECISIONS" ]; } || fail_input "select needs --decisions FILE (an existing file)"
  jq -c 'select(.action != "none")' "$DECISIONS" >"$TMPD/actions.jsonl" || fail_input "--decisions: not JSON Lines"
  total="$(grep -c . "$TMPD/actions.jsonl" || true)"
  head -n "$MAX_ACTIONS" "$TMPD/actions.jsonl"
  planned=$((total < MAX_ACTIONS ? total : MAX_ACTIONS))
  if [ -n "$COUNTS" ]; then echo "$total $planned" >"$COUNTS"; fi
}

# summary LINE...: to the job summary when there is one, else to stdout.
summary() { printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }

# head_is_current: 0 when the live head of the default branch is COMMIT, 1
# when it has moved. A failed or malformed read is a refusal.
head_is_current() {
  local repo_json ref_json branch head
  repo_json="$(gh api "repos/$REPO" 2>"$TMPD/gh.err")" ||
    refuse "could not read the repository: $(head -c 300 "$TMPD/gh.err")"
  branch="$(jq -r 'if type == "object" and (.default_branch | type) == "string" and .default_branch != ""
                   then .default_branch else error("no default_branch") end' <<<"$repo_json" 2>/dev/null)" ||
    refuse "the repository read has no default branch"
  ref_json="$(gh api "repos/$REPO/git/ref/heads/$branch" 2>"$TMPD/gh.err")" ||
    refuse "could not read the head of $branch: $(head -c 300 "$TMPD/gh.err")"
  head="$(jq -r 'if type == "object" and .object.type == "commit" and (.object.sha | type) == "string"
                 then .object.sha else error("not a branch ref") end' <<<"$ref_json" 2>/dev/null)" ||
    refuse "the head of $branch is not a commit"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse "the head of $branch is not a 40-hex commit"
  LIVE_BRANCH="$branch" LIVE_HEAD="$head"
  [ "$head" = "$COMMIT" ]
}

LIVE_BRANCH="" LIVE_HEAD=""
cmd_apply() {
  local count i item n action reason body now done_n=0
  parse_opts "$@"
  need_repo_opt apply
  need_max_actions
  { [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; } || fail_input "apply needs --plan FILE (an existing file)"
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail_input "apply needs --commit SHA (the 40-hex commit the plan was made at)"
  count="$(jq 'if type == "array" then length else error("not an array") end' "$PLAN_FILE")" ||
    fail_input "--plan: not a JSON array"
  if [ "$count" -gt "$MAX_ACTIONS" ]; then
    refuse "the plan holds $count actions, more than max_actions ($MAX_ACTIONS)"
  fi
  # The plan was made from the tree at COMMIT. Runs queue and the branch can
  # move while one evaluates; act only while COMMIT is still the head. A later
  # run on the new head decides again.
  if ! head_is_current; then
    summary "## Issue evidence: applied" "" \
      "stale; nothing done. The plan was made at $COMMIT, but $LIVE_BRANCH is now at $LIVE_HEAD. A later run on the new head decides again."
    echo "stale: $LIVE_BRANCH moved from $COMMIT to $LIVE_HEAD; nothing done."
    return 0
  fi
  : >"$TMPD/applied.md"
  for ((i = 0; i < count; i++)); do
    item="$(jq -c --argjson i "$i" '.[$i]' "$PLAN_FILE")"
    n="$(jq -r .issue <<<"$item")"
    action="$(jq -r .action <<<"$item")"
    reason="$(jq -r .close_reason <<<"$item")"
    body="$(jq -r .body <<<"$item")"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || fail_input "bad issue number in plan"
    # Re-read the issue and who closed or reopened it last, right before
    # acting: the plan was made from an earlier read, a person may have acted
    # since, and two runs can be queued. A person's close or reopen is never
    # undone.
    read_issue "$n"
    if [ "$(fact pr)" != false ]; then echo "#$n is a pull request; not acting."; continue; fi
    now="$(fact state)/$(fact last_event)/$(fact last_actor)"
    case "$action" in
      close)
        if [ "$(fact consistent)" != true ] || [ "$(fact state)" != open ]; then
          echo "#$n is now $now; not closing."
          continue
        fi
        if [ "$(fact reopened_by_human)" = true ]; then
          echo "#$n was reopened by $(fact last_actor) after the bot closed it; not closing."
          continue
        fi
        gh issue close "$n" --repo "$REPO" --reason "$reason" --comment "$body" ||
          refuse "closing #$n failed; $done_n of $count planned action(s) were performed"
        ;;
      reopen)
        if [ "$(fact closed_by_bot)" != true ]; then
          echo "#$n is now $now, not a close by this bot; not reopening."
          continue
        fi
        gh issue reopen "$n" --repo "$REPO" --comment "$body" ||
          refuse "reopening #$n failed; $done_n of $count planned action(s) were performed"
        ;;
      *) fail_input "unknown action in plan: $action" ;;
    esac
    done_n=$((done_n + 1))
    echo "| #$n | $action |" >>"$TMPD/applied.md"
  done
  {
    echo "## Issue evidence: applied"
    echo
    echo "$done_n of $count planned action(s) performed."
    if [ -s "$TMPD/applied.md" ]; then
      echo
      echo "| Issue | Action |"
      echo "|---|---|"
      cat "$TMPD/applied.md"
    fi
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

for t in gh jq; do
  command -v "$t" >/dev/null 2>&1 || { printf '%s: %s not found on PATH\n' "$PROG" "$t" >&2; exit 1; }
done
TMPD="$(mktemp -d)"
trap 'rm -rf -- "$TMPD"' EXIT

[ "$#" -ge 1 ] || fail_input "usage: $PROG states|select|apply [OPTIONS]"
sub="$1"
shift
case "$sub" in
  states) cmd_states "$@" ;;
  select) cmd_select "$@" ;;
  apply) cmd_apply "$@" ;;
  *) fail_input "unknown subcommand: $sub" ;;
esac
