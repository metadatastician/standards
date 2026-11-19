#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# kyaml-format-test.sh — fixture suite for scripts/kyaml-format.sh (standards#1022).
#
# A checker that only ever says "clean" proves nothing, so every accepting case
# here has a rejecting twin: a block-YAML file and a hand-mangled KYAML file
# must fail --check, an unparseable or newline-less file must be REFUSED (exit
# 2, never 0), and format mode must preserve the pin comment and be idempotent.
#
# Run: bash scripts/tests/kyaml-format-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FMT="${FMT:-$SCRIPT_DIR/../kyaml-format.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1
pass=0 fail=0

# expect <label> <want-rc> <needle|-> <args...> — runs the formatter and checks
# its exit code and, unless the needle is "-", a substring of its output.
expect() {
  local label=$1 want=$2 needle=$3 out rc
  shift 3
  out="$(bash "$FMT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || { [ "$needle" != "-" ] && ! /usr/bin/grep -qF -- "$needle" <<<"$out"; }; then
    echo "FAIL: $label — wanted exit $want and '$needle', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# check_true <label> <command...> — records a pass when the command succeeds.
check_true() {
  local label=$1
  shift
  if "$@"; then echo "PASS: $label"; pass=$((pass + 1)); else echo "FAIL: $label"; fail=$((fail + 1)); fi
}

cat > "$WORK/block.yml" <<EOF
# SPDX-License-Identifier: MPL-2.0
name: ci
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA # v7.0.1
      - run: |
          echo one
          echo two
EOF
cp "$WORK/block.yml" "$WORK/block.orig"

expect "block YAML fails --check" 1 "is not KYAML" --check "$WORK/block.yml"
check_true "--check rewrote nothing" cmp -s "$WORK/block.yml" "$WORK/block.orig"

expect "format mode rewrites block YAML" 0 "1 rewritten" "$WORK/block.yml"
check_true "the pin comment survives on its uses: line" \
  /usr/bin/grep -qE "uses: \"actions/checkout@$SHA\", # v7\.0\.1" "$WORK/block.yml"
check_true "the formatted file holds the same data" \
  test "$(yq -o json -I 0 'sort_keys(..)' "$WORK/block.orig")" = "$(yq -o json -I 0 'sort_keys(..)' "$WORK/block.yml")"
expect "the formatted file passes --check" 0 "all 1 file(s) are KYAML" --check "$WORK/block.yml"
cp "$WORK/block.yml" "$WORK/pass1"
expect "a second format pass is a no-op" 0 "0 rewritten" "$WORK/block.yml"
check_true "idempotent under cmp" cmp -s "$WORK/block.yml" "$WORK/pass1"

# Mutant: valid YAML, same data, but not the canonical KYAML layout.
sed 's/^  name: "ci",$/  name:    "ci",/' "$WORK/pass1" > "$WORK/mangled.yml"
check_true "the mutant was actually applied" bash -c "! cmp -s '$WORK/pass1' '$WORK/mangled.yml'"
check_true "the mutant still parses" bash -c "yq -e 'has(\"jobs\")' '$WORK/mangled.yml' >/dev/null"
expect "hand-mangled KYAML fails --check" 1 "mangled.yml is not KYAML" --check "$WORK/mangled.yml"

expect "one bad file among clean ones fails the run" 1 "1 of 2 file(s) are not KYAML" \
  --check "$WORK/pass1" "$WORK/mangled.yml"

printf 'jobs: {\n  a: [\n' > "$WORK/broken.yml"
expect "an unparseable file is REFUSED, not clean" 2 "does not parse" --check "$WORK/broken.yml"
expect "an unparseable file is REFUSED in format mode too" 2 "REFUSED" "$WORK/broken.yml"

printf 'a:\n  run: |\n    echo x' > "$WORK/nonl.yml"
expect "a file with no final newline is REFUSED" 2 "no final newline" --check "$WORK/nonl.yml"

expect "a missing file is REFUSED" 2 "no such file" --check "$WORK/does-not-exist.yml"
expect "no arguments is REFUSED" 2 "no files given" --check

echo
echo "kyaml-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
