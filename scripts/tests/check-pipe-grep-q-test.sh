#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-pipe-grep-q-test.sh — fixture suite for scripts/check-pipe-grep-q.sh.
#
# Proves, each with a planted positive and a clean negative:
#   1. clean input passes (positive control), and every spelling the gate
#      claims is refused: -q, -qF, -Eq, -qxF, --quiet, --silent, egrep, fgrep,
#      a path to grep, the pipe at the end of the previous line, a pipe on the
#      line after a backslash, a file under .githooks/ with no extension, a
#      file found by its shebang, and a workflow run: line;
#   2. what is not a defect is not flagged: a comment line, a pattern given
#      with -e (-eq), a non-quiet grep, a here-string, `||`;
#   3. the ledger is shrink-only (new, grown, stale, malformed), and --prune
#      lowers and deletes, never raises or adds, never hides a new offender,
#      and is idempotent;
#   4. the suite sees a regression: five mutants of the gate are killed;
#   5. this repository matches its ledger (exit 0).
#
# Fixture text is assembled from parts ($G, $P) so this file holds no pipe into
# a quiet grep and does not appear in the gate's own scan.
#
# Run: bash scripts/tests/check-pipe-grep-q-test.sh
# Fixture text is written with literal $ on purpose (it must not expand here).
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$SCRIPT_DIR/../check-pipe-grep-q.sh}"
REPO_ROOT="$SCRIPT_DIR/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

G="gr""ep"
P="|"
L=.machine_readable/pipe-grep-q-allow.txt
pass=0 fail=0

fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
plant() { mkdir -p "$(dirname "$WORK/t/$1")"; cat > "$WORK/t/$1"; }
ledger() { plant "$L"; }

# expect <label> <want-rc> <needle|-> [gate] [args...]
expect() {
  local label=$1 want=$2 needle=$3 gate=${4:-$GATE} out rc
  shift 4 2>/dev/null || shift $#
  out="$(bash "$gate" --root "$WORK/t" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || { [ "$needle" != - ] && ! grep -qF -- "$needle" <<<"$out"; }; then
    echo "FAIL: $label — wanted exit $want and '$needle', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# bad <label> <file> <line...> — a file with a bad line is refused as new.
bad() {
  local label=$1 file=$2; shift 2
  fresh; ledger </dev/null
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } | plant "$file"
  expect "$label" 1 "new pipe(s) into a quiet grep in $file"
}

# good <label> <file> <line...> — a file with this line is clean.
good() {
  local label=$1 file=$2; shift 2
  fresh; ledger </dev/null
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } | plant "$file"
  expect "$label" 0 "none new"
}

echo "== positive control =="
fresh; ledger </dev/null
printf '#!/usr/bin/env bash\nout=$(writer)\n%s -q x <<<"$out"\n' "$G" | plant a.sh
expect "clean input passes" 0 "0 ledgered"

echo "== each spelling is refused =="
bad "-q"                     a.sh "writer $P $G -q x"
bad "-qF"                    a.sh "writer $P $G -qF x"
bad "-Eq"                    a.sh "writer $P $G -Eq 'a|b'"
bad "-qxF"                   a.sh "writer $P $G -qxF -- x"
bad "-iqE"                   a.sh "writer $P $G -iqE x"
bad "--quiet"                a.sh "writer $P $G --quiet x"
bad "--silent"               a.sh "writer $P $G --silent x"
bad "egrep -q"               a.sh "writer $P e$G -q x"
bad "fgrep -q"               a.sh "writer $P f$G -q x"
bad "a path to grep"         a.sh "writer $P /usr/bin/$G -q x"
bad "an env prefix"          a.sh "writer $P LC_ALL=C $G -q x"
bad "a negation"             a.sh "if ! writer $P $G -q x; then echo no; fi"
bad "|& into grep -q"        a.sh "writer |& $G -q x"
bad "the flag after the pattern" a.sh "writer $P $G x -q"
bad "the pipe at the end of the previous line"   a.sh "writer $P" "$G -q x"
bad "a pipe, a backslash, then the grep"         a.sh "writer $P \\" "  $G -q x"
bad "a comment between the pipe and the grep"    a.sh "writer $P" "# note" "$G -q x"
bad "the pipe on the line after a backslash"     a.sh "writer \\" "  $P $G -q x"
bad "a second pipe on one line"                  a.sh "a $P b $P $G -q x"
bad "a file under .githooks with no extension"   .githooks/pre-x "writer $P $G -q x"
bad "a file found by its shebang"                bin/tool "writer $P $G -q x"
fresh; ledger </dev/null
printf 'jobs:\n  t:\n    steps:\n      - run: |\n          writer %s %s -q x\n' "$P" "$G" | plant .github/workflows/w.yml
expect "a workflow run: line" 1 "new pipe(s) into a quiet grep in .github/workflows/w.yml"

echo "== what is not a defect =="
good "a full-line comment"        a.sh "# writer $P $G -q x"
good "an indented comment"        a.sh "    # writer $P $G -q x"
good "-eq is the pattern q"       a.sh "writer $P $G -eq x"
good "-e then a pattern"          a.sh "writer $P $G -e -q x"
good "a non-quiet grep"           a.sh "writer $P $G -c x" "writer $P $G x"
good "a here-string"              a.sh "$G -q x <<<\"\$out\""
good "|| is not a pipe"           a.sh "writer || $G -q x"
good "a quoted -q in a pattern"   a.sh "writer $P $G 'a -q b'"
good "a quiet grep after a line that is not a pipe" a.sh "writer" "$G -q x"
fresh; ledger </dev/null
printf 'writer %s %s -q x\n' "$P" "$G" | plant notes.txt
expect "a file that is not a shell source is not read" 0 "none new"

echo "== the ledger is shrink-only =="
fresh
printf '#!/bin/sh\nw %s %s -q x\nw %s %s -q y\n' "$P" "$G" "$P" "$G" | plant a.sh
printf '# ledger\na.sh:2\n' | plant "$L"
expect "a ledgered offender passes"  0 "2 ledgered"
printf '# ledger\na.sh:1\n' | plant "$L"
expect "a count above the ledger is refused" 1 "GREW in a.sh: 2, ledger allows 1"
printf '# ledger\na.sh:3\n' | plant "$L"
expect "a count below the ledger is stale"   1 "stale ledger entry a.sh:3 — now 2"
printf '# ledger\na.sh:2\nb.sh:1\n' | plant "$L"
expect "a line with no offender is stale"    1 "stale ledger entry b.sh:1"
printf '# ledger\n' | plant "$L"
expect "a file not in the ledger is refused" 1 "new pipe(s)"
printf '# ledger\na.sh:2\na.sh:2\n' | plant "$L"
expect "a duplicate entry is malformed"      1 "malformed or duplicate"
printf '# ledger\na.sh 2\n' | plant "$L"
expect "a malformed entry is refused"        1 "malformed or duplicate"

echo "== --prune =="
fresh
printf '#!/bin/sh\nw %s %s -q x\n' "$P" "$G" | plant a.sh
printf '#!/bin/sh\nclean\n' | plant b.sh
printf '# keep this comment\na.sh:3\nb.sh:2\n\nc.sh:1' | plant "$L"
expect "prune lowers a count and deletes stale lines" 0 "2 line(s) deleted, 1 count(s) lowered" "$GATE" --prune
if [ "$(cat "$WORK/t/$L")" = "$(printf '# keep this comment\na.sh:1\n\n')" ] || [ "$(cat "$WORK/t/$L")" = "$(printf '# keep this comment\na.sh:1\n')" ]; then
  echo "PASS: prune wrote exactly the lowered ledger"; pass=$((pass + 1))
else
  echo "FAIL: prune wrote: $(cat "$WORK/t/$L")"; fail=$((fail + 1))
fi
expect "the ledger now passes"              0 "none stale"
cp "$WORK/t/$L" "$WORK/before"
expect "a second prune changes nothing"     0 "nothing stale" "$GATE" --prune
if cmp -s "$WORK/before" "$WORK/t/$L"; then echo "PASS: idempotent, byte for byte"; pass=$((pass + 1)); else echo "FAIL: second prune changed the ledger"; fail=$((fail + 1)); fi
printf '# ledger\n' | plant "$L"
cp "$WORK/t/$L" "$WORK/before"
expect "prune never adds a line for a new offender" 1 "prune refused" "$GATE" --prune
if cmp -s "$WORK/before" "$WORK/t/$L"; then echo "PASS: the ledger is unchanged after a refused prune"; pass=$((pass + 1)); else echo "FAIL: refused prune changed the ledger"; fail=$((fail + 1)); fi
printf '# ledger\na.sh:1\n' | plant "$L"
printf '#!/bin/sh\nw %s %s -q x\nw %s %s -q y\n' "$P" "$G" "$P" "$G" | plant a.sh
cp "$WORK/t/$L" "$WORK/before"
expect "prune never raises a count"         1 "prune refused" "$GATE" --prune
if cmp -s "$WORK/before" "$WORK/t/$L"; then echo "PASS: the count was not raised"; pass=$((pass + 1)); else echo "FAIL: prune raised a count"; fail=$((fail + 1)); fi

echo "== --print and --list =="
fresh; ledger </dev/null
printf '#!/bin/sh\nw %s %s -q x\n' "$P" "$G" | plant a.sh
expect "--print writes path:count" 0 "a.sh:1" "$GATE" --print
expect "--list writes path:line"   0 "a.sh:2: w $P $G -q x" "$GATE" --list

# ── mutants ───────────────────────────────────────────────────────────────
# mutant <label> <sed-expr> <case-fn> — a copy of the gate with <sed-expr>
# applied must parse, differ, and make <case-fn> FAIL.
mutant() {
  local label=$1 expr=$2 fn=$3 m="$WORK/mutant-gate.sh"
  mkdir -p "$WORK/lib"
  sed "$expr" "$GATE" > "$m"
  if ! bash -n "$m" || cmp -s "$m" "$GATE"; then
    echo "FAIL: mutant ($label) is invalid or identical — it proves nothing"
    fail=$((fail + 1)); return
  fi
  if GATE="$m" "$fn"; then
    echo "FAIL: mutant survived ($label)"; fail=$((fail + 1))
  else
    echo "PASS: mutant killed ($label)"; pass=$((pass + 1))
  fi
}
# Each case runs the gate in $GATE (the mutant) and returns 0 when the gate
# behaved correctly.
m_ledger() {
  fresh
  printf '#!/bin/sh\nw %s %s -q x\n' "$P" "$G" | plant a.sh
  printf 'a.sh:1\n' | plant "$L"
  bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}
m_cluster() {
  fresh; ledger </dev/null
  printf '#!/bin/sh\nw %s %s -Eq x\n' "$P" "$G" | plant a.sh
  ! bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}
m_prevline() {
  fresh; ledger </dev/null
  printf '#!/bin/sh\nw %s\n%s -q x\n' "$P" "$G" | plant a.sh
  ! bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}
m_comment() {
  fresh; ledger </dev/null
  printf '#!/bin/sh\n# w %s %s -q x\n' "$P" "$G" | plant a.sh
  bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}
m_stale() {
  fresh
  printf '#!/bin/sh\nclean\n' | plant a.sh
  printf 'a.sh:1\n' | plant "$L"
  ! bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}
m_hooks() {
  fresh; ledger </dev/null
  printf 'w %s %s -q x\n' "$P" "$G" | plant .githooks/pre-x
  ! bash "$GATE" --root "$WORK/t" >/dev/null 2>&1
}

echo "== mutants =="
mutant "the gate stops reading the ledger" 's/^LEDGER_SNAPSHOT=\$(cat -- "\$LEDGER")$/LEDGER_SNAPSHOT=/;s/^\[ -f "\$LEDGER" \] && LEDGER_SNAPSHOT=\$(cat -- "\$LEDGER")$/LEDGER_SNAPSHOT=/' m_ledger
mutant "the gate ignores flag clusters" 's/for (j = 2; j <= length(tok); j++)/for (j = 2; j <= 2 \&\& j <= length(tok); j++)/' m_cluster
mutant "the gate ignores a pipe on the previous line" 's/if (!hit \&\& prevpipe \&\& match/if (0 \&\& match/' m_prevline
mutant "the gate reads comment lines" 's/^      if (line ~ \/\^\[\[:space:\]\]\*#\/) next$/      if (0) next/' m_comment
mutant "the gate does not call a lowered count stale" 's/elif \[ "\$n" -lt "\$want" \]; then echo "LOWER \$f \$want \$n"/elif false; then :/;s/\[ -z "\${actual\[\$f\]:-}" \] \&\& echo "GONE \$f \${allowed\[\$f\]}"/:/' m_stale
mutant "the gate skips .githooks" 's/\*\.sh|\.githooks\/\*|/*.sh|/' m_hooks

echo "== this repository =="
out="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "PASS: the gate passes on this repository (ledger matches the tree)"; pass=$((pass + 1))
else echo "FAIL: the gate fails on this repository"; printf '%s\n' "$out" | tail -20 | sed 's/^/      | /'; fail=$((fail + 1)); fi

echo
echo "check-pipe-grep-q: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
