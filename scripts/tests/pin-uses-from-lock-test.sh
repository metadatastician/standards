#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# pin-uses-from-lock-test.sh — fixture suite for scripts/pin-uses-from-lock.sh.
#
# Each verdict the script can give is planted once, and the suite checks the
# bytes it writes: only `uses:` lines with a locked tag change, the SHA is the
# lock record's commit, quotes and sub-paths survive, a ref keeps its case
# while owner/repo folds, a missing final newline stays missing, a dry run
# writes nothing, and a second run is a no-op.
#
# Run: bash scripts/tests/pin-uses-from-lock-test.sh
# TARGET=<path> runs the suite against another copy (used for mutant checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-$SCRIPT_DIR/../pin-uses-from-lock.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
A=1111111111111111111111111111111111111111
C=3333333333333333333333333333333333333333
Q=5555555555555555555555555555555555555555
R=6666666666666666666666666666666666666666
U=7777777777777777777777777777777777777777

# ok: record and print a passing assertion.
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
# bad: record and print a failing assertion.
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
# expect: assert that two strings are equal.
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

d="$WORK/r/.github/workflows"; mkdir -p "$d"
cat > "$d/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@v7
      - uses: github/codeql-action/init@v4
      - name: quoted
        uses: 'o/single@v2'
      - uses: "o/double@v3"
      - uses: Swatinem/rust-cache@v2.9.3
      - uses: o/case@V1
      - uses: o/case@v1
      - uses: actions/cache@$C # v4
      - uses: o/expr@\${{ matrix.v }}
      - uses: o/commented@v5 # keep me
      - uses: o/absent@v9
      - uses: ./local-action
      - uses: docker://alpine:3
      - run: |
          echo uses: o/inside@v2
EOF
# A lock key in mixed case: owner/repo folds on the lock side too.
printf "jobs:\n  c:\n    steps:\n      - uses: o2/mixed@v1\n" > "$d/mixed.yml"
# No final newline, on purpose.
printf 'jobs:\n  b:\n    steps:\n      - uses: actions/checkout@v7' > "$d/release.yaml"
cat > "$d/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@v7'
dependencies:
    'actions/checkout@v7':
        ref: 'v7'
        commit: 'sha1-$A'
        owner_id: 1
        repo_id: 2
    'actions/cache@$C':
        ref: 'v4'
        commit: 'sha1-$C'
        owner_id: 1
        repo_id: 3
    'github/codeql-action@v4':
        ref: 'v4'
        commit: 'sha1-$Q'
        owner_id: 1
        repo_id: 4
    'o/single@v2':
        ref: 'v2'
        commit: 'sha1-$R'
        owner_id: 1
        repo_id: 5
    'o/double@v3':
        ref: 'v3'
        commit: 'sha1-$R'
        owner_id: 1
        repo_id: 6
    'swatinem/rust-cache@v2.9.3':
        ref: 'v2.9.3'
        commit: 'sha1-$U'
        owner_id: 1
        repo_id: 7
    'o/case@V1':
        ref: 'V1'
        commit: 'sha1-$U'
        owner_id: 1
        repo_id: 8
    'O2/Mixed@v1':
        ref: 'v1'
        commit: 'sha1-$Q'
        owner_id: 1
        repo_id: 10
    'o/commented@v5':
        ref: 'v5'
        commit: 'sha1-$U'
        owner_id: 1
        repo_id: 9
EOF
cp -r "$WORK/r" "$WORK/orig"

# --- dry run: reports, writes nothing -------------------------------------
cd "$WORK/r" || exit 1
out="$(bash "$TARGET" .github/workflows 2>"$WORK/err")"; rc=$?
expect "dry run exits 0" "$rc" 0
if diff -r "$WORK/orig" "$WORK/r" >/dev/null; then ok "dry run writes nothing"; else bad "dry run changed files"; fi
verdict() { awk -F'\t' -v f="$1" -v l="$2" '$1 == f && $2 == l { print $5 }' <<<"$out"; }
expect "tag in the lock is pinned"            "$(verdict .github/workflows/ci.yml 4)"  pinned
expect "sub-path action uses its repo record" "$(verdict .github/workflows/ci.yml 5)"  pinned
expect "single-quoted ref is pinned"          "$(verdict .github/workflows/ci.yml 7)"  pinned
expect "double-quoted ref is pinned"          "$(verdict .github/workflows/ci.yml 8)"  pinned
expect "owner/repo folds case"                "$(verdict .github/workflows/ci.yml 9)"  pinned
expect "a ref keeps its case (V1 found)"      "$(verdict .github/workflows/ci.yml 10)" pinned
expect "a ref keeps its case (v1 not found)"  "$(verdict .github/workflows/ci.yml 11)" unlocked
expect "SHA ref is already pinned"            "$(verdict .github/workflows/ci.yml 12)" already-pinned
expect "expression ref is left"               "$(verdict .github/workflows/ci.yml 13)" expression
expect "commented line is left"               "$(verdict .github/workflows/ci.yml 14)" commented
expect "unlocked tag is left"                 "$(verdict .github/workflows/ci.yml 15)" unlocked
expect "local, docker and run: text are not listed" \
  "$(awk -F'\t' '$1 == ".github/workflows/ci.yml" && $2 >= 16' <<<"$out" | wc -l | tr -d ' ')" 0
expect "a mixed-case lock key is found" "$(verdict .github/workflows/mixed.yml 4)" pinned
expect "the file with no final newline is read" "$(verdict .github/workflows/release.yaml 4)" pinned
expect "summary counts 8 pinned in 3 files" \
  "$(grep -c '8 uses: pinned in 3 file(s) (dry run); 5 left' "$WORK/err")" 1

# --- --write: exact bytes -------------------------------------------------
bash "$TARGET" --write .github/workflows >/dev/null 2>&1; rc=$?
expect "--write exits 0" "$rc" 0
line() { sed -n "${2}p" ".github/workflows/$1"; }
expect "plain rewrite"     "$(line ci.yml 4)"  "      - uses: actions/checkout@$A # v7"
expect "sub-path kept"     "$(line ci.yml 5)"  "      - uses: github/codeql-action/init@$Q # v4"
expect "single quotes kept, comment after them" "$(line ci.yml 7)" "        uses: 'o/single@$R' # v2"
expect "double quotes kept" "$(line ci.yml 8)" "      - uses: \"o/double@$R\" # v3"
expect "workflow spelling of owner kept" "$(line ci.yml 9)" "      - uses: Swatinem/rust-cache@$U # v2.9.3"
expect "commented line untouched" "$(line ci.yml 14)" "      - uses: o/commented@v5 # keep me"
changed="$(diff "$WORK/orig/.github/workflows/ci.yml" .github/workflows/ci.yml | grep -c '^>')"
expect "only the 6 pinned lines of ci.yml change" "$changed" 6
if cmp -s "$WORK/orig/.github/workflows/actions.lock" .github/workflows/actions.lock; then
  ok "the lock is not touched"; else bad "the lock changed"; fi
expect "missing final newline stays missing" "$(tail -c1 .github/workflows/release.yaml)" "7"
expect "last line rewritten" "$(tail -n1 .github/workflows/release.yaml)" "      - uses: actions/checkout@$A # v7"

# --- idempotent -------------------------------------------------------------
cp -r "$WORK/r" "$WORK/once"
bash "$TARGET" --write .github/workflows >/dev/null 2>"$WORK/err2"
if diff -r "$WORK/once" "$WORK/r" >/dev/null; then ok "a second --write changes nothing"; else bad "second run changed files"; fi
expect "second run pins nothing" "$(grep -c '^pin-uses-from-lock: 0 uses: pinned' "$WORK/err2")" 1

# --- refusals ---------------------------------------------------------------
mkdir -p "$WORK/nolock/.github/workflows"
bash "$TARGET" "$WORK/nolock/.github/workflows" >/dev/null 2>&1; expect "missing lock exits 1" "$?" 1
mkdir -p "$WORK/badlock/.github/workflows"
printf "dependencies:\n    'o/x@v1':\n        ref: 'v1'\n        commit: 'abc'\n" > "$WORK/badlock/.github/workflows/actions.lock"
bash "$TARGET" "$WORK/badlock/.github/workflows" >/dev/null 2>&1; expect "a non-sha1 commit exits 1" "$?" 1
bash "$TARGET" --frobnicate >/dev/null 2>&1; expect "unknown option exits 2" "$?" 2

echo "pin-uses-from-lock-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
