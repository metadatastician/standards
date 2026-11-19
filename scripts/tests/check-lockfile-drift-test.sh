#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-lockfile-drift-test.sh — fixture suite for scripts/check-lockfile-drift.sh,
# covering its YAML-syntax independence (YAML-POLICY Y-1 / Y-3).
#
# The script used to line-grep `uses:[[:space:]]*owner/repo@ref`. A KYAML
# workflow quotes the value (`uses: "owner/repo@ref",`), so the grep matched
# nothing and a drifted KYAML workflow scanned CLEAN. It also read `uses:` text
# inside a `run:` body as a ref, and called an unparseable workflow clean.
# Each case runs the script on a fixture repo; exit 0 clean, 1 drift, 2 withheld.
#
# Run: bash scripts/tests/check-lockfile-drift-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT="${DRIFT:-$SCRIPT_DIR/../check-lockfile-drift.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOCKED=3d3c42e5aac5ba805825da76410c181273ba90b1
WF="$WORK/repo/.github/workflows"
mkdir -p "$WF"
cat > "$WF/actions.lock" <<EOF
version: 'v0.0.2'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@v7.0.1'
dependencies:
    'actions/checkout@v7.0.1':
        ref: 'v7.0.1'
        commit: 'sha1-$LOCKED'
EOF

pass=0 fail=0

# expect <label> <want-rc> <needle|-> — writes stdin to ci.yml, runs the script
# on the fixture repo, and checks its exit code and, unless "-", an output substring.
expect() {
  local label=$1 want=$2 needle=$3 out rc
  cat > "$WF/ci.yml"
  out="$(bash "$DRIFT" "$WORK/repo" fixture 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! /usr/bin/grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $label — exit $rc correct, but output lacked '$needle'"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

expect "block control: the locked tag is clean" 0 "clean" <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v7.0.1
EOF

expect "block control: the locked commit by SHA is clean" 0 "clean" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF

expect "block mutant: a different tag is drift" 1 "actions/checkout@v6.0.0" <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v6.0.0
EOF

expect "KYAML: the locked tag, quoted, is clean" 0 "clean" <<'EOF'
# SPDX-License-Identifier: MPL-2.0
{
  jobs: {
    a: {
      steps: [
        { uses: "actions/checkout@v7.0.1", # v7.0.1
        },
      ],
    },
  },
}
EOF

expect "KYAML mutant: a different tag, quoted, is drift" 1 "actions/checkout@v6.0.0" <<'EOF'
{
  jobs: {
    a: {
      steps: [
        { uses: "actions/checkout@v6.0.0" },
      ],
    },
  },
}
EOF

expect "a uses: inside a run: body is not a ref" 0 "clean" <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v7.0.1
      - run: |
          echo "uses: actions/checkout@v6.0.0"
EOF

expect "an unparseable workflow is withheld, not clean" 2 "ci.yml: not parseable" <<'EOF'
{
  jobs: {
EOF

# `name: "X` whose quote closes only on a later line swallows the whole
# workflow into one scalar that still parses (measured: 007-lang oracle-fuzz.yml).
expect "a quote-swallowed workflow with no jobs is withheld" 2 "has no jobs: map" <<'EOF'
name: "CHECK: broken
on: push
jobs:
  a:
    steps:
      - uses: actions/checkout@v6.0.0
      - run: echo hi"
EOF

echo
echo "check-lockfile-drift: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
