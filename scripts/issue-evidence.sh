#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# issue-evidence.sh — the issue-evidence ledger evaluator (the "closer bot").
#
# WHY THIS EXISTS
#   In this repository fixes land and the issue stays open: squash merges drop
#   `Fixes #N` commit trailers (#958), and owner rulings supersede issues with
#   nobody writing that back. Two manual triages did not move the count. The
#   owner ruled that an issue's open/closed state is a FUNCTION of evidence on
#   the default branch. A row in .machine_readable/issue-evidence.jsonl says
#   "issue N is done (or moot) because these machine-checkable facts hold".
#   The owner approves a closure by merging the row in a reviewed PR; the
#   workflow closes the issue while the facts hold, and reopens an issue IT
#   closed when they stop holding. Doctrine: 3-practice/ISSUE-EVIDENCE.adoc.
#
# THIS SCRIPT IS A TOTAL, SIDE-EFFECT-FREE FUNCTION of (ledger, git tree at a
# ref). It never calls the network and never writes to the repository. The
# GitHub reads and writes live in scripts/issue-evidence-apply.sh, which
# .github/workflows/issue-evidence-reusable.yml calls (caller:
# .github/workflows/issue-evidence.yml).
#
# SUBCOMMANDS (LEDGER defaults to .machine_readable/issue-evidence.jsonl)
#   validate [LEDGER]
#       Schema check against the closed vocabulary, length bounds included.
#       Each error names the line. It never reads the git tree (and works
#       outside a repository), so one row cannot invalidate the ledger by
#       naming a script that is later deleted: evaluation reports that check
#       as failed (a regression) and still evaluates every other row.
#   lint [LEDGER]
#       validate, and also: every `script` check names a file tracked at HEAD
#       with the executable bit. For a pull request author before merge (the
#       test suite runs it on the live ledger); the bot does not need it.
#   evaluate [--repo OWNER/NAME] [--ref REF] [LEDGER]
#       One JCS line per row (ledger order): {disposition, failed, holds,
#       issue, repo, unevaluated}. holds is true when every check holds, false
#       when any check fails, null when none fails but one could not be
#       evaluated. failed/unevaluated are 0-based check indices.
#       Script checks apart (one of these at a time; evaluate only):
#       --no-scripts      run no script. A script check whose script is
#                         tracked and executable at REF is unevaluated, and
#                         each record also lists such checks in `deferred`.
#       --scripts-only    run only the script checks, and print one JCS
#                         script result per script check whose script is
#                         tracked and executable at REF:
#                         {blob, check, issue, outcome, path, repo}, blob the
#                         script's blob id at REF, outcome holds|failed|
#                         unevaluated. Nothing else is evaluated. Refuses
#                         (exit 2, nothing printed) when the results could
#                         exceed 65,536 bytes, before any script runs.
#       --script-results FILE
#                         run no script: take each script check's outcome
#                         from FILE, script result records as --scripts-only
#                         prints them. FILE is checked first, and the whole
#                         run is refused (exit 2, nothing printed) unless it
#                         is at most 65,536 bytes of UTF-8 and every line is
#                         a JCS record of that closed schema that matches a
#                         real script check of a row of --repo at REF (same
#                         repo, issue, check, path and blob), each at most
#                         once. A script check with no record is unevaluated.
#       In every mode a script that is not tracked and executable at REF is
#       a failed check, decided from the tree. `evaluate` then equals
#       `--scripts-only` followed by `--script-results` (the test suite
#       checks it on every row).
#   decide --repo OWNER/NAME --open FILE [--evaluated FILE | --ref REF] [LEDGER]
#       Pure decision table. FILE is a JSON array of {number, state} with
#       state open|closed, closed_by_bot (bool) for closed issues, and
#       optionally reopened_by_human (bool) for open ones. One JCS line per
#       row: {action: close|reopen|none, disposition, issue, reason, repo}.
#       --repo is required: FILE describes that repository's issues by
#       number, so rows (or --evaluated records) of any other repository
#       are dropped and never yield an action.
#   render-comment --issue N --action close|reopen [--repo R] [--ref REF]
#                  [--evaluated FILE] [--commit SHA] [LEDGER]
#       The Markdown comment for a close or reopen. Its last line is the
#       marker <!-- issue-evidence-bot: row-sha256=HASH --> (HASH = sha256 of
#       the row's ledger line), by which the workflow recognises its own work.
#       --commit SHA (a full commit id, with --evaluated) names the evaluated
#       commit as data instead of resolving --ref: no git repository is read,
#       which is how the workflow's apply job renders from a fetched ledger.
#   candidates --log FILE --open FILE [--repo R] [LEDGER]
#       REPORT ONLY. Open issues with no ledger row that commits mention, most
#       mentioned first. FILE is `git log --format='%H%x09%s%x09%b%x1e'`.
#
# CHECKS ARE EVALUATED AT THE REF, NOT IN THE WORKING TREE. Every check reads
# the committed tree through git (ls-tree, cat-file, grep at the commit,
# merge-base). The one exception is `script`, which must run in a checkout and
# may read any file there: it runs only when REF is the checked-out commit and
# the checkout is exactly that commit (no staged, unstaged or hidden change to
# a tracked file, and no untracked file the .gitignore files do not ignore),
# and is otherwise UNEVALUATED (null), never guessed. Ignored files are not
# compared: a script that reads one reads something outside the commit.
#
# SAFETY BOUNDARY (why no ledger value is ever code)
#   Issue #1405 is about `eval` in test helpers: a value that reaches eval,
#   `sh -c` or an unquoted expansion is a program, whoever wrote it. A ledger
#   row is reviewed prose about evidence, and this tool must not reintroduce
#   that class. So:
#   * no value from a row is ever passed to eval, `sh -c`, `bash -c`, a
#     here-doc that is executed, or an unquoted expansion;
#   * a `pattern` reaches grep / git grep only as the single argument after
#     -e, so a leading "-" is a pattern, not an option;
#   * a `path` reaches git only inside "COMMIT:PATH" or as the single argument
#     after `--` with literal pathspecs; a `glob` only after `--`, prefixed
#     with the :(glob) magic this script chooses (a glob that starts with ":"
#     is refused, so a row cannot pick its own pathspec magic);
#   * `script` runs a path tracked in git under scripts/ or tests/, executable
#     in git, with NO arguments (a row cannot carry `args`), never through a
#     shell string: a row chooses which reviewed script runs, nothing else;
#   * control characters (newline, tab, NUL, DEL) are refused in every string,
#     so a value cannot split a grep pattern list or forge a comment line.
#   scripts/tests/issue-evidence-test.sh plants $(…), backticks, `; rm -rf`,
#   leading "-" and newlines in every string field and asserts no side effect.
#
# JCS (RFC 8785, 3-practice/JSON-POLICY.adoc J-1/J-2) is checked with jq: a
# line is canonical when it equals its parse re-serialised with sorted keys.
# That is exact for this schema because it is closed (ASCII keys only), its one
# number must be written as a plain integer, and control characters, which jq
# and JCS escape differently (DEL), are refused. The ijson-jcs workflow checks
# the same file with the reference tool.
#
# EXIT
#   0  done (evaluate: evaluation completed, whatever the rows' verdicts)
#   2  invalid ledger or invalid input (usage, malformed --open/--evaluated/--log)
#   3  internal error (no jq/git, not a git repository, REF does not resolve)
#
# Test seam: ISSUE_EVIDENCE_SCRIPT_TIMEOUT (seconds, default 300) bounds a
# `script` check; a timeout is UNEVALUATED.
#
# TESTS: scripts/tests/issue-evidence-test.sh
#
# CONSUMER: scripts/departures.sh (3-practice/DEPARTURES.adoc) evaluates the
# checks of its rows with this script and has no check engine of its own. It
# writes an ordinary ledger of this schema and relies on: `validate` errors of
# the form "LEDGER:LINE: message" on stderr with exit 2, and the `evaluate`
# record {disposition, failed, holds, issue, repo, unevaluated}, one per row
# in ledger order. scripts/tests/departures-test.sh exercises both.
set -euo pipefail
export LC_ALL=C
# Pathspec behaviour is chosen here, never inherited from the caller.
unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

PROG="issue-evidence.sh"
DEFAULT_LEDGER=".machine_readable/issue-evidence.jsonl"
SCRIPT_TIMEOUT="${ISSUE_EVIDENCE_SCRIPT_TIMEOUT:-300}"

usage() {
  sed -n '/^# SUBCOMMANDS/,/^# CHECKS ARE/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
}
fail_input() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}
fail_internal() {
  printf '%s: internal error: %s\n' "$PROG" "$*" >&2
  exit 3
}

TMPD=""
cleanup() {
  if [ -n "$TMPD" ]; then rm -rf -- "$TMPD"; fi
}
trap cleanup EXIT

need_tools() {
  local t
  for t in jq git grep sha256sum timeout mktemp; do
    command -v "$t" >/dev/null 2>&1 || fail_internal "$t not found on PATH"
  done
  TMPD="$(mktemp -d)" || fail_internal "mktemp failed"
}

need_repo() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_internal "not inside a git work tree"
}

# --- validation ---------------------------------------------------------------

# The closed vocabulary, as a jq program. Input: the ledger's raw lines (-R).
# Output, NUL-separated triples: "E" LINE MESSAGE (an error), "P" LINE PATTERN
# (an ERE to compile), "S" LINE PATH (a script that must be tracked).
# shellcheck disable=SC2016  # jq program text, not shell
VALIDATE_JQ='
def ctrl: explode | any(. < 32 or . == 127);
def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
def keyset($req; $opt):
  (($req - keys)[] | "missing field \"\(.)\""),
  ((keys - $req - $opt)[] | "unknown field \"\(.)\"");
def text($f; $v):
  if ($v | type) != "string" then "\($f) must be a string"
  elif $v == "" then "\($f) is empty"
  elif ($v | ctrl) then "\($f) contains a control character (newline, tab, NUL and DEL are refused)"
  else empty end;
def nocomment($f; $v):
  if ($v | type) == "string" and (($v | contains("<!--")) or ($v | contains("-->")))
  then "\($f) contains an HTML comment delimiter" else empty end;
def relpath($f; $v):
  if ($v | type) != "string" or $v == "" then "\($f) must be a non-empty string"
  elif ($v | ctrl) then "\($f) contains a control character (newline, tab, NUL and DEL are refused)"
  elif ($v | startswith("/")) then "\($f) is absolute: \($v | tojson)"
  elif ($v | startswith("-")) then "\($f) starts with \"-\": \($v | tojson)"
  elif ($v | split("/") | any(. == "" or . == "." or . == "..")) then "\($f) has an empty, \".\" or \"..\" component: \($v | tojson)"
  else empty end;
def posint: type == "number" and (tojson | test("^[1-9][0-9]*$")) and . <= 9007199254740991;
# Length bounds, in characters. They keep every comment the bot renders under
# the GitHub limit of 65,536 characters (the test suite renders the worst-case
# row) and keep the plan the workflow hands between its jobs small.
def longer($f; $v; $n):
  if ($v | type) == "string" and ($v | length) > $n then "\($f) is longer than \($n) characters" else empty end;
def toomany($f; $v; $n):
  if ($v | type) == "array" and ($v | length) > $n then "\($f) has more than \($n) items" else empty end;
def checkbounds($i):
  objects | "checks[\($i)]" as $p
  | longer("\($p).path"; .path; 256), longer("\($p).glob"; .glob; 256), longer("\($p).pattern"; .pattern; 400);
def check($i):
  "checks[\($i)]" as $p
  | if type != "object" then "\($p) is not an object"
    elif (.kind | type) != "string" then "\($p).kind is missing or not a string"
    elif .kind == "path-absent" or .kind == "path-present" then
      (keyset(["kind", "path"]; []) | "\($p): \(.)"), relpath("\($p).path"; .path)
    elif .kind == "grep-absent" or .kind == "grep-present" then
      (keyset(["kind", "path", "pattern"]; []) | "\($p): \(.)"),
      relpath("\($p).path"; .path), text("\($p).pattern"; .pattern)
    elif .kind == "tree-grep-absent" then
      (keyset(["glob", "kind", "pattern"]; []) | "\($p): \(.)"),
      relpath("\($p).glob"; .glob),
      (if (.glob | type) == "string" and (.glob | startswith(":"))
       then "\($p).glob starts with \":\" (a row cannot choose pathspec magic)" else empty end),
      text("\($p).pattern"; .pattern)
    elif .kind == "commit-on-main" then
      (keyset(["kind", "sha"]; []) | "\($p): \(.)"),
      (if (.sha | type) == "string" and (.sha | test("^[0-9a-f]{12,40}$")) then empty
       else "\($p).sha must be 12 to 40 lower-case hex digits" end)
    elif .kind == "script" then
      (keyset(["kind", "path"]; []) | "\($p): \(.)"),
      relpath("\($p).path"; .path),
      (if (.path | type) == "string" and ((.path | startswith("scripts/")) or (.path | startswith("tests/")))
       then empty else "\($p).path must be under scripts/ or tests/" end)
    else "\($p).kind is not in the vocabulary: \(.kind | tojson)" end;
def row:
  if type != "object" then "the line is not a JSON object"
  else
    keyset(["added", "checks", "claim", "disposition", "evidence", "issue", "repo"]; ["duplicate_of"]),
    (if (.issue | posint) then empty
     else "issue must be a positive integer written without sign, fraction or exponent" end),
    (if (.repo | type) == "string" and (.repo | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"))
        and (.repo | split("/")[1] | . != "." and . != "..")
     then empty else "repo must be OWNER/NAME" end),
    (if (.disposition | IN("landed", "superseded", "moot", "duplicate", "expired")) then empty
     else "disposition is not in the vocabulary: \(.disposition | tojson)" end),
    text("claim"; .claim), nocomment("claim"; .claim), longer("claim"; .claim; 1500),
    (if (.evidence | type) != "array" or (.evidence | length) == 0
     then "evidence must be a non-empty array of strings"
     else .evidence | to_entries[] | text("evidence[\(.key)]"; .value), nocomment("evidence[\(.key)]"; .value),
       longer("evidence[\(.key)]"; .value; 400) end),
    toomany("evidence"; .evidence; 16), toomany("checks"; .checks; 16),
    (if (.added | type) == "string" and (.added | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and ((.added | try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch "") == .added)
     then empty else "added must be a real calendar date YYYY-MM-DD" end),
    (if .disposition == "duplicate" then
       (if (.duplicate_of | posint) and .duplicate_of != .issue then empty
        else "disposition duplicate requires duplicate_of: a positive integer other than issue" end)
     elif has("duplicate_of") then "duplicate_of is allowed only with disposition duplicate"
     else empty end),
    (if (.checks | type) != "array" or (.checks | length) == 0 then "checks must be a non-empty array"
     else .checks | to_entries[] | .key as $i | .value | check($i), checkbounds($i) end)
  end;
def emit($tag; $n; $v): $tag, "\u0000", ($n | tostring), "\u0000", $v, "\u0000";
[inputs] | to_entries
| map(
    (.key + 1) as $n | .value as $raw
    | if $raw == "" then {n: $n, errors: ["blank line"]}
      else
        (try {ok: true, v: ($raw | fromjson)} catch {ok: false}) as $p
        | if ($p.ok | not) then {n: $n, errors: ["not a single JSON value"]}
          else $p.v as $v
          | {n: $n,
             errors: ([$v | row]
                      + (if ($v | canon) == $raw then []
                         else ["not JCS canonical (RFC 8785); the canonical line is \($v | canon)"] end)),
             key: (if ($v | type) == "object" and ($v.repo | type) == "string" and ($v.issue | type) == "number"
                   then "\($v.repo | ascii_downcase)#\($v.issue)" else null end),
             patterns: [$v | objects | .checks? | arrays | .[] | objects
                        | select(.kind == "grep-absent" or .kind == "grep-present" or .kind == "tree-grep-absent")
                        | .pattern | strings | select(ctrl | not)],
             scripts: [$v | objects | .checks? | arrays | .[] | objects | select(.kind == "script")
                       | .path | strings | select(ctrl | not)]}
          end
      end)
| reduce .[] as $r ({seen: {}, out: []};
    if $r.key != null and .seen[$r.key] != null
    then .seen[$r.key] as $first
      | .out += [$r | .errors += ["duplicate (repo, issue): the same issue is already on line \($first)"]]
    else (if $r.key != null then .seen[$r.key] = $r.n else . end) | .out += [$r] end)
| .out[]
| . as $r
| ($r.errors[] as $e | emit("E"; $r.n; $e)),
  ($r.patterns[]? as $x | emit("P"; $r.n; $x)),
  ($r.scripts[]? as $x | emit("S"; $r.n; $x))
'

# entry_at COMMIT PATH: sets E_MODE, E_TYPE, E_OID for PATH in COMMIT's tree.
# Returns 1 when the path is absent. The path is passed after `--` with literal
# pathspecs, so it is a name, never an option or pathspec magic.
entry_at() {
  local out
  E_MODE="" E_TYPE="" E_OID=""
  out="$(GIT_LITERAL_PATHSPECS=1 git ls-tree -z "$1" -- "$2" 2>/dev/null | tr '\0' '\n')" || return 1
  out="${out%%$'\n'*}"
  [ -n "$out" ] || return 1
  [ "${out#*$'\t'}" = "$2" ] || return 1
  read -r E_MODE E_TYPE E_OID <<<"${out%%$'\t'*}"
  return 0
}

# validate_ledger LEDGER [SCRIPTS_AT]: prints one error per line to stderr;
# returns 1 when the ledger is invalid. Schema validation never reads the git
# tree, so a script deleted or renamed after its row merged cannot make the
# whole ledger invalid: evaluation reports that check as FAILED. Only `lint`
# passes SCRIPTS_AT (a commit), adding "each script check names a tracked,
# executable file there" for a pull request author to see before merge.
validate_ledger() {
  local ledger="$1" scripts_at="${2:-}" bad=0 i tag n val rc stream
  if [ ! -f "$ledger" ]; then
    printf '%s: ledger not found\n' "$ledger" >&2
    return 1
  fi
  # I-JSON: the file is UTF-8 with no NUL byte, and (J-2) every record ends in
  # a line feed. jq would read past both, so they are checked on the bytes.
  if [ -s "$ledger" ] && [ "$(tail -c 1 "$ledger" | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '%s:%s: missing final line feed (JSON-POLICY J-2)\n' "$ledger" "$(($(wc -l <"$ledger") + 1))" >&2
    bad=1
  fi
  if [ "$(tr -d '\000' <"$ledger" | wc -c)" != "$(wc -c <"$ledger")" ]; then
    printf '%s: contains a NUL byte\n' "$ledger" >&2
    return 1
  fi
  while IFS= read -r n; do
    printf '%s:%s: not valid UTF-8 (I-JSON, RFC 7493)\n' "$ledger" "${n%%:*}" >&2
    bad=1
  done < <(LC_ALL=C.UTF-8 grep -a -n -x -v '.*' "$ledger" || true)
  if ! jq -n -R -j "$VALIDATE_JQ" <"$ledger" >"$TMPD/validate.stream" 2>"$TMPD/validate.err"; then
    fail_internal "jq could not run the schema program: $(head -c 300 "$TMPD/validate.err")"
  fi
  mapfile -d '' -t stream <"$TMPD/validate.stream"
  for ((i = 0; i + 2 < ${#stream[@]}; i += 3)); do
    tag="${stream[i]}" n="${stream[i + 1]}" val="${stream[i + 2]}"
    case "$tag" in
      E)
        printf '%s:%s: %s\n' "$ledger" "$n" "$val" >&2
        bad=1
        ;;
      P)
        rc=0
        grep -E -q -e "$val" </dev/null 2>/dev/null || rc=$?
        if [ "$rc" -ge 2 ]; then
          printf '%s:%s: pattern is not a valid POSIX ERE: %s\n' "$ledger" "$n" "$(jq -n --arg v "$val" '$v')" >&2
          bad=1
        fi
        ;;
      S)
        [ -n "$scripts_at" ] || continue
        if ! entry_at "$scripts_at" "$val" || [ "$E_TYPE" != blob ]; then
          printf '%s:%s: script %s is not tracked in git at HEAD\n' "$ledger" "$n" "$(jq -n --arg v "$val" '$v')" >&2
          bad=1
        elif [ "$E_MODE" != 100755 ]; then
          printf '%s:%s: script %s is tracked without the executable bit (mode %s)\n' "$ledger" "$n" "$(jq -n --arg v "$val" '$v')" "$E_MODE" >&2
          bad=1
        fi
        ;;
    esac
  done
  [ "$bad" -eq 0 ]
}

# --- evaluation ---------------------------------------------------------------

# Per row, NUL-separated: repo, issue, disposition, check count, then per
# check: kind, path|glob|sha, pattern.
# shellcheck disable=SC2016  # jq program text, not shell
ROW_STREAM_JQ='
def z: ., "\u0000";
(.repo | z), (.issue | tostring | z), (.disposition | z), (.checks | length | tostring | z),
(.checks[] | (.kind | z), ((.path // .glob // .sha) | z), ((.pattern // "") | z))
'

# Check results: 0 holds, 1 does not hold, 2 not evaluated.

check_path() { # KIND PATH
  if entry_at "$COMMIT" "$2"; then
    [ "$1" = path-present ] && return 0 || return 1
  fi
  [ "$1" = path-absent ] && return 0 || return 1
}

check_grep() { # KIND PATH PATTERN
  local rc=0
  # The file must exist as a regular file: absence of a match in a file that
  # is not there proves nothing (use path-absent to assert a removal).
  entry_at "$COMMIT" "$2" || return 1
  case "$E_MODE" in 100644 | 100755) ;; *) return 1 ;; esac
  git cat-file blob "$E_OID" >"$TMPD/blob" 2>/dev/null || return 2
  grep -E -q -e "$3" -- "$TMPD/blob" 2>/dev/null || rc=$?
  case "$rc" in
    0) [ "$1" = grep-present ] && return 0 || return 1 ;;
    1) [ "$1" = grep-absent ] && return 0 || return 1 ;;
    *) return 2 ;;
  esac
}

check_tree_grep_absent() { # GLOB PATTERN
  local spec=":(glob)$1" rc=0
  # The glob must select at least one non-empty tracked file: a mistyped glob
  # must not read as "nothing matches".
  git -c grep.lineNumber=false grep -q -E -e '' "$COMMIT" -- "$spec" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  rc=0
  git -c grep.lineNumber=false grep -q -E -e "$2" "$COMMIT" -- "$spec" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

check_commit_on_main() { # SHA
  local cands=() c commits=() rc=0
  # A shallow clone cannot tell "not an ancestor" from "not fetched".
  [ "$SHALLOW" = false ] || return 2
  mapfile -t cands < <(git rev-parse --disambiguate="$1" 2>/dev/null || true)
  for c in "${cands[@]}"; do
    [ "$(git cat-file -t "$c" 2>/dev/null || true)" = commit ] && commits+=("$c")
  done
  case "${#commits[@]}" in
    0) return 1 ;;
    1) ;;
    *) return 2 ;; # an ambiguous prefix is not evidence
  esac
  git merge-base --is-ancestor "${commits[0]}" "$COMMIT" 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# checkout_is_commit: 0 when the working tree and index are exactly HEAD's
# tree: no staged or unstaged change to a tracked file, no index entry that
# hides a change (assume-unchanged, skip-worktree) or is unmerged, and no
# untracked file except one the checkout's .gitignore files ignore. Neither
# core.excludesFile nor .git/info/exclude is honoured, so a file hidden only
# by a personal exclude still counts as untracked.
checkout_is_commit() {
  git -C "$ROOT" diff --quiet --no-ext-diff --no-textconv HEAD -- 2>/dev/null || return 1
  git -C "$ROOT" diff --cached --quiet --no-ext-diff --no-textconv HEAD -- 2>/dev/null || return 1
  # `ls-files -v` tags a plain entry "H "; every other tag is refused.
  [ -z "$(git -C "$ROOT" ls-files -z -v | tr '\0' '\n' | grep -v '^H ' | head -c 1)" ] || return 1
  [ -z "$(git -C "$ROOT" ls-files -z --others --exclude-per-directory=.gitignore | head -c 1)" ] || return 1
}

# script_tracked PATH: 0 when PATH is a tracked, executable regular file AT
# THE EVALUATED COMMIT (E_OID is then its blob id); 1 when it is not, which is
# a FAILED check; 2 for a path outside scripts/ and tests/.
script_tracked() {
  # Only explicitly allowlisted repository scripts are runnable.
  # This prevents ledger data from triggering arbitrary code execution.
  case "$1" in
    scripts/*|tests/*) ;;
    *) return 2 ;;
  esac
  # Read from the commit, so absence (deleted, renamed, never added) or a lost
  # executable bit is a FAILED check (a regression) whichever commit is checked
  # out and in every script mode, never an invalid ledger and never "not
  # evaluated". No script runs to decide it.
  entry_at "$COMMIT" "$1" || return 1
  [ "$E_TYPE" = blob ] && [ "$E_MODE" = 100755 ] || return 1
}

# run_script PATH: runs a tracked script (script_tracked held) in the checkout.
run_script() {
  local path="$1" rc=0
  # A script runs in the checkout and may read any file there, so it counts
  # as evidence only when the checkout IS the evaluated commit: HEAD is that
  # commit and checkout_is_commit holds. Re-checked before every script, so a
  # script that litters the checkout leaves the later ones unevaluated.
  [ "$COMMIT" = "$HEAD_COMMIT" ] || return 2
  checkout_is_commit || return 2
  # No argument: nothing from the ledger reaches the script's argv.
  (cd "$ROOT" && timeout "$SCRIPT_TIMEOUT" "./$path" </dev/null >&2) || rc=$?
  # 0 holds. 2 is this estate's "could not run", 77 is a skip (the automake
  # convention: a test that ran nothing, e.g. a missing toolchain), and 124+
  # is a timeout or a signal: none of them is evidence either way, so the
  # check is unevaluated and the bot neither closes nor reopens on it.
  case "$rc" in
    0) return 0 ;;
    2 | 77) return 2 ;;
    *) [ "$rc" -ge 124 ] && return 2 || return 1 ;;
  esac
}

# check_script PATH INDEX: a script check of the row eval_row is reading
# (R_REPO, R_ISSUE), by SCRIPT_MODE:
#   run       run the script (the default);
#   none      never run it: 3 (unevaluated, reported as `deferred`);
#   supplied  never run it: the outcome loaded by load_script_results, or 2
#             (unevaluated) when none was supplied.
# In every mode a script that is not tracked and executable at the commit is
# a failed check (script_tracked), decided from the tree alone.
check_script() {
  local rc=0
  script_tracked "$1" || return $?
  case "$SCRIPT_MODE" in
    run) run_script "$1" || rc=$?; return "$rc" ;;
    none) return 3 ;;
    supplied)
      case "${SUPPLIED["$R_REPO#$R_ISSUE#$2"]:-}" in
        holds) return 0 ;;
        failed) return 1 ;;
        *) return 2 ;;
      esac
      ;;
    *) fail_internal "check_script in script mode $SCRIPT_MODE" ;;
  esac
}

# eval_row LINE: sets R_REPO R_ISSUE R_DISP R_HOLDS R_FAILED R_UNEVAL and
# R_DEFERRED (JSON). R_DEFERRED lists the script checks SCRIPT_MODE none did
# not run; they are in R_UNEVAL too.
eval_row() {
  local f=() k=0 nchecks i kind a pat rc any_false=0 any_null=0
  local failed=() uneval=() deferred=()
  printf '%s\n' "$1" | jq -j "$ROW_STREAM_JQ" >"$TMPD/row.stream" || fail_internal "jq could not read a validated row"
  mapfile -d '' -t f <"$TMPD/row.stream"
  R_REPO="${f[0]}" R_ISSUE="${f[1]}" R_DISP="${f[2]}" nchecks="${f[3]}"
  k=4
  for ((i = 0; i < nchecks; i++)); do
    kind="${f[k]}" a="${f[k + 1]}" pat="${f[k + 2]}"
    k=$((k + 3))
    rc=0
    case "$kind" in
      path-absent | path-present) check_path "$kind" "$a" || rc=$? ;;
      grep-absent | grep-present) check_grep "$kind" "$a" "$pat" || rc=$? ;;
      tree-grep-absent) check_tree_grep_absent "$a" "$pat" || rc=$? ;;
      commit-on-main) check_commit_on_main "$a" || rc=$? ;;
      script) check_script "$a" "$i" || rc=$? ;;
      *) fail_internal "unvalidated check kind reached evaluation" ;;
    esac
    case "$rc" in
      0) ;;
      1) any_false=1; failed+=("$i") ;;
      3) any_null=1; uneval+=("$i"); deferred+=("$i") ;;
      *) any_null=1; uneval+=("$i") ;;
    esac
  done
  if [ "$any_false" -eq 1 ]; then R_HOLDS=false
  elif [ "$any_null" -eq 1 ]; then R_HOLDS=null
  else R_HOLDS=true; fi
  R_FAILED="[$(IFS=,; printf '%s' "${failed[*]}")]"
  R_UNEVAL="[$(IFS=,; printf '%s' "${uneval[*]}")]"
  R_DEFERRED="[$(IFS=,; printf '%s' "${deferred[*]}")]"
}

# resolve_ref REF: sets COMMIT, HEAD_COMMIT, SHALLOW.
resolve_ref() {
  COMMIT="$(git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null)" ||
    fail_internal "ref does not resolve to a commit: $1"
  HEAD_COMMIT="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  SHALLOW="$(git rev-parse --is-shallow-repository 2>/dev/null)" || fail_internal "git rev-parse failed"
}

# in_repo_filter LINE: 0 when the row is of --repo (or there is no --repo).
in_repo_filter() {
  printf '%s\n' "$1" | jq -e --arg r "$REPO_FILTER" \
    '$r == "" or (.repo | ascii_downcase) == ($r | ascii_downcase)' >/dev/null
}

# evaluate_into LEDGER OUT: writes the evaluate output for LEDGER to OUT. With
# SCRIPT_MODE none each record also carries `deferred`.
evaluate_into() {
  local ledger="$1" out="$2" line
  : >"$out"
  [ "$SCRIPT_MODE" != supplied ] || load_script_results "$ledger"
  while IFS= read -r line; do
    in_repo_filter "$line" || continue
    eval_row "$line"
    jq -c -n -S --arg repo "$R_REPO" --argjson issue "$R_ISSUE" --arg disposition "$R_DISP" \
      --argjson holds "$R_HOLDS" --argjson failed "$R_FAILED" --argjson unevaluated "$R_UNEVAL" \
      --argjson deferred "$R_DEFERRED" --arg mode "$SCRIPT_MODE" \
      '{repo: $repo, issue: $issue, disposition: $disposition, holds: $holds, failed: $failed, unevaluated: $unevaluated}
       + (if $mode == "none" then {deferred: $deferred} else {} end)' >>"$out"
  done <"$ledger"
}

# --- script checks apart from the rest (--scripts-only, --script-results) -------
#
# The workflow runs the ledger's scripts in a job of their own, which holds no
# issue permission and whose only product is one outcome per script check, and
# builds the plan in another job that runs no code of the evaluated
# repository. These two modes are the two halves; their meeting point is a
# SCRIPT RESULT record, one JCS line per script check:
#   {blob, check, issue, outcome, path, repo}
# blob is the script's blob id at the commit, check the 0-based check index,
# outcome holds|failed|unevaluated. Only a script check whose script is
# tracked and executable at the commit has a record: the tree alone decides
# the others (failed), in every mode.

# Cap on the script results, in bytes (each record is under 450 bytes).
SCRIPT_RESULTS_MAX_BYTES=65536

# script_checks_into LEDGER OUT: one JCS line {blob, check, issue, path, repo}
# per script check, of the rows of --repo, whose script is tracked and
# executable at COMMIT. Nothing is run.
script_checks_into() {
  local ledger="$1" out="$2" line f=() k nchecks i
  : >"$out"
  while IFS= read -r line; do
    in_repo_filter "$line" || continue
    printf '%s\n' "$line" | jq -j "$ROW_STREAM_JQ" >"$TMPD/row.stream" || fail_internal "jq could not read a validated row"
    mapfile -d '' -t f <"$TMPD/row.stream"
    nchecks="${f[3]}" k=4
    for ((i = 0; i < nchecks; i++)); do
      if [ "${f[k]}" = script ] && script_tracked "${f[k + 1]}"; then
        jq -c -n -S --arg blob "$E_OID" --argjson check "$i" --argjson issue "${f[1]}" \
          --arg path "${f[k + 1]}" --arg repo "${f[0]}" \
          '{blob: $blob, check: $check, issue: $issue, path: $path, repo: $repo}' >>"$out"
      fi
      k=$((k + 3))
    done
  done <"$ledger"
}

# run_scripts_into LEDGER OUT: runs every script check script_checks_into
# lists, and writes its script result record. Refuses (exit 2, nothing
# written) when the records exceed SCRIPT_RESULTS_MAX_BYTES.
run_scripts_into() {
  local ledger="$1" out="$2" rec path rc outcome bound
  script_checks_into "$ledger" "$TMPD/script-checks.jsonl"
  # The largest the results can be is known before any script runs (each
  # record gains at most `,"outcome":"unevaluated"`, 24 bytes): refuse first.
  bound=$(($(wc -c <"$TMPD/script-checks.jsonl") + 24 * $(grep -c '' "$TMPD/script-checks.jsonl" || true)))
  if [ "$bound" -gt "$SCRIPT_RESULTS_MAX_BYTES" ]; then
    fail_input "the script results could reach $bound bytes, over $SCRIPT_RESULTS_MAX_BYTES; refusing to run the scripts"
  fi
  : >"$TMPD/script-results.jsonl"
  while IFS= read -r rec; do
    path="$(jq -r .path <<<"$rec")"
    rc=0
    run_script "$path" || rc=$?
    case "$rc" in 0) outcome=holds ;; 1) outcome=failed ;; *) outcome=unevaluated ;; esac
    jq -c -S --arg o "$outcome" '. + {outcome: $o}' <<<"$rec" >>"$TMPD/script-results.jsonl"
  done <"$TMPD/script-checks.jsonl"
  if [ "$(wc -c <"$TMPD/script-results.jsonl")" -gt "$SCRIPT_RESULTS_MAX_BYTES" ]; then
    fail_input "the script results exceed $SCRIPT_RESULTS_MAX_BYTES bytes; refusing to emit them"
  fi
  cp "$TMPD/script-results.jsonl" "$out"
}

# The trusted boundary: a supplied script result is used only if it is
# exactly a script result record (closed schema, JCS, known outcome) of a
# real script check at this commit, at most once.
# shellcheck disable=SC2016  # jq program text, not shell
SCRIPT_RESULTS_JQ='
def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
def natural: type == "number" and (tojson | test("^(0|[1-9][0-9]*)$"));
($exp | map({key: "\(.repo)#\(.issue)#\(.check)", value: .}) | from_entries) as $want
| [inputs] | to_entries
| map((.key + 1) as $n | .value as $raw
    | if $raw == "" then {n: $n, err: "blank line"}
      else (try {ok: true, v: ($raw | fromjson)} catch {ok: false}) as $p
      | if ($p.ok | not) then {n: $n, err: "not a single JSON value"}
        else $p.v as $v
        | if ($v | type) != "object" then {n: $n, err: "not a JSON object"}
          elif ($v | keys) != ["blob", "check", "issue", "outcome", "path", "repo"]
            then {n: $n, err: "the fields must be exactly blob, check, issue, outcome, path, repo"}
          elif ($v.outcome | IN("holds", "failed", "unevaluated") | not)
            then {n: $n, err: "outcome must be holds, failed or unevaluated"}
          elif ($v.check | natural | not) or ($v.issue | natural | not) or ($v.issue == 0)
            then {n: $n, err: "check and issue must be integers written plainly"}
          elif (($v.blob | type) != "string") or (($v.path | type) != "string") or (($v.repo | type) != "string")
            then {n: $n, err: "blob, path and repo must be strings"}
          elif ($v | canon) != $raw then {n: $n, err: "not JCS canonical"}
          elif $want["\($v.repo)#\($v.issue)#\($v.check)"] != ($v | del(.outcome))
            then {n: $n, err: "matches no script check of the ledger at this commit (repo, issue, check, path and blob)"}
          else {n: $n, key: "\($v.repo)#\($v.issue)#\($v.check)", outcome: $v.outcome} end
        end
      end)
| reduce .[] as $r ({seen: {}, out: []};
    if $r.key != null and .seen[$r.key] != null
    then .out += [{n: $r.n, err: "duplicate: the same script check is already on line \(.seen[$r.key])"}]
    else (if $r.key != null then .seen[$r.key] = $r.n else . end) | .out += [$r] end)
| .out
| if any(.[]; has("err")) then (.[] | select(has("err")) | "E\t\(.n)\t\(.err)")
  else (.[] | "K\t\(.key)\t\(.outcome)") end
'

# load_script_results LEDGER: fills SUPPLIED (key REPO#ISSUE#CHECK, value the
# outcome) from SCRIPT_RESULTS_FILE, or refuses (exit 2, nothing emitted).
declare -A SUPPLIED=()
load_script_results() {
  local file="$SCRIPT_RESULTS_FILE" tag a b bad=0 n
  [ -f "$file" ] || fail_input "--script-results file not found: $file"
  [ "$(wc -c <"$file")" -le "$SCRIPT_RESULTS_MAX_BYTES" ] ||
    fail_input "--script-results: larger than $SCRIPT_RESULTS_MAX_BYTES bytes"
  [ "$(tr -d '\000' <"$file" | wc -c)" = "$(wc -c <"$file")" ] || fail_input "--script-results: contains a NUL byte"
  while IFS= read -r n; do
    printf '%s:%s: not valid UTF-8\n' "$file" "${n%%:*}" >&2
    bad=1
  done < <(LC_ALL=C.UTF-8 grep -a -n -x -v '.*' "$file" || true)
  [ "$bad" -eq 0 ] || exit 2
  script_checks_into "$1" "$TMPD/script-checks.jsonl"
  jq -n -R -r --slurpfile exp "$TMPD/script-checks.jsonl" "$SCRIPT_RESULTS_JQ" <"$file" \
    >"$TMPD/script-results.checked" 2>"$TMPD/script-results.err" ||
    fail_internal "jq could not check the script results: $(head -c 300 "$TMPD/script-results.err")"
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      E) printf '%s:%s: %s\n' "$file" "$a" "$b" >&2; bad=1 ;;
      K) SUPPLIED["$a"]="$b" ;;
      *) fail_internal "unexpected line from the script results check" ;;
    esac
  done <"$TMPD/script-results.checked"
  if [ "$bad" -ne 0 ]; then
    SUPPLIED=()
    exit 2
  fi
}

# --- subcommands --------------------------------------------------------------

# validate reads no git tree (it works outside a repository, as in the
# workflow's apply job, which checks nothing out).
cmd_validate() {
  [ "$#" -le 1 ] || fail_input "validate takes at most one LEDGER"
  local ledger="${1:-$DEFAULT_LEDGER}"
  validate_ledger "$ledger" || exit 2
  printf '%s: %s rows valid\n' "$ledger" "$(grep -c '' "$ledger" || true)" >&2
}

cmd_lint() {
  [ "$#" -le 1 ] || fail_input "lint takes at most one LEDGER"
  local ledger="${1:-$DEFAULT_LEDGER}" head
  need_repo
  head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || fail_internal "HEAD does not resolve to a commit"
  validate_ledger "$ledger" "$head" || exit 2
  printf '%s: %s rows valid; every script check names a tracked, executable file at HEAD\n' \
    "$ledger" "$(grep -c '' "$ledger" || true)" >&2
}

REPO_FILTER="" REF="HEAD" OPEN_FILE="" EVAL_FILE="" LOG_FILE="" ISSUE="" ACTION=""
SCRIPT_MODE="run" SCRIPT_RESULTS_FILE="" COMMIT_ARG=""
LEDGER_ARG=()
# set_script_mode MODE OPTION: the script options exclude one another.
set_script_mode() {
  [ "$SCRIPT_MODE" = run ] || fail_input "$2: --no-scripts, --scripts-only and --script-results exclude one another"
  SCRIPT_MODE="$1"
}
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || fail_input "--repo needs a value"; REPO_FILTER="$2"; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || fail_input "--ref needs a value"; REF="$2"; shift 2 ;;
      --open) [ "$#" -ge 2 ] || fail_input "--open needs a value"; OPEN_FILE="$2"; shift 2 ;;
      --evaluated) [ "$#" -ge 2 ] || fail_input "--evaluated needs a value"; EVAL_FILE="$2"; shift 2 ;;
      --log) [ "$#" -ge 2 ] || fail_input "--log needs a value"; LOG_FILE="$2"; shift 2 ;;
      --issue) [ "$#" -ge 2 ] || fail_input "--issue needs a value"; ISSUE="$2"; shift 2 ;;
      --action) [ "$#" -ge 2 ] || fail_input "--action needs a value"; ACTION="$2"; shift 2 ;;
      --no-scripts) set_script_mode none "$1"; shift ;;
      --scripts-only) set_script_mode only "$1"; shift ;;
      --script-results)
        [ "$#" -ge 2 ] || fail_input "--script-results needs a value"
        set_script_mode supplied "$1"; SCRIPT_RESULTS_FILE="$2"; shift 2 ;;
      --commit) [ "$#" -ge 2 ] || fail_input "--commit needs a value"; COMMIT_ARG="$2"; shift 2 ;;
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
# only_for SUBCOMMAND: refuses the options that belong to another subcommand.
only_for() {
  if [ "$1" != evaluate ] && [ "$SCRIPT_MODE" != run ]; then
    fail_input "--no-scripts, --scripts-only and --script-results are options of evaluate only"
  fi
  if [ "$1" != render-comment ] && [ -n "$COMMIT_ARG" ]; then
    fail_input "--commit is an option of render-comment only"
  fi
}

cmd_evaluate() {
  parse_opts "$@"
  only_for evaluate
  need_repo
  validate_ledger "$LEDGER" || exit 2
  resolve_ref "$REF"
  if [ "$SCRIPT_MODE" = only ]; then
    run_scripts_into "$LEDGER" "$TMPD/script-results.out"
    cat "$TMPD/script-results.out"
    return 0
  fi
  evaluate_into "$LEDGER" "$TMPD/evaluated.jsonl"
  cat "$TMPD/evaluated.jsonl"
}

# shellcheck disable=SC2016  # jq program text, not shell
CHECK_EVALUATED_JQ='
def posint: type == "number" and . == floor and . >= 1;
if type == "object" and (.issue | posint) and (.repo | type) == "string"
   and (.holds == true or .holds == false or .holds == null)
   and (.disposition | type) == "string" and (.failed | type) == "array"
   and (.unevaluated | type) == "array"
then . else error("--evaluated: line \(input_line_number) is not an evaluate record") end
'

# load_evaluated: sets EVALUATED (a file of evaluate records) from --evaluated
# or by evaluating LEDGER at --ref.
load_evaluated() {
  if [ -n "$EVAL_FILE" ]; then
    [ -f "$EVAL_FILE" ] || fail_input "--evaluated file not found: $EVAL_FILE"
    jq -c "$CHECK_EVALUATED_JQ" "$EVAL_FILE" >"$TMPD/evaluated.jsonl" 2>"$TMPD/check-evaluated.err" ||
      fail_input "$(head -c 300 "$TMPD/check-evaluated.err")"
  else
    need_repo
    validate_ledger "$LEDGER" || exit 2
    resolve_ref "$REF"
    evaluate_into "$LEDGER" "$TMPD/evaluated.jsonl"
  fi
  EVALUATED="$TMPD/evaluated.jsonl"
}

# shellcheck disable=SC2016  # jq program text, not shell
DECIDE_JQ='
def posint: type == "number" and . == floor and . >= 1;
($open[0]) as $o
| if ($o | type) != "array" then error("--open: not a JSON array") else . end
| ($o | map(
    if type != "object" or (.number | posint | not) then error("--open: an entry has no positive integer number")
    elif (.state != "open" and .state != "closed") then error("--open: issue \(.number): state must be open or closed")
    elif .state == "closed" and ((.closed_by_bot | type) != "boolean") then error("--open: issue \(.number): a closed issue needs closed_by_bot (boolean)")
    elif has("reopened_by_human") and ((.reopened_by_human | type) != "boolean") then error("--open: issue \(.number): reopened_by_human must be a boolean")
    else {key: (.number | tostring), value: .} end)) as $entries
| if ($entries | map(.key) | unique | length) != ($entries | length) then error("--open: an issue number appears twice") else . end
| ($entries | from_entries) as $state
| $ev[]
| . as $r
| $state[$r.issue | tostring] as $s
| (if $s == null then {action: "none", reason: "no-issue-state"}
   elif $r.holds == null then {action: "none", reason: "unevaluated"}
   elif $r.holds == true and $s.state == "open" and ($s.reopened_by_human // false) then {action: "none", reason: "reopened-by-human"}
   elif $r.holds == true and $s.state == "open" then {action: "close", reason: "evidence-holds"}
   elif $r.holds == true then {action: "none", reason: "already-closed"}
   elif $s.state == "open" then {action: "none", reason: "evidence-does-not-hold"}
   elif $s.closed_by_bot then {action: "reopen", reason: "regression"}
   else {action: "none", reason: "closed-by-human"} end)
| . + {issue: $r.issue, repo: $r.repo, disposition: $r.disposition}
'

cmd_decide() {
  parse_opts "$@"
  only_for decide
  [ -n "$OPEN_FILE" ] || fail_input "decide needs --open FILE"
  [ -f "$OPEN_FILE" ] || fail_input "--open file not found: $OPEN_FILE"
  # --open names one repository's issues by number only, so decide is always
  # about one repository: rows of any other repository are dropped, whether
  # the records come from --evaluated or from evaluating the ledger.
  [ -n "$REPO_FILTER" ] || fail_input "decide needs --repo OWNER/NAME (the repository --open describes)"
  load_evaluated
  jq -c --arg r "$REPO_FILTER" 'select((.repo | ascii_downcase) == ($r | ascii_downcase))' \
    "$EVALUATED" >"$TMPD/evaluated-repo.jsonl" || fail_internal "jq could not filter the evaluate records"
  jq -n -c -S --slurpfile open "$OPEN_FILE" --slurpfile ev "$TMPD/evaluated-repo.jsonl" "$DECIDE_JQ" 2>"$TMPD/decide.err" ||
    fail_input "$(head -c 300 "$TMPD/decide.err")"
}

# shellcheck disable=SC2016  # jq program text, not shell
RENDER_JQ='
def plain:
  if .kind == "path-present" then "the path \(.path | tojson) exists"
  elif .kind == "path-absent" then "the path \(.path | tojson) does not exist"
  elif .kind == "grep-present" then "some line of the file \(.path | tojson) matches the regular expression \(.pattern | tojson)"
  elif .kind == "grep-absent" then "no line of the file \(.path | tojson) matches the regular expression \(.pattern | tojson)"
  elif .kind == "tree-grep-absent" then "no tracked file matching \(.glob | tojson) has a line matching \(.pattern | tojson)"
  elif .kind == "commit-on-main" then "commit \(.sha) is an ancestor of the evaluated commit"
  elif .kind == "script" then "the tracked script \(.path | tojson) exits 0"
  else "unknown check" end;
# GitHub notifies every @name in a comment; a zero-width space after "@" keeps
# the text readable and notifies nobody.
def inert: gsub("@"; "@​");
($ev.failed // []) as $failed
| ($ev.unevaluated // []) as $uneval
| [ $row.checks | to_entries[]
    | "[\(.key)] \(.value | plain)"
      + (if $action != "reopen" then ""
         elif (.key | IN($failed[])) then " - DOES NOT HOLD"
         elif (.key | IN($uneval[])) then " - NOT EVALUATED"
         else " - holds" end) ]
  as $lines
| ([($lines | join("\n")) | scan("`+") | length] | max // 0) as $run
| ("`" * ([3, $run + 1] | max)) as $fence
| (if $action == "close" then
     "**issue-evidence:** closing this issue as **\($row.disposition)**. Every check recorded for it in `\($ledger)` holds at commit \($commit)."
   else
     "**issue-evidence:** reopening this issue. The issue-evidence bot closed it on the evidence below, and at commit \($commit) that evidence no longer holds (a regression)."
   end) as $head
| [ $head,
    "",
    "**Claim:** \($row.claim | inert)",
    "",
    (if $action == "close" then "**Checks** (each holds at \($commit)):" else "**Checks** at \($commit):" end),
    "",
    $fence,
    $lines[],
    $fence,
    "",
    "**Evidence:**",
    "",
    ($row.evidence[] | "- \(inert)"),
    "",
    (if $action == "close" then
       "The owner approved this closure by merging the ledger row. If the evidence stops holding, the bot reopens the issue. To dispute it, change or remove the row in a reviewed pull request, or reopen the issue by hand: the bot does not re-close an issue a person reopened."
     else
       "Fix the regression, or correct the ledger row in a reviewed pull request. The bot closes the issue again once every check holds."
     end),
    "",
    "<!-- issue-evidence-bot: row-sha256=\($hash) -->" ]
| join("\n")
'

cmd_render_comment() {
  local line="" l found=0 hash ev
  parse_opts "$@"
  [[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || fail_input "render-comment needs --issue N (a positive integer)"
  case "$ACTION" in close | reopen) ;; *) fail_input "render-comment needs --action close|reopen" ;; esac
  only_for render-comment
  # --commit SHA: the evaluated commit is given as data, and no git repository
  # is read (the workflow's apply job renders from a ledger it fetched). It
  # needs --evaluated, since nothing can be evaluated without the tree.
  if [ -n "$COMMIT_ARG" ]; then
    [[ "$COMMIT_ARG" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail_input "--commit must be a full commit id (40 or 64 lower-case hex digits)"
    [ -n "$EVAL_FILE" ] || fail_input "--commit needs --evaluated FILE"
  else
    need_repo
  fi
  validate_ledger "$LEDGER" || exit 2
  while IFS= read -r l; do
    if printf '%s\n' "$l" | jq -e --argjson n "$ISSUE" --arg r "$REPO_FILTER" \
      '.issue == $n and ($r == "" or (.repo | ascii_downcase) == ($r | ascii_downcase))' >/dev/null; then
      line="$l"
      found=$((found + 1))
    fi
  done <"$LEDGER"
  [ "$found" -eq 1 ] || fail_input "render-comment: expected exactly one row for issue $ISSUE${REPO_FILTER:+ in $REPO_FILTER}, found $found (pass --repo)"
  if [ -n "$COMMIT_ARG" ]; then COMMIT="$COMMIT_ARG"; else resolve_ref "$REF"; fi
  if [ -n "$EVAL_FILE" ]; then
    load_evaluated
    ev="$(jq -c -s --argjson n "$ISSUE" --arg r "$(printf '%s\n' "$line" | jq -r .repo)" \
      'map(select(.issue == $n and .repo == $r)) | if length == 1 then .[0] else error("--evaluated has no single record for this row") end' \
      "$EVALUATED" 2>"$TMPD/ev.err")" || fail_input "$(head -c 300 "$TMPD/ev.err")"
  else
    printf '%s\n' "$line" >"$TMPD/one.jsonl"
    evaluate_into "$TMPD/one.jsonl" "$TMPD/one.evaluated"
    ev="$(cat "$TMPD/one.evaluated")"
  fi
  hash="$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)"
  printf '%s\n' "$line" | jq -r --arg action "$ACTION" --arg commit "$COMMIT" --arg hash "$hash" \
    --arg ledger "$LEDGER" --argjson ev "$ev" '. as $row | '"$RENDER_JQ"
}

# shellcheck disable=SC2016  # jq program text, not shell
CANDIDATES_JQ='
def posint: type == "number" and . == floor and . >= 1;
($open[0]) as $o
| if ($o | type) != "array" then error("--open: not a JSON array") else . end
| ($repo | ascii_downcase | split("/")) as $rp
| ($o | map(select(type == "object" and (.number | posint) and .state == "open") | .number)) as $openn
| ($ledger | map(select($repo == "" or (.repo | ascii_downcase) == ($repo | ascii_downcase)) | .issue)) as $rowed
| ($openn - $rowed) as $want
# A reference is "#N", "NAME#N" or "OWNER/NAME#N" (NAME and OWNER must be
# this repository when --repo is given; without it only a bare "#N" counts),
# or a github.com issues/pull URL of this repository. A closing keyword just
# before it is recorded.
| [ $log | split("\u001e")[] | ltrimstr("\n") | select(length > 0)
    | (split("\t")) as $f
    | {sha: $f[0],
       refs: [ (scan("(?i)(?:\\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\\s+)?(?:([A-Za-z0-9_.-]+)/)?([A-Za-z0-9_.-]*)#([0-9]+)(?![0-9])")
                | select((.[1] == null and .[2] == "")
                         or ($repo != "" and (.[2] | ascii_downcase) == $rp[1] and (.[1] == null or (.[1] | ascii_downcase) == $rp[0])))
                | {n: (.[3] | tonumber), kw: (.[0] != null)}),
               (if $repo == "" then empty else
                  scan("(?i)github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(?:issues|pull)/([0-9]+)")
                  | select((.[0] | ascii_downcase) == $rp[0] and (.[1] | ascii_downcase) == $rp[1])
                  | {n: (.[2] | tonumber), kw: false} end) ]} ]
| . as $commits
| [ $want[] as $n
    | [ $commits[] | select(any(.refs[]; .n == $n)) ] as $hits
    | select(($hits | length) > 0)
    | {issue: $n, mentions: ($hits | length), commits: [$hits[].sha],
       closing_keyword: any($hits[].refs[]; .n == $n and .kw)} ]
| sort_by(-.mentions, .issue)[]
'

cmd_candidates() {
  parse_opts "$@"
  only_for candidates
  { [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; } || fail_input "candidates needs --log FILE (an existing file)"
  { [ -n "$OPEN_FILE" ] && [ -f "$OPEN_FILE" ]; } || fail_input "candidates needs --open FILE (an existing file)"
  need_repo
  validate_ledger "$LEDGER" || exit 2
  jq -n -c -S --rawfile log "$LOG_FILE" --slurpfile open "$OPEN_FILE" --slurpfile ledger "$LEDGER" \
    --arg repo "$REPO_FILTER" "$CANDIDATES_JQ" 2>"$TMPD/cand.err" ||
    fail_input "$(head -c 300 "$TMPD/cand.err")"
}

main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"
  shift
  need_tools
  case "$sub" in
    validate) cmd_validate "$@" ;;
    lint) cmd_lint "$@" ;;
    evaluate) cmd_evaluate "$@" ;;
    decide) cmd_decide "$@" ;;
    render-comment) cmd_render_comment "$@" ;;
    candidates) cmd_candidates "$@" ;;
    -h | --help | help) usage ;;
    *) usage; fail_input "unknown subcommand: $sub" ;;
  esac
}

main "$@"
