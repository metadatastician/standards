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
#       input of `issue-evidence.sh decide`. A pull request is never listed.
#   select --decisions FILE --max-actions N [--counts FILE]
#       The actions to plan this run: the decided closes and reopens, in
#       order, at most N of them (N from 0 to 50). --counts receives
#       "TOTAL PLANNED".
#   apply --repo OWNER/NAME --plan FILE --max-actions N
#       Performs the plan (a JSON array of {issue, action, close_reason,
#       body}) with `gh issue close` / `gh issue reopen`, re-reading each
#       issue's state just before acting.
#
# The bot's identity is one value, BOT below: the login the workflow's token
# acts as (github-actions[bot] for GITHUB_TOKEN). --bot LOGIN overrides it.
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

REPO="" EVAL_FILE="" DECISIONS="" MAX_ACTIONS="" COUNTS="" PLAN_FILE=""
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
  gh api --paginate "repos/$REPO/issues/$n/timeline?per_page=100" >"$TMPD/timeline.json" 2>"$TMPD/gh.err" ||
    refuse "could not read the timeline of #$n: $(head -c 300 "$TMPD/gh.err")"
  FACTS="$(jq -c -n --argjson n "$n" --arg bot "$BOT" --arg marker "$MARKER" \
    --slurpfile issue "$TMPD/issue.json" --slurpfile pages "$TMPD/timeline.json" \
    '($issue[0]) as $issue | '"$FACTS_JQ" 2>"$TMPD/jq.err")" ||
    refuse "unreadable state for #$n: $(head -c 300 "$TMPD/jq.err")"
}
fact() { jq -r --arg k "$1" '.[$k]' <<<"$FACTS"; }

cmd_states() {
  local n issue state closed_by markers last closed_by_bot reopened_by_human
  parse_opts "$@"
  need_repo_opt states
  { [ -n "$EVAL_FILE" ] && [ -f "$EVAL_FILE" ]; } || fail_input "states needs --evaluated FILE (an existing file)"
  for n in $(jq -r '.issue' "$EVAL_FILE" | sort -n -u); do
    issue="$(gh api "repos/$REPO/issues/$n")"
    if [ "$(jq 'has("pull_request")' <<<"$issue")" = true ]; then
      echo "::warning::ledger row #$n names a pull request, not an issue; it is never acted on." >&2
      continue
    fi
    state="$(jq -r .state <<<"$issue")"
    closed_by="$(jq -r '.closed_by.login // ""' <<<"$issue")"
    markers="$(gh api --paginate "repos/$REPO/issues/$n/comments?per_page=100" |
      jq -r --arg bot "$BOT" --arg marker "$MARKER" \
        '.[] | select(.user.login == $bot and (.body | contains($marker))) | .id' | grep -c . || true)"
    closed_by_bot=false
    reopened_by_human=false
    if [ "$state" = closed ] && [ "$closed_by" = "$BOT" ] && [ "$markers" -gt 0 ]; then
      closed_by_bot=true
    fi
    if [ "$state" = open ] && [ "$markers" -gt 0 ]; then
      last="$(gh api --paginate "repos/$REPO/issues/$n/events?per_page=100" |
        jq -r '.[] | select(.event == "closed" or .event == "reopened") | [.event, (.actor.login // "")] | @tsv' | tail -n 1)"
      if [ "${last%%$'\t'*}" = reopened ] && [ "${last#*$'\t'}" != "$BOT" ]; then
        reopened_by_human=true
      fi
    fi
    jq -c -n --argjson number "$n" --arg state "$state" \
      --argjson cbb "$closed_by_bot" --argjson rbh "$reopened_by_human" \
      '{number: $number, state: $state, closed_by_bot: $cbb, reopened_by_human: $rbh}'
  done | jq -c -s .
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

cmd_apply() {
  local count i item n action reason body now done_n=0
  parse_opts "$@"
  need_repo_opt apply
  need_max_actions
  { [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; } || fail_input "apply needs --plan FILE (an existing file)"
  count="$(jq 'if type == "array" then length else error("not an array") end' "$PLAN_FILE")" ||
    fail_input "--plan: not a JSON array"
  if [ "$count" -gt "$MAX_ACTIONS" ]; then
    refuse "the plan holds $count actions, more than max_actions ($MAX_ACTIONS)"
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
    now="$(fact state)/$(fact last_event)/$(fact last_actor)"
    case "$action" in
      close)
        if [ "$(fact pr)" != false ] || [ "$(fact consistent)" != true ] || [ "$(fact state)" != open ]; then
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
        if [ "$(fact pr)" != false ] || [ "$(fact closed_by_bot)" != true ]; then
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
