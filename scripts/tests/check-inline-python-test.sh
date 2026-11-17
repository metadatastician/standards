#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-inline-python-test.sh — fixture suite for scripts/check-inline-python.sh.
#
# Proves three things, each with a planted positive:
#   1. every embedded-Python form is caught, and look-alikes are not;
#   2. the ledger is shrink-only: new path, grown count and stale entry all fail;
#   3. the suite itself can see a regression — two mutants of the gate (stale
#      check deleted, `-c` form deleted) must each turn one case green.
#
# Fixture text is assembled from fragments ($PY, $PIP) so this file never
# contains the literal forms and does not appear in the gate's own scan.
#
# Run: bash scripts/tests/check-inline-python-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$SCRIPT_DIR/../check-inline-python.sh}"
REPO_ROOT="$SCRIPT_DIR/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY="pyth""on3"
PIP="pi""p"
LT="<""<"
pass=0 fail=0

# fresh — empties the fixture tree $WORK/t (not a git repo, so the gate walks it).
fresh() {
  rm -rf "$WORK/t"; mkdir -p "$WORK/t"
}

# plant <relpath> — writes stdin to $WORK/t/<relpath>, creating parent dirs.
plant() {
  mkdir -p "$(dirname "$WORK/t/$1")"
  cat > "$WORK/t/$1"
}

# ledger — writes stdin as the fixture tree's ledger.
ledger() {
  plant .machine_readable/inline-python-allow.txt
}

# expect <label> <want-rc> <needle|-> [gate] — runs the gate (or a mutant) on
# $WORK/t and checks its exit code and, unless "-", a substring of its output.
expect() {
  local label=$1 want=$2 needle=$3 gate=${4:-$GATE} out rc
  out="$(bash "$gate" --root "$WORK/t" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || { [ "$needle" != - ] && ! /usr/bin/grep -qF -- "$needle" <<<"$out"; }; then
    echo "FAIL: $label — wanted exit $want and '$needle', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# form_case <label> <line> — plants <line> in a workflow and expects it caught.
form_case() {
  fresh
  printf 'jobs:\n  a:\n    steps:\n      - run: |\n          %s\n' "$2" | plant ci.yml
  expect "caught: $1" 1 "new inline Python in ci.yml"
}

echo "== every embedded-Python form is caught =="
form_case "-c one-liner"        "$PY -c 'print(1)'"
form_case "-m module"           "$PY -m json.tool x.json"
form_case "- stdin heredoc"     "$PY - \"\$A\" <<'EOF'"
form_case "bare << heredoc"     "$PY << EOF"
form_case "quoted PY delimiter" "cat ${LT}'PY'"
form_case "bare PY delimiter"   "cat ${LT}PY"
form_case "script.py"           "xargs $PY tools/lint.py --self-test"
form_case "python (no 3) -c"    "pyth""on -c 'x'"
form_case "pip install"         "$PIP install pyyaml"
form_case "pip3 install"        "${PIP}3 install safety"

fresh
printf 'RUN %s install --no-cache-dir x\n' "$PIP" | plant sub/Containerfile
printf 'serve:\n    %s -m http.server\n' "$PY" | plant Justfile
printf 'x:\n    %s -c 1\n' "$PY" | plant a/justfile
printf 'r=$(%s -c 1)\n' "$PY" | plant a/b.sh
printf '"j": $(echo x | %s -c 1)\n' "$PY" | plant t/j.template
expect "Containerfile, Justfile, justfile, .sh and .template are in scope" 1 "5 file(s)"

echo
echo "== look-alikes and out-of-scope text are not flagged =="
fresh
cat <<EOF | plant clean.yml
# a comment naming $PY -c is not executed
  # neither is an indented one: $PIP install x
run: |
  echo ${PY}.12
  ${PY}-config --libs
  my${PY} -c x
  cat tools/lint.py
  $PIP list
  cat <<'PYEOF'
  cat <<EOF2
EOF
printf '%s -c 1\n' "$PY" | plant docs/guide.adoc
printf '%s -c 1\n' "$PY" | plant notes.md
expect "comments, prose files and look-alikes are clean" 0 "0 ledgered line(s) across 0 file(s)"

echo
echo "== the ledger is shrink-only =="
fresh
printf 'a: |\n  %s -c 1\n  %s -c 2\n' "$PY" "$PY" | plant w.yml
printf '# header\n\nw.yml:2\n' | ledger
expect "exact ledger match passes" 0 "2 ledgered line(s) across 1 file(s)"

printf 'w.yml:1\n' | ledger
expect "a count above the ledger GREW fails" 1 "GREW in w.yml: 2 line(s), ledger allows 1"

printf 'w.yml:3\n' | ledger
expect "a count below the ledger is stale" 1 "stale ledger entry w.yml:3 — now 2"

printf 'w.yml:2\ngone.yml:1\n' | ledger
expect "an entry with no inline Python left is stale" 1 "stale ledger entry gone.yml:1 — no inline Python left"

printf 'w.yml:2\n' | ledger
printf '%s install x\n' "$PIP" | plant new.sh
expect "a new path beside a clean ledger fails" 1 "new inline Python in new.sh"

rm "$WORK/t/new.sh"
printf 'w.yml:two\n' | ledger
expect "a malformed entry fails closed" 1 "malformed ledger entry"

printf 'w.yml:0\n' | ledger
expect "a zero count is malformed, not an allowance" 1 "malformed ledger entry"

echo
echo "== the suite can see a regression (kill the mutants) =="
# mutant <name> <sed-expr> <case-label> <want-rc-under-mutant> <needle>: a copy of
# the gate with <sed-expr> applied must parse, must differ from the gate, and
# must give <want-rc> on the current fixture where the real gate fails.
mutant() {
  local m="$WORK/mutant-$1.sh"
  sed "$2" "$GATE" > "$m"
  if ! bash -n "$m" || cmp -s "$m" "$GATE"; then
    echo "FAIL: mutant $1 is invalid or identical to the gate — it proves nothing"
    fail=$((fail + 1)); return
  fi
  expect "mutant killed ($1): $3" "$4" "$5" "$m"
}
fresh
printf 'a: |\n  %s -c 1\n' "$PY" | plant w.yml
printf 'w.yml:3\n' | ledger
expect "control: stale entry fails under the real gate" 1 "stale ledger entry"
mutant no-stale-check '/elif \[ "\$n" -lt "\$want" \]; then/,/fail=\$((fail + 1))/{/elif/{s/elif .*/elif false; then/}}' \
  "without the stale branch a shrunk count passes" 0 "none stale"

fresh
printf 'a: |\n  %s -c 1\n' "$PY" | plant w.yml
expect "control: -c is caught under the real gate" 1 "new inline Python"
mutant no-dash-c 's/(-\[cm\](/(-[m](/' \
  "without the -c form the one-liner passes" 0 "0 ledgered line(s)"

echo
echo "== this repository matches its ledger =="
out="$(bash "$GATE" --root "$REPO_ROOT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: repository ledger is exact — $out"; pass=$((pass + 1))
else
  echo "FAIL: repository ledger drifted (exit $rc)"; printf '%s\n' "$out" | sed 's/^/      | /'
  fail=$((fail + 1))
fi

echo
echo "check-inline-python: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
