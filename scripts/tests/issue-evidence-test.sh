#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# issue-evidence-test.sh — fixture suite for scripts/issue-evidence.sh, the
# issue-evidence ledger evaluator. Every fixture is a throwaway git repository
# in a temp dir. It proves:
#   * each check kind both holds and fails;
#   * checks are read at the REF, not in the working tree (a check that holds
#     on one commit fails on its parent, and an uncommitted edit is ignored);
#   * every `validate` rejection, each naming its line;
#   * injection attempts in every string field ($(...), backticks, `; rm -rf`,
#     a leading "-", a newline) are refused or stay inert literals, and no
#     sentinel file appears;
#   * the full `decide` truth table, `render-comment` and `candidates`;
#   * determinism (same inputs twice give byte-identical output);
#   * a NEGATIVE CONTROL: this suite, run against a copy of the evaluator with
#     one check inverted, reports failures.
#
# Run: bash scripts/tests/issue-evidence-test.sh
# ISSUE_EVIDENCE_SH overrides the script under test (the negative control uses it).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IE="${ISSUE_EVIDENCE_SH:-$SCRIPT_DIR/../issue-evidence.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
# verdict LABEL CMD...: PASS when CMD succeeds.
verdict() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else ko "$label"; fi
}
# out_has TEXT / out_line LINE: $OUT contains TEXT / has exactly the line LINE.
out_has() { printf "%s\n" "$OUT" | grep -qF -- "$1"; }
out_line() { printf "%s\n" "$OUT" | grep -qx -- "$1"; }
rc0_and() { [ "$RC" = 0 ] && "$@"; }

# run CMD...: sets OUT (stdout), ERR (stderr) and RC.
run() {
  RC=0
  "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}

# expect_rc LABEL WANT CMD...
expect_rc() {
  local label="$1" want="$2"
  shift 2
  run "$@"
  if [ "$RC" = "$want" ]; then ok "$label"; else ko "$label — expected exit $want, got $RC; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|')"; fi
}

# expect_err LABEL NEEDLE CMD... — exit 2 and NEEDLE on stderr.
expect_err() {
  local label="$1" needle="$2"
  shift 2
  run "$@"
  if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -qF -- "$needle"; then ok "$label"
  else ko "$label — expected exit 2 with '$needle', got $RC; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|')"; fi
}

# expect_holds LABEL WANT [evaluate args...] — the first evaluated row's holds.
expect_holds() {
  local label="$1" want="$2" got
  shift 2
  run bash "$IE" evaluate "$@"
  got="$(printf '%s\n' "$OUT" | head -1 | jq -r '.holds' 2>/dev/null)"
  if [ "$RC" = 0 ] && [ "$got" = "$want" ]; then ok "$label"
  else ko "$label — expected holds=$want, got rc=$RC holds=${got:-<none>}; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|')"; fi
}

# row ISSUE CHECKS_JSON [DISPOSITION] [EXTRA_JSON] — one canonical ledger line.
row() {
  jq -c -S -n --argjson issue "$1" --argjson checks "$2" --arg d "${3:-landed}" --argjson extra "${4:-{\}}" \
    '{issue: $issue, repo: "o/r", disposition: $d, claim: "The fix is on main.", checks: $checks,
      evidence: ["abc123"], added: "2026-11-17"} + $extra'
}
ledger() { # LINE... -> $WORK/ledger.jsonl
  printf '%s\n' "$@" >"$WORK/ledger.jsonl"
}
L="$WORK/ledger.jsonl"

# write_eval_helper: the defect of the fixture issue (#1405): a helper that evals.
write_eval_helper() {
  cat >scripts/helper.sh <<'EOF'
run() {
  eval "$1"
}
EOF
}

# --- fixture repository --------------------------------------------------------
R="$WORK/repo"
mkdir -p "$R/scripts" "$R/docs"
cd "$R" || exit 2
git init -q -b main .
git config user.email t@example.invalid
git config user.name test
git config commit.gpgsign false
write_eval_helper
printf 'rule one\n--count is a flag\n' >docs/a.adoc
printf '#!/usr/bin/env bash\nexit 0\n' >scripts/pass.sh
printf '#!/usr/bin/env bash\nexit 1\n' >scripts/fail.sh
printf '#!/usr/bin/env bash\nexit 2\n' >scripts/cannot.sh
printf '#!/usr/bin/env bash\necho "SKIP: tool missing"\nexit 77\n' >scripts/skip.sh
printf '#!/usr/bin/env bash\nexit 3\n' >scripts/exit3.sh
cat >scripts/argv.sh <<'EOF'
#!/usr/bin/env bash
printf "argc=%s\n" "$#" > "$ARGV_OUT"
EOF
printf 'not executable\n' >scripts/plain.sh
# dirty.sh passes but leaves an untracked file in the checkout (its cwd).
printf '#!/usr/bin/env bash\n: >litter.txt\n' >scripts/dirty.sh
printf 'build/\n' >.gitignore
chmod +x scripts/pass.sh scripts/fail.sh scripts/cannot.sh scripts/skip.sh scripts/exit3.sh scripts/argv.sh scripts/dirty.sh
git add .
git commit -qm "one: helper uses eval"
C1="$(git rev-parse HEAD)"
printf 'run() {\n  "$@"\n}\n' >scripts/helper.sh
git commit -qam "two: drop eval (#1405)"
C2="$(git rev-parse HEAD)"
git checkout -q -b side
printf 'side\n' >docs/side.adoc
git add docs/side.adoc
git commit -qm "side branch"
SIDE="$(git rev-parse HEAD)"
git checkout -q main

echo "=== each check kind holds and fails (at HEAD) ==="
ledger "$(row 1 '[{"kind":"path-present","path":"scripts/helper.sh"}]')"
expect_holds "path-present holds" true "$L"
ledger "$(row 1 '[{"kind":"path-present","path":"scripts/gone.sh"}]')"
expect_holds "path-present fails" false "$L"
ledger "$(row 1 '[{"kind":"path-absent","path":"scripts/gone.sh"}]')"
expect_holds "path-absent holds" true "$L"
ledger "$(row 1 '[{"kind":"path-absent","path":"docs"}]')"
expect_holds "path-absent fails on a directory" false "$L"
ledger "$(row 1 '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^rule (one|two)$"}]')"
expect_holds "grep-present holds" true "$L"
ledger "$(row 1 '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^rule three$"}]')"
expect_holds "grep-present fails" false "$L"
ledger "$(row 1 '[{"kind":"grep-present","path":"docs/none.adoc","pattern":"x"}]')"
expect_holds "grep-present fails on a missing file" false "$L"
ledger "$(row 1 '[{"kind":"grep-absent","path":"scripts/helper.sh","pattern":"\\beval\\b"}]')"
expect_holds "grep-absent holds" true "$L"
ledger "$(row 1 '[{"kind":"grep-absent","path":"docs/a.adoc","pattern":"rule"}]')"
expect_holds "grep-absent fails" false "$L"
ledger "$(row 1 '[{"kind":"grep-absent","path":"docs/none.adoc","pattern":"x"}]')"
expect_holds "grep-absent fails on a missing file (absence proves nothing)" false "$L"
ledger "$(row 1 '[{"kind":"tree-grep-absent","glob":"scripts/*.sh","pattern":"eval"}]')"
expect_holds "tree-grep-absent holds" true "$L"
ledger "$(row 1 '[{"kind":"tree-grep-absent","glob":"**/*.adoc","pattern":"rule one"}]')"
expect_holds "tree-grep-absent fails" false "$L"
ledger "$(row 1 '[{"kind":"tree-grep-absent","glob":"nowhere/*.sh","pattern":"x"}]')"
expect_holds "tree-grep-absent fails when the glob selects no file" false "$L"
ledger "$(row 1 "[{\"kind\":\"commit-on-main\",\"sha\":\"${C1:0:12}\"}]")"
expect_holds "commit-on-main holds (12-hex prefix)" true "$L"
ledger "$(row 1 "[{\"kind\":\"commit-on-main\",\"sha\":\"$SIDE\"}]")"
expect_holds "commit-on-main fails for a commit off main" false "$L"
ledger "$(row 1 '[{"kind":"commit-on-main","sha":"0123456789abcdef0123"}]')"
expect_holds "commit-on-main fails for an unknown commit" false "$L"
ledger "$(row 1 '[{"kind":"script","path":"scripts/pass.sh"}]')"
expect_holds "script holds (exit 0)" true "$L"
ledger "$(row 1 '[{"kind":"script","path":"scripts/fail.sh"}]')"
expect_holds "script fails (exit 1)" false "$L"
ledger "$(row 1 '[{"kind":"script","path":"scripts/cannot.sh"}]')"
expect_holds "script exit 2 (could not run) is unevaluated" null "$L"
# Exit 77 is a skip (the automake convention): the script ran nothing, so it
# is never evidence either way. A row whose only problem is a skipped script
# is neither closed nor reopened.
ledger "$(row 1 '[{"kind":"script","path":"scripts/skip.sh"}]')"
expect_holds "script exit 77 (skipped) is unevaluated, never holds" null "$L"
echo '[{"number":1,"state":"open"}]' >"$WORK/o-skip.json"
run bash "$IE" decide --repo o/r --open "$WORK/o-skip.json" "$L"
verdict "a skipped script check does not close an open issue" \
  rc0_and [ "$OUT" = '{"action":"none","disposition":"landed","issue":1,"reason":"unevaluated","repo":"o/r"}' ]
echo '[{"number":1,"state":"closed","closed_by_bot":true}]' >"$WORK/o-skip.json"
run bash "$IE" decide --repo o/r --open "$WORK/o-skip.json" "$L"
verdict "a skipped script check does not reopen an issue the bot closed" \
  rc0_and [ "$OUT" = '{"action":"none","disposition":"landed","issue":1,"reason":"unevaluated","repo":"o/r"}' ]
ledger "$(row 1 '[{"kind":"script","path":"scripts/exit3.sh"}]')"
expect_holds "script exit 3 (any other code below 124) fails" false "$L"
ledger "$(row 1 '[{"kind":"script","path":"scripts/pass.sh"},{"kind":"path-present","path":"scripts/gone.sh"}]')"
run bash "$IE" evaluate "$L"
verdict "failed lists the failing check's index" [ "$OUT" = '{"disposition":"landed","failed":[1],"holds":false,"issue":1,"repo":"o/r","unevaluated":[]}' ]
ledger "$(row 1 '[{"kind":"script","path":"scripts/cannot.sh"},{"kind":"path-present","path":"scripts/gone.sh"}]')"
expect_holds "a failing check outweighs an unevaluated one" false "$L"

echo "=== checks are read at the ref, not in the working tree ==="
ledger "$(row 1405 '[{"kind":"grep-absent","path":"scripts/helper.sh","pattern":"eval"}]')"
expect_holds "holds at the fixing commit" true --ref "$C2" "$L"
expect_holds "fails at its parent" false --ref "$C1" "$L"
write_eval_helper
expect_holds "an uncommitted regression in the working tree is not read" true "$L"
git checkout -q -- scripts/helper.sh
ledger "$(row 1 '[{"kind":"script","path":"scripts/pass.sh"}]')"
expect_holds "script is unevaluated when REF is not the checkout" null --ref "$C1" "$L"
printf '#!/usr/bin/env bash\nexit 1\n' >scripts/pass.sh
expect_holds "script is unevaluated when the checkout's copy is modified" null "$L"
git checkout -q -- scripts/pass.sh
# A script may read any file in the checkout, so it counts as evidence only
# when the checkout IS the committed tree (Codex finding on #1651).
printf 'edited\n' >>docs/a.adoc
expect_holds "script is unevaluated when another tracked file is modified" null "$L"
git checkout -q -- docs/a.adoc
printf 'staged\n' >>docs/a.adoc
git add docs/a.adoc
git show HEAD:docs/a.adoc >docs/a.adoc # the working file is the committed one again
expect_holds "script is unevaluated when the index differs from the commit" null "$L"
git reset -q -- docs/a.adoc
git checkout -q -- docs/a.adoc
printf 'x\n' >docs/new.adoc
expect_holds "script is unevaluated with an untracked file in the checkout" null "$L"
rm -f docs/new.adoc
git update-index --assume-unchanged docs/a.adoc
printf 'hidden\n' >>docs/a.adoc
expect_holds "script is unevaluated when an index entry hides a change (assume-unchanged)" null "$L"
git update-index --no-assume-unchanged docs/a.adoc
git checkout -q -- docs/a.adoc
mkdir -p build
printf 'x\n' >build/out.txt
expect_holds "a path the committed .gitignore ignores does not block a script" true "$L"
rm -rf build
ledger "$(row 1 '[{"kind":"script","path":"scripts/dirty.sh"},{"kind":"script","path":"scripts/pass.sh"}]')"
run bash "$IE" evaluate "$L"
verdict "a script that litters the checkout leaves later script checks unevaluated" \
  rc0_and [ "$OUT" = '{"disposition":"landed","failed":[],"holds":null,"issue":1,"repo":"o/r","unevaluated":[1]}' ]
rm -f litter.txt
verdict "the fixture checkout is clean again" [ -z "$(git status --porcelain)" ]
ledger "$(row 1 '[{"kind":"script","path":"scripts/pass.sh"}]')"
git clone -q --depth 1 "file://$R" "$WORK/shallow"
ledger "$(row 1 "[{\"kind\":\"commit-on-main\",\"sha\":\"$C1\"}]")"
# Assertions run in this shell (never in a subshell), so their counts reach
# the summary; the directory is restored after each.
cd "$WORK/shallow" || exit 2
expect_holds "commit-on-main is unevaluated in a shallow clone" null "$L"
cd "$R" || exit 2
ledger "$(row 1 '[{"kind":"path-present","path":"scripts/helper.sh"}]')"
expect_rc "an unresolvable --ref is an internal error (3)" 3 bash "$IE" evaluate --ref no-such-ref "$L"
cd "$WORK" || exit 2
expect_rc "outside a git repository is an internal error (3)" 3 bash "$IE" evaluate "$L"
cd "$R" || exit 2

echo "=== validate: every rejection names its line ==="
GOOD="$(row 2 '[{"kind":"path-present","path":"docs/a.adoc"}]')"
ledger "$GOOD"
expect_rc "a good row validates" 0 bash "$IE" validate "$L"
: >"$L"
expect_rc "an empty ledger validates" 0 bash "$IE" validate "$L"
ledger "$GOOD" "$(row 3 '[{"kind":"path-anywhere","path":"x"}]')"
expect_err "unknown kind" "ledger.jsonl:2: checks[0].kind is not in the vocabulary" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' fixed)"
expect_err "unknown disposition" ":1: disposition is not in the vocabulary" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' | jq -c 'del(.claim)')"
expect_err "missing field" ':1: missing field "claim"' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"grep-present","path":"x"}]')"
expect_err "missing check field" 'checks[0]: missing field "pattern"' bash "$IE" validate "$L"
ledger "$(row 3 '[]')"
expect_err "empty checks" ":1: checks must be a non-empty array" bash "$IE" validate "$L"
ledger "$GOOD" "$GOOD"
expect_err "duplicate (repo, issue)" ":2: duplicate (repo, issue): the same issue is already on line 1" bash "$IE" validate "$L"
ledger "$GOOD" "$(row 2 '[{"kind":"path-present","path":"x"}]' landed '{"repo":"O/R"}')"
expect_err "duplicate (repo, issue) ignores repository case" ":2: duplicate (repo, issue)" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"/etc/passwd"}]')"
expect_err "absolute path" "checks[0].path is absolute" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"grep-absent","path":"docs/../../etc/passwd","pattern":"x"}]')"
expect_err "path with .." 'checks[0].path has an empty, "." or ".." component' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"tree-grep-absent","glob":"../*","pattern":"x"}]')"
expect_err "glob with .." 'checks[0].glob has an empty, "." or ".." component' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"tree-grep-absent","glob":"/x/*","pattern":"x"}]')"
expect_err "absolute glob" "checks[0].glob is absolute" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"tree-grep-absent","glob":":(exclude)x","pattern":"x"}]')"
expect_err "glob choosing pathspec magic" 'checks[0].glob starts with ":"' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"script","path":"docs/a.adoc"}]')"
expect_err "script outside scripts/ and tests/" "checks[0].path must be under scripts/ or tests/" bash "$IE" validate "$L"
# Schema validation never reads the tree: a script that is absent or not
# executable is a FAILED check at evaluation (a regression), and `lint` is the
# separate pre-merge check that names it.
printf '#!/usr/bin/env bash\nexit 0\n' >scripts/untracked.sh
chmod +x scripts/untracked.sh
ledger "$(row 3 '[{"kind":"script","path":"scripts/untracked.sh"}]')"
expect_rc "validate does not read the tree: an untracked script is schema-valid" 0 bash "$IE" validate "$L"
expect_err "lint: untracked script" "is not tracked in git at HEAD" bash "$IE" lint "$L"
expect_holds "evaluate: an untracked script is a failed check" false "$L"
rm -f scripts/untracked.sh
ledger "$(row 3 '[{"kind":"script","path":"scripts/plain.sh"}]')"
expect_rc "validate does not read the tree: a non-executable script is schema-valid" 0 bash "$IE" validate "$L"
expect_err "lint: script without the executable bit" "without the executable bit" bash "$IE" lint "$L"
expect_holds "evaluate: a non-executable script is a failed check" false "$L"
ledger "$(row 3 '[{"kind":"script","path":"scripts/pass.sh"}]')"
expect_rc "lint passes a tracked executable script" 0 bash "$IE" lint "$L"
ledger "$(row 3 '[{"kind":"script","path":"scripts/gone.sh"}]')" "$(row 4 '[{"kind":"path-present","path":"docs/a.adoc"}]')"
run bash "$IE" evaluate "$L"
verdict "one row's missing script does not stop the other rows" rc0_and [ "$OUT" = '{"disposition":"landed","failed":[0],"holds":false,"issue":3,"repo":"o/r","unevaluated":[]}
{"disposition":"landed","failed":[],"holds":true,"issue":4,"repo":"o/r","unevaluated":[]}' ]
ledger "$(row 3 '[{"kind":"script","path":"scripts/gone.sh"}]')"
expect_holds "a script absent at another ref is failed, not unevaluated" false --ref "$C1" "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' duplicate)"
expect_err "duplicate without duplicate_of" "disposition duplicate requires duplicate_of" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' duplicate '{"duplicate_of":3}')"
expect_err "duplicate_of naming itself" "disposition duplicate requires duplicate_of" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' landed '{"duplicate_of":4}')"
expect_err "duplicate_of without disposition duplicate" "duplicate_of is allowed only with disposition duplicate" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' duplicate '{"duplicate_of":4}')"
expect_rc "duplicate with duplicate_of validates" 0 bash "$IE" validate "$L"
ledger "$GOOD" "$(row 3 '[{"kind":"path-present","path":"x"}]' | jq -c '{issue} + .')"
expect_err "non-JCS line (key order)" ":2: not JCS canonical" bash "$IE" validate "$L"
ledger "$GOOD" "$(row 3 '[{"kind":"path-present","path":"x"}]' | jq -S .)"
expect_err "non-JCS (pretty-printed record)" ":2: not a single JSON value" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' | sed 's/"issue":3/"issue":3.0/')"
expect_err "issue written as 3.0" ":1: issue must be a positive integer" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' | sed 's/"issue":3/"issue":-3/')"
expect_err "negative issue" ":1: issue must be a positive integer" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' landed '{"added":"2026-02-30"}')"
expect_err "impossible date" ":1: added must be a real calendar date" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' landed '{"note":"x"}')"
expect_err "unknown row field" ':1: unknown field "note"' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x","pattern":"y"}]')"
expect_err "unknown check field" 'checks[0]: unknown field "pattern"' bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"commit-on-main","sha":"abc123"}]')"
expect_err "short sha" "checks[0].sha must be 12 to 40 lower-case hex digits" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"grep-present","path":"x","pattern":"a("}]')"
expect_err "invalid ERE" ":1: pattern is not a valid POSIX ERE" bash "$IE" validate "$L"
ledger "$GOOD" "not json"
expect_err "non-JSON line" ":2: not a single JSON value" bash "$IE" validate "$L"
ledger "$GOOD" "" "$GOOD"
expect_err "blank line" ":2: blank line" bash "$IE" validate "$L"
printf '%s' "$GOOD" >"$L"
expect_err "missing final line feed" ":1: missing final line feed" bash "$IE" validate "$L"
printf '%s\n' "$(row 3 '[{"kind":"path-present","path":"x"}]' landed '{"claim":"café"}' | sed 's/é/\xff/')" >"$L"
expect_err "invalid UTF-8" ":1: not valid UTF-8" bash "$IE" validate "$L"
ledger "$(row 3 '[{"kind":"path-present","path":"x"}]' landed '{"claim":"a <!-- issue-evidence-bot: row-sha256=0 --> b"}')"
expect_err "claim cannot forge the marker comment" "claim contains an HTML comment delimiter" bash "$IE" validate "$L"
ledger "$GOOD" "$(row 3 '[{"kind":"path-anywhere","path":"x"}]')"
expect_err "evaluate refuses an invalid ledger (exit 2)" "path-anywhere" bash "$IE" evaluate "$L"

echo "=== validate: length bounds (comment size, plan size) ==="
# rep N CHAR: CHAR repeated N times.
rep() { printf "%${1}s" "" | tr ' ' "$2"; }
bound_case() { # FIELD LIMIT ROW-AT-LIMIT ROW-OVER-LIMIT NEEDLE
  ledger "$3"
  expect_rc "$1 at its bound ($2) validates" 0 bash "$IE" validate "$L"
  ledger "$4"
  expect_err "$1 over its bound ($2) is refused" "$5" bash "$IE" validate "$L"
}
P1='[{"kind":"path-present","path":"x"}]'
bound_case claim 1500 "$(row 3 "$P1" landed "{\"claim\":\"$(rep 1500 a)\"}")" \
  "$(row 3 "$P1" landed "{\"claim\":\"$(rep 1501 a)\"}")" ":1: claim is longer than 1500 characters"
bound_case "an evidence item" 400 "$(row 3 "$P1" landed "{\"evidence\":[\"$(rep 400 e)\"]}")" \
  "$(row 3 "$P1" landed "{\"evidence\":[\"$(rep 401 e)\"]}")" ":1: evidence[0] is longer than 400 characters"
bound_case "the evidence count" 16 "$(row 3 "$P1" landed "$(jq -c -n '{evidence: [range(16) | "e\(.)"]}')")" \
  "$(row 3 "$P1" landed "$(jq -c -n '{evidence: [range(17) | "e\(.)"]}')")" ":1: evidence has more than 16 items"
bound_case "the check count" 16 "$(row 3 "$(jq -c -n '[range(16) | {kind: "path-present", path: "p\(.)"}]')")" \
  "$(row 3 "$(jq -c -n '[range(17) | {kind: "path-present", path: "p\(.)"}]')")" ":1: checks has more than 16 items"
bound_case "a pattern" 400 "$(row 3 "[{\"kind\":\"grep-present\",\"path\":\"x\",\"pattern\":\"$(rep 400 p)\"}]")" \
  "$(row 3 "[{\"kind\":\"grep-present\",\"path\":\"x\",\"pattern\":\"$(rep 401 p)\"}]")" "checks[0].pattern is longer than 400 characters"
bound_case "a path" 256 "$(row 3 "[{\"kind\":\"path-present\",\"path\":\"$(rep 256 q)\"}]")" \
  "$(row 3 "[{\"kind\":\"path-present\",\"path\":\"$(rep 257 q)\"}]")" "checks[0].path is longer than 256 characters"
bound_case "a glob" 256 "$(row 3 "[{\"kind\":\"tree-grep-absent\",\"glob\":\"$(rep 256 g)\",\"pattern\":\"x\"}]")" \
  "$(row 3 "[{\"kind\":\"tree-grep-absent\",\"glob\":\"$(rep 257 g)\",\"pattern\":\"x\"}]")" "checks[0].glob is longer than 256 characters"
# The bounds keep every comment under GitHub's 65,536-character limit. The
# worst row: every bound reached with characters that grow when rendered
# ("@" gains a zero-width space; '"' and "\" are escaped by tojson).
WORST="$(jq -c -S -n --arg a "$(rep 1500 @)" --arg e "$(rep 400 @)" --arg q "$(rep 256 '"')" \
  --arg p "$(printf '\\\\%.0s' $(seq 200))" '
  {issue: 3, repo: "o/r", disposition: "landed", added: "2026-11-17", claim: $a,
   evidence: [range(16) | $e], checks: [range(16) | {kind: "grep-absent", path: $q, pattern: $p}]}')"
ledger "$WORST"
expect_rc "the worst-case row validates" 0 bash "$IE" validate "$L"
run bash "$IE" render-comment --issue 3 --action reopen "$L"
chars="$(printf '%s' "$OUT" | jq -R -s length)"
verdict "the worst-case comment ($chars characters) is under GitHub's 65,536-character limit" \
  rc0_and [ "${chars:-99999}" -lt 65536 ]
if command -v ijson-jcs >/dev/null 2>&1; then
  ledger "$GOOD" "$(row 4 '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"é|\\\\d"}]' landed '{"claim":"Ünïcode \" quote"}')"
  bad=0
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | ijson-jcs canon)" = "$line" ] || bad=1
  done <"$L"
  run bash "$IE" validate "$L"
  if [ "$bad" = 0 ] && [ "$RC" = 0 ]; then ok "the jq JCS check agrees with ijson-jcs on non-ASCII and escapes"
  else ko "jq/ijson-jcs disagreement (ijson bad=$bad, validate rc=$RC)"; fi
else
  echo "SKIP: ijson-jcs not installed; cross-check with the reference JCS tool not run"
fi

echo "=== injection attempts stay inert ==="
SENT="PWNED"
sentinel_absent() { [ ! -e "$R/$SENT" ] && [ ! -e "$WORK/$SENT" ] && [ ! -e "$SCRIPT_DIR/$SENT" ]; }
# inert LABEL ROW: the row is rejected (2) or evaluates (0); no sentinel appears.
inert() {
  local label="$1"
  ledger "$2"
  run bash "$IE" validate "$L"
  local vrc="$RC"
  run bash "$IE" evaluate "$L"
  local erc="$RC"
  if ! sentinel_absent; then
    ko "$label — SIDE EFFECT: $SENT exists"
  elif { [ "$vrc" = 2 ] && [ "$erc" = 2 ]; } || { [ "$vrc" = 0 ] && [ "$erc" = 0 ]; }; then
    ok "$label (validate=$vrc evaluate=$erc, no side effect)"
  else
    ko "$label — validate=$vrc evaluate=$erc"
  fi
}
for p in "\$(touch $SENT)" "\`touch $SENT\`" "; touch $SENT; rm -rf ." "x\" ; touch $SENT; #" "\$(rm -rf $R)"; do
  pj="$(jq -n --arg p "$p" '$p')"
  inert "pattern: $p" "$(row 5 "[{\"kind\":\"grep-absent\",\"path\":\"docs/a.adoc\",\"pattern\":$pj}]")"
  inert "tree-grep pattern: $p" "$(row 5 "[{\"kind\":\"tree-grep-absent\",\"glob\":\"docs/*\",\"pattern\":$pj}]")"
  inert "path: $p" "$(row 5 "[{\"kind\":\"path-present\",\"path\":$pj}]")"
  inert "grep path: $p" "$(row 5 "[{\"kind\":\"grep-present\",\"path\":$pj,\"pattern\":\"x\"}]")"
  inert "glob: $p" "$(row 5 "[{\"kind\":\"tree-grep-absent\",\"glob\":$pj,\"pattern\":\"x\"}]")"
  inert "claim: $p" "$(row 5 '[{"kind":"path-present","path":"docs/a.adoc"}]' landed "{\"claim\":$pj}")"
  inert "evidence: $p" "$(row 5 '[{"kind":"path-present","path":"docs/a.adoc"}]' landed "{\"evidence\":[$pj]}")"
  inert "script args: $p" "$(row 5 "[{\"kind\":\"script\",\"path\":\"scripts/pass.sh\",\"args\":[$pj]}]")"
done
verdict "the repository survived the rm -rf payloads" [ -d "$R/scripts" ]
# A leading "-" in a pattern is a pattern, never a grep option: "--count" is a
# literal line in docs/a.adoc, so grep-present holds only if it was searched for.
ledger "$(row 5 '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"--count"}]')"
expect_holds "a leading - in pattern is a literal pattern (grep)" true "$L"
ledger "$(row 5 '[{"kind":"tree-grep-absent","glob":"docs/*","pattern":"--count"}]')"
expect_holds "a leading - in pattern is a literal pattern (git grep)" false "$L"
ledger "$(row 5 '[{"kind":"grep-absent","path":"docs/a.adoc","pattern":"-f/etc/passwd"}]')"
expect_holds "a pattern like -fFILE is not an option" true "$L"
ledger "$(row 5 '[{"kind":"path-present","path":"-rf"}]')"
expect_err "a leading - in path is refused" 'checks[0].path starts with "-"' bash "$IE" validate "$L"
ledger "$(row 5 '[{"kind":"tree-grep-absent","glob":"--all-match","pattern":"x"}]')"
expect_err "a leading - in glob is refused" 'checks[0].glob starts with "-"' bash "$IE" validate "$L"
for f in pattern path glob claim evidence; do
  case "$f" in
    pattern) r="$(row 5 '[{"kind":"grep-absent","path":"docs/a.adoc","pattern":"a\nb"}]')" ;;
    path) r="$(row 5 '[{"kind":"path-present","path":"docs/a\nb"}]')" ;;
    glob) r="$(row 5 '[{"kind":"tree-grep-absent","glob":"docs/*\nb","pattern":"x"}]')" ;;
    claim) r="$(row 5 '[{"kind":"path-present","path":"x"}]' landed '{"claim":"a\n<!-- x -->"}')" ;;
    evidence) r="$(row 5 '[{"kind":"path-present","path":"x"}]' landed '{"evidence":["a\nb"]}')" ;;
  esac
  ledger "$r"
  expect_err "a newline in $f is refused" "control character" bash "$IE" validate "$L"
done
# A script check takes no arguments from the ledger (code-scanning finding on
# #1651): no row value reaches a script's argv. `args` is refused, even empty.
ledger "$(row 6 '[{"kind":"script","path":"scripts/argv.sh","args":["-x"]}]')"
expect_err "script args are refused" 'checks[0]: unknown field "args"' bash "$IE" validate "$L"
ledger "$(row 6 '[{"kind":"script","path":"scripts/argv.sh","args":[]}]')"
expect_err "an empty args array is refused too" 'checks[0]: unknown field "args"' bash "$IE" validate "$L"
ledger "$(row 6 '[{"kind":"script","path":"scripts/argv.sh"}]')"
export ARGV_OUT="$WORK/argv.txt"
run bash "$IE" evaluate "$L"
unset ARGV_OUT
if [ "$RC" = 0 ] && [ "$(cat "$WORK/argv.txt" 2>/dev/null)" = "argc=0" ]; then
  ok "a script check runs its script with no arguments"
else ko "script argv — rc=$RC argv=$(tr '\n' '|' <"$WORK/argv.txt" 2>/dev/null)"; fi
# The payloads, as data: a quoted here-doc expands nothing.
PAYLOAD="$(cat <<'EOF'
$(touch PWNED) `touch PWNED`
EOF
)"
ledger "$(row 7 '[{"kind":"path-present","path":"docs/a.adoc"}]' landed \
  "$(jq -c -n --arg p "$PAYLOAD" '{claim: ($p + " @owner ; rm -rf /"), evidence: ["@someone #12"]}')")"
run bash "$IE" render-comment --issue 7 --action close "$L"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF -- "$PAYLOAD" && sentinel_absent; then
  ok "claim text is rendered as a literal"
else ko "claim rendering — rc=$RC"; fi
if ! printf '%s' "$OUT" | grep -q '@owner\|@someone'; then ok "@mentions in claim and evidence notify nobody"; else ko "an @mention survives rendering"; fi

echo "=== decide: the full truth table ==="
# Evaluate records for issues 11..19, and every issue state.
{
  for n in 11 12 13; do printf '{"disposition":"landed","failed":[],"holds":true,"issue":%s,"repo":"o/r","unevaluated":[]}\n' "$n"; done
  for n in 14 15 16; do printf '{"disposition":"moot","failed":[0],"holds":false,"issue":%s,"repo":"o/r","unevaluated":[]}\n' "$n"; done
  for n in 17 18 19; do printf '{"disposition":"landed","failed":[],"holds":null,"issue":%s,"repo":"o/r","unevaluated":[0]}\n' "$n"; done
  printf '{"disposition":"landed","failed":[],"holds":true,"issue":20,"repo":"o/r","unevaluated":[]}\n'
  printf '{"disposition":"landed","failed":[],"holds":true,"issue":21,"repo":"o/r","unevaluated":[]}\n'
  printf '{"disposition":"landed","failed":[0],"holds":false,"issue":22,"repo":"o/r","unevaluated":[]}\n'
} >"$WORK/ev.jsonl"
cat >"$WORK/open.json" <<'EOF'
[{"number":11,"state":"open"},{"number":12,"state":"closed","closed_by_bot":true},{"number":13,"state":"closed","closed_by_bot":false},
 {"number":14,"state":"open"},{"number":15,"state":"closed","closed_by_bot":true},{"number":16,"state":"closed","closed_by_bot":false},
 {"number":17,"state":"open"},{"number":18,"state":"closed","closed_by_bot":true},{"number":19,"state":"closed","closed_by_bot":false},
 {"number":20,"state":"open","reopened_by_human":true},{"number":22,"state":"open","reopened_by_human":true}]
EOF
cat >"$WORK/want.jsonl" <<'EOF'
{"action":"close","disposition":"landed","issue":11,"reason":"evidence-holds","repo":"o/r"}
{"action":"none","disposition":"landed","issue":12,"reason":"already-closed","repo":"o/r"}
{"action":"none","disposition":"landed","issue":13,"reason":"already-closed","repo":"o/r"}
{"action":"none","disposition":"moot","issue":14,"reason":"evidence-does-not-hold","repo":"o/r"}
{"action":"reopen","disposition":"moot","issue":15,"reason":"regression","repo":"o/r"}
{"action":"none","disposition":"moot","issue":16,"reason":"closed-by-human","repo":"o/r"}
{"action":"none","disposition":"landed","issue":17,"reason":"unevaluated","repo":"o/r"}
{"action":"none","disposition":"landed","issue":18,"reason":"unevaluated","repo":"o/r"}
{"action":"none","disposition":"landed","issue":19,"reason":"unevaluated","repo":"o/r"}
{"action":"none","disposition":"landed","issue":20,"reason":"reopened-by-human","repo":"o/r"}
{"action":"none","disposition":"landed","issue":21,"reason":"no-issue-state","repo":"o/r"}
{"action":"none","disposition":"landed","issue":22,"reason":"evidence-does-not-hold","repo":"o/r"}
EOF
run bash "$IE" decide --repo o/r --open "$WORK/open.json" --evaluated "$WORK/ev.jsonl"
if [ "$RC" = 0 ] && [ "$OUT" = "$(cat "$WORK/want.jsonl")" ]; then ok "decide truth table (12 cases)"
else ko "decide truth table — rc=$RC"; diff <(printf '%s\n' "$OUT") "$WORK/want.jsonl" | head -20; fi
echo '{"number":1}' >"$WORK/bad-open.json"
expect_err "decide refuses an --open that is not an array" "not a JSON array" bash "$IE" decide --repo o/r --open "$WORK/bad-open.json" --evaluated "$WORK/ev.jsonl"
echo '[{"number":11,"state":"closed"}]' >"$WORK/bad-open.json"
expect_err "decide refuses a closed issue without closed_by_bot" "needs closed_by_bot" bash "$IE" decide --repo o/r --open "$WORK/bad-open.json" --evaluated "$WORK/ev.jsonl"
echo '[{"number":11,"state":"open"},{"number":11,"state":"open"}]' >"$WORK/bad-open.json"
expect_err "decide refuses a repeated issue" "appears twice" bash "$IE" decide --repo o/r --open "$WORK/bad-open.json" --evaluated "$WORK/ev.jsonl"
# --open lists ONE repository's issues by number, so a row of another
# repository with the same number must never yield an action here.
expect_err "decide needs --repo (with --evaluated)" "decide needs --repo" bash "$IE" decide --open "$WORK/open.json" --evaluated "$WORK/ev.jsonl"
expect_err "decide needs --repo (from the ledger)" "decide needs --repo" bash "$IE" decide --open "$WORK/open.json" "$L"
{
  printf '{"disposition":"landed","failed":[],"holds":true,"issue":11,"repo":"other/r","unevaluated":[]}\n'
  printf '{"disposition":"landed","failed":[0],"holds":false,"issue":12,"repo":"other/r","unevaluated":[]}\n'
  printf '{"disposition":"landed","failed":[],"holds":true,"issue":14,"repo":"O/R","unevaluated":[]}\n'
} >"$WORK/ev-mixed.jsonl"
echo '[{"number":11,"state":"open"},{"number":12,"state":"closed","closed_by_bot":true},{"number":14,"state":"open"}]' >"$WORK/open-mixed.json"
run bash "$IE" decide --repo o/r --open "$WORK/open-mixed.json" --evaluated "$WORK/ev-mixed.jsonl"
verdict "decide --evaluated ignores another repository's rows (case-insensitive match)" \
  rc0_and [ "$OUT" = '{"action":"close","disposition":"landed","issue":14,"reason":"evidence-holds","repo":"O/R"}' ]
# decide straight from the ledger: evaluate and decide agree on the tree.
ledger "$(row 1405 '[{"kind":"grep-absent","path":"scripts/helper.sh","pattern":"eval"}]')"
echo '[{"number":1405,"state":"open"}]' >"$WORK/o1405.json"
run bash "$IE" decide --repo o/r --open "$WORK/o1405.json" --ref "$C2" "$L"
verdict "decide from the ledger: close at the fixing commit" [ "$OUT" = '{"action":"close","disposition":"landed","issue":1405,"reason":"evidence-holds","repo":"o/r"}' ]
echo '[{"number":1405,"state":"closed","closed_by_bot":true}]' >"$WORK/o1405.json"
run bash "$IE" decide --repo o/r --open "$WORK/o1405.json" --ref "$C1" "$L"
verdict "decide from the ledger: reopen at the parent (regression)" [ "$OUT" = '{"action":"reopen","disposition":"landed","issue":1405,"reason":"regression","repo":"o/r"}' ]

echo "=== render-comment ==="
ledger "$(row 1405 '[{"kind":"grep-absent","path":"scripts/helper.sh","pattern":"eval"}]')"
LINE="$(cat "$L")"
HASH="$(printf '%s' "$LINE" | sha256sum | cut -d' ' -f1)"
run bash "$IE" render-comment --issue 1405 --action close --ref "$C2" "$L"
last="$(printf '%s\n' "$OUT" | tail -1)"
verdict "close comment ends with the row-hash marker" rc0_and [ "$last" = "<!-- issue-evidence-bot: row-sha256=$HASH -->" ]
verdict "close comment names the evaluated commit" out_has "commit $C2"
run bash "$IE" render-comment --issue 1405 --action reopen --ref "$C1" "$L"
verdict "reopen comment marks the failing check" out_has '[0] no line of the file "scripts/helper.sh" matches the regular expression "eval" - DOES NOT HOLD'
# A check that could not be evaluated is labelled so, never "holds".
ledger "$(row 9 '[{"kind":"script","path":"scripts/cannot.sh"},{"kind":"path-present","path":"scripts/gone.sh"},{"kind":"path-present","path":"docs/a.adoc"}]')"
run bash "$IE" render-comment --issue 9 --action reopen "$L"
verdict "reopen comment labels an unevaluated check as not evaluated" out_has '[0] the tracked script "scripts/cannot.sh" exits 0 - NOT EVALUATED'
verdict "reopen comment still marks the failing check" out_has '[1] the path "scripts/gone.sh" exists - DOES NOT HOLD'
verdict "reopen comment marks a holding check" out_has '[2] the path "docs/a.adoc" exists - holds'
printf '{"disposition":"landed","failed":[1],"holds":false,"issue":9,"repo":"o/r","unevaluated":[0]}\n' >"$WORK/ev9.jsonl"
run bash "$IE" render-comment --issue 9 --action reopen --evaluated "$WORK/ev9.jsonl" "$L"
verdict "reopen comment from --evaluated labels the unevaluated check" out_has '[0] the tracked script "scripts/cannot.sh" exits 0 - NOT EVALUATED'
printf '{"disposition":"landed","failed":[1],"holds":false,"issue":9,"repo":"o/r"}\n' >"$WORK/ev9.jsonl"
expect_err "an --evaluated record without unevaluated is refused" "is not an evaluate record" \
  bash "$IE" render-comment --issue 9 --action reopen --evaluated "$WORK/ev9.jsonl" "$L"
ledger "$(row 8 '[{"kind":"grep-absent","path":"docs/a.adoc","pattern":"```x"}]')"
run bash "$IE" render-comment --issue 8 --action close "$L"
verdict "the check block's fence outgrows a backtick run in a pattern" out_line "````"
expect_err "render-comment for an issue with no row" "found 0" bash "$IE" render-comment --issue 999 --action close "$L"

echo "=== candidates (report only) ==="
ledger "$(row 5 '[{"kind":"path-present","path":"docs/a.adoc"}]')"
printf 'aaa\tfix: drop eval (#7)\tFixes #7\n\x1e\nbbb\tdocs: o/r#7, other/r#8 and #8\t\x1e\nccc\tchore: #5 #9 #70\tsee https://github.com/o/r/issues/8\x1e\nddd\tbump other#8\t\x1e\n' >"$WORK/log"
echo '[{"number":5,"state":"open"},{"number":7,"state":"open"},{"number":8,"state":"open"},{"number":9,"state":"closed","closed_by_bot":false},{"number":10,"state":"open"}]' >"$WORK/cand-open.json"
cat >"$WORK/want-cand.jsonl" <<'EOF'
{"closing_keyword":true,"commits":["aaa","bbb"],"issue":7,"mentions":2}
{"closing_keyword":false,"commits":["bbb","ccc"],"issue":8,"mentions":2}
EOF
run bash "$IE" candidates --log "$WORK/log" --open "$WORK/cand-open.json" --repo o/r "$L"
if [ "$RC" = 0 ] && [ "$OUT" = "$(cat "$WORK/want-cand.jsonl")" ]; then ok "candidates: rowless open issues, most mentioned first, closing keyword flagged"
else ko "candidates — rc=$RC out=$(printf '%s' "$OUT" | tr '\n' '|')"; fi

echo "=== determinism ==="
ledger "$(row 1 '[{"kind":"path-present","path":"scripts/helper.sh"},{"kind":"grep-absent","path":"scripts/helper.sh","pattern":"eval"}]')" \
  "$(row 2 "[{\"kind\":\"commit-on-main\",\"sha\":\"$C2\"},{\"kind\":\"tree-grep-absent\",\"glob\":\"**/*.adoc\",\"pattern\":\"zzz\"}]" moot)" \
  "$(row 3 '[{"kind":"script","path":"scripts/pass.sh"}]' superseded)"
same() { # LABEL CMD...
  local label="$1" a b
  shift
  a="$("$@" 2>&1)"
  b="$("$@" 2>&1)"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$label is byte-identical twice"; else ko "$label differs between runs"; fi
}
same "evaluate" bash "$IE" evaluate "$L"
echo '[{"number":1,"state":"open"},{"number":2,"state":"closed","closed_by_bot":true},{"number":3,"state":"open"}]' >"$WORK/det-open.json"
same "decide" bash "$IE" decide --repo o/r --open "$WORK/det-open.json" "$L"
same "render-comment" bash "$IE" render-comment --issue 2 --action close "$L"
same "candidates" bash "$IE" candidates --log "$WORK/log" --open "$WORK/cand-open.json" --repo o/r "$L"
run bash "$IE" evaluate "$L"
verdict "evaluate keeps ledger order" [ "$(printf '%s\n' "$OUT" | jq -r .issue | tr '\n' ' ')" = "1 2 3 " ]
run bash "$IE" evaluate --repo O/R "$L"
verdict "--repo matches case-insensitively" [ "$(printf '%s\n' "$OUT" | grep -c .)" = 3 ]
run bash "$IE" evaluate --repo o/other "$L"
verdict "--repo filters out other repositories' rows" rc0_and [ -z "$OUT" ]

echo "=== script checks apart: --no-scripts, --scripts-only, --script-results ==="
R2="$WORK/repo2"
mkdir -p "$R2/scripts" "$R2/docs"
cd "$R2" || exit 2
git init -q -b main .
git config user.email t@example.invalid
git config user.name test
git config commit.gpgsign false
printf 'a\n' >docs/a.adoc
printf '#!/usr/bin/env bash\nexit 0\n' >scripts/pass.sh
printf '#!/usr/bin/env bash\nexit 1\n' >scripts/fail.sh
printf '#!/usr/bin/env bash\nexit 2\n' >scripts/cannot.sh
printf '#!/usr/bin/env bash\nexit 77\n' >scripts/skip.sh
# shellcheck disable=SC2016  # the fixture script's own text
printf '#!/usr/bin/env bash\n: >"${MARK_OUT:?}"\nexit 0\n' >scripts/mark.sh
printf 'not executable\n' >scripts/plain.sh
chmod +x scripts/pass.sh scripts/fail.sh scripts/cannot.sh scripts/skip.sh scripts/mark.sh
git add -A
git commit -qm fixture
export MARK_OUT="$WORK/mark-ran"
L2="$WORK/ledger2.jsonl"
other_row() { row "$@" | jq -c -S '.repo = "other/r"'; }
printf '%s\n' \
  "$(row 10 '[{"kind":"script","path":"scripts/pass.sh"},{"kind":"path-present","path":"docs/a.adoc"}]')" \
  "$(row 11 '[{"kind":"script","path":"scripts/fail.sh"}]')" \
  "$(row 12 '[{"kind":"script","path":"scripts/cannot.sh"},{"kind":"script","path":"scripts/skip.sh"}]')" \
  "$(row 13 '[{"kind":"path-present","path":"docs/a.adoc"},{"kind":"script","path":"scripts/gone.sh"}]')" \
  "$(row 14 '[{"kind":"script","path":"scripts/plain.sh"}]')" \
  "$(row 15 '[{"kind":"path-present","path":"docs/a.adoc"}]')" \
  "$(row 16 '[{"kind":"script","path":"scripts/mark.sh"}]')" \
  "$(other_row 17 '[{"kind":"script","path":"scripts/pass.sh"}]')" >"$L2"
run bash "$IE" validate "$L2"
verdict "the mode fixture ledger validates" rc0_and true
rec_of() { printf '%s\n' "$OUT" | jq -c --argjson n "$1" 'select(.issue == $n)'; }
blob_of() { git rev-parse "HEAD:$1"; }

rm -f "$MARK_OUT"
run bash "$IE" evaluate --no-scripts "$L2"
verdict "--no-scripts: no script runs" rc0_and [ ! -e "$MARK_OUT" ]
verdict "--no-scripts: a runnable script check is unevaluated and tagged deferred" \
  [ "$(rec_of 10)" = '{"deferred":[0],"disposition":"landed","failed":[],"holds":null,"issue":10,"repo":"o/r","unevaluated":[0]}' ]
verdict "--no-scripts: a script absent at the commit still fails (the tree decides), not deferred" \
  [ "$(rec_of 13)" = '{"deferred":[],"disposition":"landed","failed":[1],"holds":false,"issue":13,"repo":"o/r","unevaluated":[]}' ]
verdict "--no-scripts: a script without the executable bit still fails" \
  [ "$(rec_of 14 | jq -c '[.holds, .failed, .deferred]')" = '[false,[0],[]]' ]
verdict "--no-scripts: a row without script checks is evaluated as before" \
  [ "$(rec_of 15 | jq -c '[.holds, .deferred]')" = '[true,[]]' ]

rm -f "$MARK_OUT"
run bash "$IE" evaluate --scripts-only "$L2"
verdict "--scripts-only: the scripts run" rc0_and [ -e "$MARK_OUT" ]
verdict "--scripts-only: one record per runnable script check, nothing else" \
  [ "$(printf '%s\n' "$OUT" | jq -r '"\(.issue)/\(.check)"' | tr '\n' ' ')" = "10/0 11/0 12/0 12/1 16/0 17/0 " ]
verdict "--scripts-only: a record is {blob, check, issue, outcome, path, repo} with the blob at the commit" \
  [ "$(rec_of 10)" = "{\"blob\":\"$(blob_of scripts/pass.sh)\",\"check\":0,\"issue\":10,\"outcome\":\"holds\",\"path\":\"scripts/pass.sh\",\"repo\":\"o/r\"}" ]
verdict "--scripts-only: exit 1 is failed, exit 2 and 77 are unevaluated" \
  [ "$(printf '%s\n' "$OUT" | jq -r 'select(.issue == 11 or .issue == 12) | .outcome' | tr '\n' ' ')" = "failed unevaluated unevaluated " ]
run bash "$IE" evaluate --scripts-only --repo o/r "$L2"
verdict "--scripts-only --repo: another repository's rows have no record" \
  rc0_and [ -z "$(printf '%s\n' "$OUT" | jq -r 'select(.repo != "o/r")')" ]
printf '%s\n' "$OUT" >"$WORK/results.jsonl"
SR="$WORK/results.jsonl"

# Equivalence: running the scripts in one process and supplying their
# outcomes to another gives the same verdicts as evaluating normally.
run bash "$IE" evaluate --repo o/r "$L2"
normal="$OUT"
rm -f "$MARK_OUT"
run bash "$IE" evaluate --repo o/r --script-results "$SR" "$L2"
verdict "equivalence: evaluate == --scripts-only then --script-results, on every row" rc0_and [ "$OUT" = "$normal" ]
verdict "--script-results: no script runs" [ ! -e "$MARK_OUT" ]
verdict "equivalence covers holds, failed and unevaluated rows" \
  [ "$(printf '%s\n' "$normal" | jq -r '.holds' | sort -u | tr '\n' ' ')" = "false null true " ]
: >"$WORK/empty.jsonl"
run bash "$IE" evaluate --repo o/r --script-results "$WORK/empty.jsonl" "$L2"
verdict "--script-results: a script check with no record is unevaluated" \
  rc0_and [ "$(rec_of 10 | jq -c '[.holds, .unevaluated]')" = '[null,[0]]' ]
grep -v '"issue":11' "$SR" >"$WORK/partial.jsonl"
run bash "$IE" evaluate --repo o/r --script-results "$WORK/partial.jsonl" "$L2"
verdict "--script-results: only the omitted check becomes unevaluated" \
  rc0_and [ "$(rec_of 11 | jq -c .holds)/$(rec_of 10 | jq -c .holds)" = "null/true" ]
sed 's/"issue":11,"outcome":"failed"/"issue":11,"outcome":"holds"/' "$SR" >"$WORK/flipped.jsonl"
run bash "$IE" evaluate --repo o/r --script-results "$WORK/flipped.jsonl" "$L2"
verdict "--script-results: a supplied outcome is that check's bit, and only that" \
  rc0_and [ "$(rec_of 11 | jq -c .holds)" = true ] &&
  [ "$(printf '%s\n' "$OUT" | grep -v '"issue":11,')" = "$(printf '%s\n' "$normal" | grep -v '"issue":11,')" ]

# The trusted boundary: anything but exact records of real script checks is
# refused, with exit 2 and nothing on stdout.
refused() { # LABEL FILE
  run bash "$IE" evaluate --repo o/r --script-results "$2" "$L2"
  if [ "$RC" = 2 ] && [ -z "$OUT" ]; then ok "refused: $1"
  else ko "refused: $1 — rc=$RC out=$(printf '%s' "$OUT" | head -c 120)"; fi
}
adv() { # LABEL JQ-ON-ONE-RECORD: a valid results file plus one tampered record
  { cat "$SR"; jq -c -S "$2" <<<"$(head -n 1 "$SR")"; } >"$WORK/adv.jsonl"
  refused "$1" "$WORK/adv.jsonl"
}
adv "a record for an issue with no row" '.issue = 999'
adv "a record for a row whose check is not a script (issue 15)" '.issue = 15'
adv "a record for a script check absent at the commit (issue 13, check 1)" \
  '.issue = 13 | .check = 1 | .path = "scripts/gone.sh"'
adv "a record with the wrong check index" '.check = 1'
adv "a record with the wrong blob" '.blob = "0000000000000000000000000000000000000000"'
adv "a record with another path" '.path = "scripts/fail.sh"'
adv "a record of another repository" '.repo = "other/r"'
adv "an unknown outcome" '.outcome = "pass"'
adv "an extra field" '. + {note: "x"}'
adv "a missing field" 'del(.blob)'
adv "check as a string" '.check = "0"'
adv "issue as a string" '.issue = "10"'
{ cat "$SR"; head -n 1 "$SR"; } >"$WORK/dup.jsonl"
refused "a duplicated record" "$WORK/dup.jsonl"
head -n 1 "$SR" | sed 's/"issue":10/"issue":10.0/' >"$WORK/float.jsonl"
refused "issue written as 10.0" "$WORK/float.jsonl"
head -n 1 "$SR" | jq -c '{repo} + .' >"$WORK/order.jsonl"
refused "a record that is not JCS (key order)" "$WORK/order.jsonl"
{ head -n 1 "$SR"; echo; } >"$WORK/blank.jsonl"
refused "a blank line" "$WORK/blank.jsonl"
printf 'not json\n' >"$WORK/notjson.jsonl"
refused "a line that is not JSON" "$WORK/notjson.jsonl"
jq -c -s . "$SR" >"$WORK/array.jsonl"
refused "a JSON array instead of JSON Lines" "$WORK/array.jsonl"
{ cat "$SR"; head -c 70000 /dev/zero | tr '\0' ' '; } >"$WORK/big.jsonl"
refused "input over 65,536 bytes" "$WORK/big.jsonl"
printf '\xff\n' >"$WORK/utf8.jsonl"
refused "invalid UTF-8" "$WORK/utf8.jsonl"
expect_err "a missing --script-results file is invalid input" "not found" \
  bash "$IE" evaluate --script-results "$WORK/none.jsonl" "$L2"
expect_err "--no-scripts and --scripts-only exclude one another" "exclude one another" \
  bash "$IE" evaluate --no-scripts --scripts-only "$L2"
expect_err "the script options belong to evaluate only (decide)" "options of evaluate only" \
  bash "$IE" decide --repo o/r --open "$WORK/open.json" --no-scripts "$L2"
expect_err "the script options belong to evaluate only (render-comment)" "options of evaluate only" \
  bash "$IE" render-comment --issue 10 --action close --script-results "$SR" "$L2"

# --scripts-only refuses to emit more than the cap, and refuses before any
# script runs: 20 rows of 16 checks of a script with a long name would make
# about 120 KB of records.
LONG="scripts/$(printf 'l%.0s' {1..200}).sh"
# shellcheck disable=SC2016  # the fixture script's own text
printf '#!/usr/bin/env bash\n: >"${MARK_OUT:?}"\nexit 0\n' >"$LONG"
chmod +x "$LONG"
git add -A
git commit -qm "long script name"
for n in $(seq 100 119); do
  row "$n" "$(jq -c -n --arg p "$LONG" '[range(16) | {kind: "script", path: $p}]')"
done >"$WORK/big-ledger.jsonl"
rm -f "$MARK_OUT"
run bash "$IE" evaluate --scripts-only "$WORK/big-ledger.jsonl"
if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ ! -e "$MARK_OUT" ] && printf '%s' "$ERR" | grep -qF "over 65536"; then
  ok "--scripts-only refuses (exit 2, nothing emitted, no script run) above the 65,536-byte cap"
else ko "--scripts-only cap — rc=$RC stdout bytes=${#OUT}"; fi

echo "=== render-comment --commit (no git repository) ==="
C2R="$(git rev-parse HEAD)"
printf '{"disposition":"landed","failed":[],"holds":true,"issue":10,"repo":"o/r","unevaluated":[]}\n' >"$WORK/ev10.jsonl"
run bash "$IE" render-comment --issue 10 --action close --repo o/r --evaluated "$WORK/ev10.jsonl" "$L2"
in_repo="$OUT"
mkdir -p "$WORK/nogit"
cp "$L2" "$WORK/nogit/ledger.jsonl"
cd "$WORK/nogit" || exit 2
run bash "$IE" validate ledger.jsonl
verdict "validate needs no git repository" rc0_and true
run bash "$IE" render-comment --issue 10 --action close --repo o/r --commit "$C2R" --evaluated "$WORK/ev10.jsonl" ledger.jsonl
verdict "render-comment --commit outside a repository equals the in-repository rendering" \
  rc0_and [ "$OUT" = "$(printf '%s' "$in_repo" | sed "s#$L2#ledger.jsonl#")" ]
expect_err "render-comment --commit needs --evaluated" "--commit needs --evaluated" \
  bash "$IE" render-comment --issue 10 --action close --repo o/r --commit "$C2R" ledger.jsonl
expect_err "render-comment --commit needs a full commit id" "full commit id" \
  bash "$IE" render-comment --issue 10 --action close --repo o/r --commit HEAD --evaluated "$WORK/ev10.jsonl" ledger.jsonl
expect_err "--commit belongs to render-comment only" "option of render-comment only" \
  bash "$IE" evaluate --commit "$C2R" ledger.jsonl
cd "$R" || exit 2
unset MARK_OUT

echo "=== the live ledger ==="
cd "$REPO_ROOT" || exit 2
expect_rc "the repository's own ledger passes lint (schema, and every script tracked and executable)" 0 bash "$IE" lint .machine_readable/issue-evidence.jsonl
cd "$R" || exit 2

# negative_control LABEL SEDFILE: the suite, run against a copy of the
# evaluator mutated by SEDFILE, must report failures.
negative_control() {
  local broken="$WORK/broken-issue-evidence.sh" nc_rc=0 nc_out nc_fail
  sed -f "$2" "$IE" >"$broken"
  if cmp -s "$IE" "$broken"; then
    ko "negative control ($1): the mutation did not apply (the text changed?)"
    return
  fi
  nc_out="$(ISSUE_EVIDENCE_SH="$broken" ISSUE_EVIDENCE_NEGATIVE_CONTROL=1 bash "$SCRIPT_DIR/$(basename "$0")" 2>&1)" || nc_rc=$?
  nc_fail="$(printf '%s\n' "$nc_out" | grep -c '^FAIL:' || true)"
  if [ "$nc_rc" -ne 0 ] && [ "$nc_fail" -gt 0 ]; then
    ok "negative control: $1 makes the suite fail ($nc_fail failures, exit $nc_rc)"
  else
    ko "negative control: the suite passed against an evaluator with $1 (exit $nc_rc)"
  fi
}
if [ -z "${ISSUE_EVIDENCE_NEGATIVE_CONTROL:-}" ]; then
  echo "=== negative controls: the suite catches a broken evaluator ==="
  # Invert grep-absent: on "no match" it now reports "does not hold".
  cat >"$WORK/invert.sed" <<'EOF2'
s/^    1) \[ "\$1" = grep-absent \] \&\& return 0 || return 1 ;;$/    1) [ "$1" = grep-absent ] \&\& return 1 || return 0 ;;/
EOF2
  negative_control "inverted grep-absent" "$WORK/invert.sed"
  # Open the trusted boundary: a supplied record no longer has to match a
  # real script check of the ledger at the commit.
  cat >"$WORK/boundary.sed" <<'EOF2'
s/^          elif \$want\[.*\] != (\$v | del(\.outcome))$/          elif false/
EOF2
  negative_control "an unchecked --script-results boundary" "$WORK/boundary.sed"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
