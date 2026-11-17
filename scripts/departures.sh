#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# departures.sh — the departures ledger: the issue-evidence mechanism turned
# round (owner decision, 2026-11-17). Doctrine: 3-practice/DEPARTURES.adoc.
#
# WHY THIS EXISTS
#   The standing rule in .claude/CLAUDE.md says an agent that meets a departure
#   from a ruling fixes it or tells the owner. A departure that cannot be fixed
#   on the spot (licence edits are owner-only; A2ML waits for a translator)
#   used to be written as prose in a plan page, which goes stale. A row in
#   .machine_readable/departures.jsonl says "this departure exists, and these
#   machine-checkable facts show it". While every check holds the departure is
#   PRESENT. When a check stops holding the departure is gone, the row is
#   RESOLVED, and `check` fails until the row is deleted (`prune` deletes it).
#   No issue is opened and nothing goes stale.
#
# ONE CHECK ENGINE. The check vocabulary and its evaluation belong to
# scripts/issue-evidence.sh and are not duplicated here. For each departures
# row this script writes one row of an issue-evidence ledger to a temp file
# (issue = the departures line number; the row's own `checks` array, verbatim;
# fixed placeholders for the other fields) and runs that script's public
# commands on it: `validate` for the checks' schema, and `evaluate` for the
# verdicts (one {holds, failed, unevaluated, issue, ...} record per row). So a
# check means exactly what it means in 3-practice/ISSUE-EVIDENCE.adoc §2, here
# with "holds" read as "the departure is still there". issue-evidence.sh is
# taken from this script's own directory.
#
# SUBCOMMANDS (LEDGER defaults to .machine_readable/departures.jsonl)
#   validate [LEDGER]
#       Schema only; never reads the git tree. Each error names the line.
#   report [--ref REV] [--repo OWNER/NAME] [LEDGER]
#       One line per evaluated row, then a summary with counts and the
#       denominator. Exits 0 whatever the verdicts, and also when the ledger
#       is malformed (it prints the errors and an INVALID summary).
#   check [--ref REV] [--repo OWNER/NAME] [LEDGER]
#       The gate. Fails (1) when a row is RESOLVED: the departure is gone, so
#       the row is stale and must be deleted. Fails (2) when the ledger is
#       malformed. A present or unevaluated row passes.
#   prune [--ref REV] [--repo OWNER/NAME] [LEDGER]
#       Deletes exactly the rows `check` reports RESOLVED, through the same
#       decision, with the shared writer scripts/lib/ledger-prune.sh. Every
#       other line is kept byte for byte; no row is added or edited; a second
#       run removes nothing. Keeps the shrink-only ledger prune contract
#       (docs/wikis/maintainers/index.adoc, "Shrink-only ledgers"): a
#       malformed ledger is refused (1) and left untouched; usage and internal
#       errors exit 2. Prints on stdout, one line per removed row, then a summary:
#         prune: delete LEDGER:LINE: ID [RESOLVED: <checks> no longer holds]
#         prune: LEDGER: N line(s) deleted, 0 count(s) lowered
#       (LINE numbers the file as it was before; the id stands for the row),
#       or "prune: LEDGER: nothing stale".
#   --repo evaluates only the rows of that repository (case-insensitive); the
#   others are counted as not evaluated and are never pruned.
#
# VERDICTS (from the evaluate record of the row's checks at REV)
#   present      every check holds (holds = true)
#   RESOLVED     some check no longer holds (holds = false); named by index
#   unevaluated  none fails, one could not be evaluated (holds = null): a
#                `script` check runs only when REV is the checked-out commit
#                and the checkout is exactly that commit, as in issue-evidence.
#
# The ledger file is read from the working tree; the checks are read at REV.
#
# EXIT
#   0  done (check: no RESOLVED row; prune: the RESOLVED rows are gone)
#   1  check: a RESOLVED row. prune: refused, the ledger is malformed
#   2  check, report, validate: invalid ledger or invalid input (usage).
#      prune: invalid input (usage) or an internal error (the contract has no 3)
#   3  internal error (no jq/git, not a git repository, REV does not resolve);
#      not used by prune, which reports these as 2
#
# TESTS: scripts/tests/departures-test.sh
set -euo pipefail
export LC_ALL=C

PROG="departures.sh"
DEFAULT_LEDGER=".machine_readable/departures.jsonl"
IE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue-evidence.sh"

# usage: prints the SUBCOMMANDS block of this header to stderr.
usage() {
  sed -n '/^# SUBCOMMANDS/,/^# VERDICTS/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
}
# fail_input MESSAGE: an invalid ledger or invalid input; exit 2.
fail_input() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}
# fail_internal MESSAGE: the tool could not run; exit INTERNAL_RC (3, or 2 for prune).
INTERNAL_RC=3
fail_internal() {
  printf '%s: internal error: %s\n' "$PROG" "$*" >&2
  exit "$INTERNAL_RC"
}

TMPD=""
# cleanup: removes the temp directory on exit.
cleanup() {
  if [ -n "$TMPD" ]; then rm -rf -- "$TMPD"; fi
}
trap cleanup EXIT

# need_tools: checks the tools and issue-evidence.sh exist; creates TMPD.
need_tools() {
  local t
  for t in jq git grep awk cmp mktemp; do
    command -v "$t" >/dev/null 2>&1 || fail_internal "$t not found on PATH"
  done
  [ -f "$IE" ] || fail_internal "issue-evidence.sh not found beside this script: $IE"
  TMPD="$(mktemp -d)" || fail_internal "mktemp failed"
}

# --- validation ---------------------------------------------------------------

# Input: the ledger's raw lines (-R). Output, NUL-separated pairs: "E" LINE
# MESSAGE (an error) and "S" LINE ROW (the issue-evidence row that carries this
# line's checks; a placeholder check when the line has no usable checks array,
# whose error is already reported here).
# shellcheck disable=SC2016  # jq program text, not shell
VALIDATE_JQ='
def ctrl: explode | any(. < 32 or . == 127);
def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
def keyset($req; $opt):
  (($req - keys)[] | "missing field \"\(.)\""),
  ((keys - $req - $opt)[] | "unknown field \"\(.)\"");
def text($f; $v; $max):
  if ($v | type) != "string" then "\($f) must be a string"
  elif $v == "" then "\($f) is empty"
  elif ($v | ctrl) then "\($f) contains a control character (newline, tab, NUL and DEL are refused)"
  elif ($v | contains("<!--")) or ($v | contains("-->")) then "\($f) contains an HTML comment delimiter"
  elif ($v | length) > $max then "\($f) is longer than \($max) characters"
  else empty end;
def row:
  if type != "object" then "the line is not a JSON object"
  else
    keyset(["added", "checks", "claim", "fix", "id", "repo", "ruling"]; ["blocked_on"]),
    (if (.id | type) == "string" and (.id | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and (.id | length) <= 64
     then empty else "id must be a lower-case slug (a-z, 0-9, single hyphens), at most 64 characters" end),
    (if (.repo | type) == "string" and (.repo | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"))
        and (.repo | split("/")[1] | . != "." and . != "..")
     then empty else "repo must be OWNER/NAME" end),
    text("ruling"; .ruling; 200),
    text("claim"; .claim; 600),
    (if .fix | IN("owner-only", "blocked", "open") then empty
     else "fix is not in the vocabulary: \(.fix | tojson)" end),
    (if .fix == "blocked" then
       (if has("blocked_on") then text("blocked_on"; .blocked_on; 300)
        else "fix blocked requires blocked_on" end)
     elif has("blocked_on") then "blocked_on is allowed only with fix blocked"
     else empty end),
    (if (.added | type) == "string" and (.added | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and ((.added | try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch "") == .added)
     then empty else "added must be a real calendar date YYYY-MM-DD" end),
    (if (.checks | type) != "array" or (.checks | length) == 0 then "checks must be a non-empty array"
     else empty end)
  end;
def carrier($n; $v):
  {added: "2026-11-17", claim: "departures.sh carrier row", disposition: "moot",
   evidence: ["departures.sh"], issue: $n, repo: "departures/ledger",
   checks: (if ($v | type) == "object" and ($v.checks | type) == "array" and ($v.checks | length) > 0
            then $v.checks else [{kind: "path-present", path: "x"}] end)} | canon;
def emit($tag; $n; $v): $tag, "\u0000", ($n | tostring), "\u0000", $v, "\u0000";
[inputs] | to_entries
| map(
    (.key + 1) as $n | .value as $raw
    | if $raw == "" then {n: $n, errors: ["blank line"], v: null}
      else
        (try {ok: true, v: ($raw | fromjson)} catch {ok: false}) as $p
        | if ($p.ok | not) then {n: $n, errors: ["not a single JSON value"], v: null}
          else $p.v as $v
          | {n: $n, v: $v,
             errors: ([$v | row]
                      + (if ($v | canon) == $raw then []
                         else ["not JCS canonical (RFC 8785); the canonical line is \($v | canon)"] end)),
             key: (if ($v | type) == "object" and ($v.id | type) == "string" then $v.id else null end)}
          end
      end)
| reduce .[] as $r ({seen: {}, out: []};
    if $r.key != null and .seen[$r.key] != null
    then .seen[$r.key] as $first
      | .out += [$r | .errors += ["duplicate id: the same id is already on line \($first)"]]
    else (if $r.key != null then .seen[$r.key] = $r.n else . end) | .out += [$r] end)
| .out[]
| . as $r
| ($r.errors[] as $e | emit("E"; $r.n; $e)),
  emit("S"; $r.n; carrier($r.n; $r.v))
'

# validate_ledger FILE [NAME]: prints one error per line to stderr, each naming
# NAME (default FILE) and the line; returns 1 when the ledger is invalid.
# Writes $TMPD/carrier.jsonl (one issue-evidence row per ledger line) as a
# side product. Never reads the git tree.
validate_ledger() {
  local file="$1" ledger="${2:-$1}" bad=0 i tag n val rc stream line
  if [ ! -f "$file" ]; then
    printf '%s: ledger not found\n' "$ledger" >&2
    return 1
  fi
  # I-JSON on the bytes, as issue-evidence.sh checks its own ledger: no NUL,
  # valid UTF-8, and (JSON-POLICY J-2) every record ends in a line feed.
  if [ "$(tr -d '\000' <"$file" | wc -c)" != "$(wc -c <"$file")" ]; then
    printf '%s: contains a NUL byte\n' "$ledger" >&2
    return 1
  fi
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '%s:%s: missing final line feed (JSON-POLICY J-2)\n' "$ledger" "$(($(wc -l <"$file") + 1))" >&2
    bad=1
  fi
  while IFS= read -r n; do
    printf '%s:%s: not valid UTF-8 (I-JSON, RFC 7493)\n' "$ledger" "${n%%:*}" >&2
    bad=1
  done < <(LC_ALL=C.UTF-8 grep -a -n -x -v '.*' "$file" || true)
  jq -n -R -j "$VALIDATE_JQ" <"$file" >"$TMPD/validate.stream" 2>"$TMPD/validate.err" ||
    fail_internal "jq could not run the schema program: $(head -c 300 "$TMPD/validate.err")"
  mapfile -d '' -t stream <"$TMPD/validate.stream"
  : >"$TMPD/carrier.jsonl"
  for ((i = 0; i + 2 < ${#stream[@]}; i += 3)); do
    tag="${stream[i]}" n="${stream[i + 1]}" val="${stream[i + 2]}"
    case "$tag" in
      E)
        printf '%s:%s: %s\n' "$ledger" "$n" "$val" >&2
        bad=1
        ;;
      S) printf '%s\n' "$val" >>"$TMPD/carrier.jsonl" ;;
    esac
  done
  # The checks: issue-evidence.sh validates them; its errors name the carrier
  # file and the same line number, and are re-addressed to LEDGER.
  rc=0
  bash "$IE" validate "$TMPD/carrier.jsonl" 2>"$TMPD/ie-validate.err" || rc=$?
  case "$rc" in
    0) ;;
    2)
      while IFS= read -r line; do
        case "$line" in
          "$TMPD/carrier.jsonl:"*) printf '%s:%s\n' "$ledger" "${line#"$TMPD/carrier.jsonl:"}" >&2 ;;
          *) printf '%s\n' "$line" >&2 ;;
        esac
      done <"$TMPD/ie-validate.err"
      bad=1
      ;;
    *) fail_internal "issue-evidence.sh validate exited $rc: $(head -c 300 "$TMPD/ie-validate.err")" ;;
  esac
  [ "$bad" -eq 0 ]
}

# --- classification -------------------------------------------------------------

# Joins the ledger rows and the evaluate records into one JCS line per
# evaluated row: {n (the ledger line), id, fix, status, named: the checks that
# no longer hold (RESOLVED) or were not evaluated, as "[i] kind path"}.
# The ONE decision used by report, check and prune.
# shellcheck disable=SC2016  # jq program text, not shell
CLASSIFY_JQ='
($rows | to_entries | map({key: (.key + 1 | tostring), value: .value}) | from_entries) as $byline
| $ev[]
| . as $r
| $byline[$r.issue | tostring] as $row
| (.holds == false) as $resolved
| (.holds == true) as $present
| (if $resolved then "RESOLVED" elif $present then "present" else "unevaluated" end) as $status
| {n: $r.issue, id: $row.id, fix: $row.fix, status: $status,
   named: [ (if $status == "RESOLVED" then $r.failed elif $status == "unevaluated" then $r.unevaluated else [] end)[]
            | . as $i | $row.checks[$i]
            | "[\($i)] \(.kind) \(.path // .glob // .sha)" ]}
'

# classify LEDGER: for a ledger validate_ledger accepted (it wrote the carrier
# rows), evaluates the selected rows at $REF and writes
# $TMPD/classified.jsonl. Sets TOTAL, EVALUATED_N and COMMIT.
classify() {
  local ledger="$1" rc=0 keep
  keep="$(jq -r -n --arg r "$REPO_FILTER" '
    [inputs] | to_entries[]
    | select($r == "" or (.value.repo | ascii_downcase) == ($r | ascii_downcase))
    | .key + 1' "$ledger" | tr '\n' ' ')" || fail_internal "jq could not select rows"
  awk -v keep=" $keep" 'index(keep, " " FNR " ") > 0' "$TMPD/carrier.jsonl" >"$TMPD/carrier-selected.jsonl"
  bash "$IE" evaluate --ref "$REF" "$TMPD/carrier-selected.jsonl" >"$TMPD/evaluated.jsonl" 2>"$TMPD/ie-evaluate.err" || rc=$?
  case "$rc" in
    0) ;;
    3) fail_internal "$(sed 's/^issue-evidence\.sh: internal error: //' "$TMPD/ie-evaluate.err" | head -c 300)" ;;
    *) fail_internal "issue-evidence.sh evaluate exited $rc: $(head -c 300 "$TMPD/ie-evaluate.err")" ;;
  esac
  jq -c -S -n --slurpfile rows "$ledger" --slurpfile ev "$TMPD/evaluated.jsonl" "$CLASSIFY_JQ" \
    >"$TMPD/classified.jsonl" || fail_internal "jq could not join the evaluate records"
  TOTAL="$(grep -c '' "$ledger" || true)"
  EVALUATED_N="$(grep -c '' "$TMPD/classified.jsonl" || true)"
  COMMIT="$(git rev-parse --verify --quiet --end-of-options "$REF^{commit}" 2>/dev/null)" ||
    fail_internal "ref does not resolve to a commit: $REF"
}

# print_rows: one report line per classified row.
print_rows() {
  jq -r '
    [.status, (" " * (13 - (.status | length))), .id, "  [", .fix, "]",
     (if .status == "RESOLVED" then "  no longer holds: " + (.named | join(", "))
      elif .status == "unevaluated" then "  not evaluated: " + (.named | join(", "))
      else "" end)] | join("")' "$TMPD/classified.jsonl"
}

# summary: the counts line, with the denominator and the evaluated commit.
summary() {
  jq -r -s --arg total "$TOTAL" --arg n "$EVALUATED_N" --arg c "${COMMIT:0:12}" --arg r "$REPO_FILTER" '
    "departures: \($n) of \($total) rows evaluated at \($c)"
    + (if $r != "" then " (rows of \($r) only)" else "" end)
    + ": \(map(select(.status == "present")) | length) present, "
    + "\(map(select(.status == "RESOLVED")) | length) RESOLVED, "
    + "\(map(select(.status == "unevaluated")) | length) unevaluated."' "$TMPD/classified.jsonl"
}

# --- subcommands --------------------------------------------------------------

REPO_FILTER="" REF="HEAD"
LEDGER_ARG=()
# parse_opts ARGS...: sets REPO_FILTER, REF and LEDGER from --repo, --ref, LEDGER.
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || fail_input "--repo needs a value"; REPO_FILTER="$2"; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || fail_input "--ref needs a value"; REF="$2"; shift 2 ;;
      --) shift; LEDGER_ARG+=("$@"); break ;;
      -*) fail_input "unknown option: $1" ;;
      *) LEDGER_ARG+=("$1"); shift ;;
    esac
  done
  [ "${#LEDGER_ARG[@]}" -le 1 ] || fail_input "at most one LEDGER"
  LEDGER="${LEDGER_ARG[0]:-$DEFAULT_LEDGER}"
  if [ -n "$REPO_FILTER" ] && ! [[ "$REPO_FILTER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    fail_input "--repo must be OWNER/NAME"
  fi
}

# need_repo: the commands read git, so they run inside a work tree.
need_repo() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || fail_internal "not inside a git work tree"
}

# snapshot: the bytes every later step reads, so validation, evaluation and a
# prune all see one version of the file.
snapshot() {
  [ -f "$LEDGER" ] || { printf '%s: ledger not found\n' "$LEDGER" >&2; exit 2; }
  cp -- "$LEDGER" "$TMPD/ledger.jsonl" || fail_internal "cannot read $LEDGER"
}

# cmd_validate [LEDGER]: schema only; exit 0 or 2.
cmd_validate() {
  [ "$#" -le 1 ] || fail_input "validate takes at most one LEDGER"
  LEDGER="${1:-$DEFAULT_LEDGER}"
  need_repo
  validate_ledger "$LEDGER" || exit 2
  printf '%s: %s rows valid\n' "$LEDGER" "$(grep -c '' "$LEDGER" || true)" >&2
}

# cmd_report [OPTIONS] [LEDGER]: one line per row and a summary; exit 0.
cmd_report() {
  parse_opts "$@"
  need_repo
  snapshot
  if ! validate_ledger "$TMPD/ledger.jsonl" "$LEDGER"; then
    printf 'departures: %s is INVALID; no row was evaluated (run: %s validate %s).\n' "$LEDGER" "$PROG" "$LEDGER"
    return 0
  fi
  classify "$TMPD/ledger.jsonl"
  print_rows
  summary
}

# cmd_check [OPTIONS] [LEDGER]: the gate; exit 1 on a RESOLVED row, 2 on a malformed ledger.
cmd_check() {
  local stale
  parse_opts "$@"
  need_repo
  snapshot
  if ! validate_ledger "$TMPD/ledger.jsonl" "$LEDGER"; then
    exit 2
  fi
  classify "$TMPD/ledger.jsonl"
  stale="$(jq -r --arg l "$LEDGER" --arg p "$PROG" 'select(.status == "RESOLVED")
    | "\($l):\(.n): \(.id): RESOLVED (\(.named | join(", ")) no longer holds): the departure is gone; delete the row (\($p) prune)"' \
    "$TMPD/classified.jsonl")"
  summary >&2
  if [ -n "$stale" ]; then
    printf '%s\n' "$stale" >&2
    exit 1
  fi
}

# cmd_prune [OPTIONS] [LEDGER]: deletes the rows cmd_check reports RESOLVED, and nothing else.
cmd_prune() {
  local plan wrote rc=0
  parse_opts "$@"
  need_repo
  snapshot
  if ! validate_ledger "$TMPD/ledger.jsonl" "$LEDGER"; then
    printf '%s: prune refused: the ledger is malformed; nothing was changed\n' "$PROG" >&2
    exit 1
  fi
  classify "$TMPD/ledger.jsonl"
  # The plan for the shared writer: delete each RESOLVED line, shown by its id.
  plan="$(jq -r 'select(.status == "RESOLVED") | .n as $n
    | "\($n)\tdelete\t\tRESOLVED: \(.named | join(", ")) no longer holds\t\(.id)"' "$TMPD/classified.jsonl")"
  if [ -z "$plan" ]; then
    printf 'prune: %s: nothing stale\n' "$LEDGER"
    return 0
  fi
  printf '%s\n' "$plan" >"$TMPD/plan.tsv"
  cp -- "$TMPD/ledger.jsonl" "$TMPD/judged.jsonl" || fail_internal "cannot copy the snapshot"
  # shellcheck source=SCRIPTDIR/lib/ledger-prune.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/ledger-prune.sh" || fail_internal "scripts/lib/ledger-prune.sh not found beside this script"
  wrote="$(ledger_prune_apply "$TMPD/ledger.jsonl" "$LEDGER" "$TMPD/plan.tsv")" || rc=$?
  [ "$rc" -eq 0 ] || fail_internal "the ledger writer refused the plan (exit $rc); nothing was changed"
  # The file must still be the bytes that were judged.
  cmp -s -- "$LEDGER" "$TMPD/judged.jsonl" || fail_internal "$LEDGER changed while it was being pruned; nothing was changed"
  cat -- "$TMPD/ledger.jsonl" >"$LEDGER" || fail_internal "cannot write $LEDGER"
  printf '%s\n' "$wrote"
}

# main SUBCOMMAND ARGS...: dispatch.
main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"
  shift
  # prune keeps the ledger prune contract: setup errors are 2, never 3.
  if [ "$sub" = prune ]; then INTERNAL_RC=2; fi
  need_tools
  case "$sub" in
    validate) cmd_validate "$@" ;;
    report) cmd_report "$@" ;;
    check) cmd_check "$@" ;;
    prune) cmd_prune "$@" ;;
    -h | --help | help) usage ;;
    *) usage; fail_input "unknown subcommand: $sub" ;;
  esac
}

main "$@"
