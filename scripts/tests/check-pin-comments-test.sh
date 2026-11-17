#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# check-pin-comments-test.sh — fixture suite for scripts/check-pin-comments.sh
# (standards#1440): a `# <ref>` pin comment must agree with the reviewed ref
# actions.lock records for that pin. Ends by holding this repository's own
# workflows to the rule.
#
# Run: bash scripts/tests/check-pin-comments-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
checker="$root/scripts/check-pin-comments.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
wf="$tmp/workflows"
mkdir -p "$wf"

A=683b588c487a69d01f6c6ddf40f036ff682cc2c8
B=d1527c8f67ef9af357290475d4af4b0fab8f12e0
C=bfa851f5291edd82d01dfb33cb8d81b3002d2f89
cat > "$wf/actions.lock" <<EOF
version: 'v0.0.3'
dependencies:
    'dtolnay/rust-toolchain@$A':
        ref: 'v1'
        commit: 'sha1-$A'
    'swatinem/rust-cache@$B':
        ref: 'v2.9.3'
        commit: 'sha1-$B'
    'metadatastician/standards@$C':
        ref: '$C'
        commit: 'sha1-$C'
EOF

pass=0 fail=0
# expect <label> <want-rc> <needle|-> — the workflow body is stdin.
expect() {
  local label=$1 want=$2 needle=$3 out rc
  cat > "$wf/ci.yml"
  out="$(bash "$checker" "$wf" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc"; printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — exit $rc correct, but output lacked '$needle'"; printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

expect "exact control (block style)" 0 "1 judged" <<EOF
jobs:
  a:
    steps:
      - uses: dtolnay/rust-toolchain@$A # v1
EOF

expect "a branch name (#1440: # stable) is refused" 1 "Write '# v1'" <<EOF
jobs:
  a:
    steps:
      - uses: dtolnay/rust-toolchain@$A # stable
EOF

expect "the major tag of the reviewed release passes (v2 for v2.9.3)" 0 "1 judged" <<EOF
jobs:
  a:
    steps:
      - uses: Swatinem/rust-cache@$B # v2
EOF

expect "another major is refused (v1 for v2.9.3)" 1 "'v1' does not name it" <<EOF
jobs:
  a:
    steps:
      - uses: swatinem/rust-cache@$B # v1
EOF

expect "the minor-line tag passes, trailing words ignored (v2.9 for v2.9.3)" 0 "1 judged" <<EOF
jobs:
  a:
    steps:
      - uses: swatinem/rust-cache@$B # v2.9 (pinned)
EOF

expect "a sibling release is refused (v2.9.4 for v2.9.3)" 1 "'v2.9.4' does not name it" <<EOF
jobs:
  a:
    steps:
      - uses: swatinem/rust-cache@$B # v2.9.4
EOF

expect "a malformed prefix is refused (v2.9. for v2.9.3)" 1 "'v2.9.' does not name it" <<EOF
jobs:
  a:
    steps:
      - uses: swatinem/rust-cache@$B # v2.9.
EOF

expect "an uncommented pin is counted, not judged" 0 "1 without a comment" <<EOF
jobs:
  a:
    steps:
      - uses: dtolnay/rust-toolchain@$A
EOF

expect "a pin with no lock record is counted, not judged" 0 "1 without a reviewed lock ref" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v4
EOF

expect "a caller-side record whose ref is its SHA is not judged" 0 "1 without a reviewed lock ref" <<EOF
jobs:
  a:
    uses: metadatastician/standards/.github/workflows/x.yml@$C # main
EOF

expect "a uses: inside a run: body is not a pin" 0 "0 SHA pin(s)" <<EOF
jobs:
  a:
    steps:
      - run: |
          echo "uses: dtolnay/rust-toolchain@$A # stable"
EOF

expect "an unparseable workflow is an error, never a pass" 2 "cannot parse" <<EOF
jobs: [unterminated
EOF

rm -f "$wf/ci.yml"
out="$(bash "$checker" "$tmp/none" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then echo "PASS: a missing workflow directory exits 2"; pass=$((pass + 1));
else echo "FAIL: a missing workflow directory exits $rc, want 2 — $out"; fail=$((fail + 1)); fi

# This repository's own workflows.
if out="$(cd "$root" && bash "$checker" 2>&1)"; then
  echo "PASS: standards' own workflows — ${out#OK: }"; pass=$((pass + 1))
else
  echo "FAIL: standards' own pin comments disagree with actions.lock"; printf '%s\n' "$out" | sed 's/^/      | /'
  fail=$((fail + 1))
fi

echo
echo "check-pin-comments: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
