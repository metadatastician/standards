#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# lock-selfcheck-test.sh — fixture suite for scripts/lock-selfcheck.sh, covering
# its YAML-syntax independence (YAML-POLICY Y-1 / Y-3).
#
# lock-selfcheck reads workflows at a commit and asks whether every action ref
# is keyed in that commit's own actions.lock. Its old line grep captured
# `…@sha",` from a KYAML workflow and called a self-consistent commit POISON.
# Each case is one commit in a throwaway repo, checked via STANDARDS_DIR.
#
# Run: bash scripts/tests/lock-selfcheck-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFCHECK="${SELFCHECK:-$SCRIPT_DIR/../lock-selfcheck.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOCKED=3d3c42e5aac5ba805825da76410c181273ba90b1
UNLOCKED=1111111111111111111111111111111111111111
REPO="$WORK/repo"
WF="$REPO/.github/workflows"

mkdir -p "$WF"
git -C "$REPO" init -q -b main .
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
git -C "$REPO" config commit.gpgsign false
# A closed lock: the workflow ref has its own top-level record, as every lock
# GitHub and Hypatia accept must (standards#963).
cat > "$WF/actions.lock" <<EOF
version: 'v0.0.2'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$LOCKED'
dependencies:
    'actions/checkout@$LOCKED':
        ref: 'v7.0.1'
        commit: 'sha1-$LOCKED'
        owner_id: 1
        repo_id: 2
EOF

pass=0 fail=0

# commit_ci — commits stdin as .github/workflows/ci.yml and prints the new SHA.
commit_ci() {
  cat > "$WF/ci.yml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m fixture
  git -C "$REPO" rev-parse HEAD
}

# expect <label> <sha> <want-rc> <needle>... [-- <absent>...] — runs
# lock-selfcheck on one commit and checks its exit code, that every needle
# appears in its output, and that every string after `--` does not.
expect() {
  local label=$1 sha=$2 want=$3 out rc s absent=0 bad=
  shift 3
  out="$(cd "$WORK" && STANDARDS_DIR="$REPO" bash "$SELFCHECK" "$sha" 2>&1)"; rc=$?
  [ "$rc" -eq "$want" ] || bad="exit $rc"
  for s in "$@"; do
    if [ "$s" = "--" ]; then absent=1; continue; fi
    if printf '%s' "$out" | /usr/bin/grep -qF -- "$s"; then
      [ "$absent" -eq 0 ] || bad="${bad:+$bad; }unwanted '$s'"
    else
      [ "$absent" -eq 1 ] || bad="${bad:+$bad; }missing '$s'"
    fi
  done
  if [ -n "$bad" ]; then
    echo "FAIL: $label — wanted exit $want; $bad"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF
)
expect "block control: keyed ref is self-consistent" "$sha" 0 "VERDICT: SELF-CONSISTENT"

sha=$(commit_ci <<EOF
# SPDX-License-Identifier: MPL-2.0
{
  jobs: {
    a: {
      steps: [
        { uses: "actions/checkout@$LOCKED", # v7.0.1
        },
      ],
    },
  },
}
EOF
)
expect "KYAML: keyed, quoted ref is self-consistent" "$sha" 0 "VERDICT: SELF-CONSISTENT"

sha=$(commit_ci <<EOF
{
  jobs: {
    a: {
      steps: [
        { uses: "actions/checkout@$LOCKED" },
        { uses: "actions/setup-node@$UNLOCKED" },
      ],
    },
  },
}
EOF
)
expect "KYAML mutant: unkeyed ref is POISON" "$sha" 1 "uses  actions/setup-node@$UNLOCKED"

sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED
      - run: |
          echo "uses: actions/setup-node@$UNLOCKED"
EOF
)
expect "a uses: inside a run: body is not a ref" "$sha" 0 "VERDICT: SELF-CONSISTENT"

sha=$(printf '{\n  jobs: {\n' | commit_ci)
expect "an unparseable workflow is UNEXAMINED, not consistent" "$sha" 1 "VERDICT: UNEXAMINED"

cat > "$WF/actions.lock" <<EOF
version: 'v0.0.2'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$LOCKED'
dependencies:
    'actions/checkout@$LOCKED':
        ref: '$LOCKED'
        commit: 'sha1-$LOCKED'
        owner_id: 1
        repo_id: 2
EOF
sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF
)
expect "self-SHA ref in dependencies is POISON (standards#1271)" "$sha" 1 "self-SHA ref  actions/checkout@$LOCKED"

sed -i "s/ref: '$LOCKED'/ref: 'v7.0.1'/" "$WF/actions.lock"
sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF
)
expect "symbolic tag ref in dependencies is SELF-CONSISTENT" "$sha" 0 "VERDICT: SELF-CONSISTENT"

# The standards#963 shape: a record's nested uses: names a ref that has no
# record of its own. Every workflow ref is keyed, so only closure catches it.
cat >> "$WF/actions.lock" <<EOF
        uses:
            - 'actions/setup-python@v2'
EOF
sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF
)
expect "a dangling nested edge is POISON (standards#963)" "$sha" 1 "dangling edge(s) in this SHA's own lock"
expect "the dangling ref is named" "$sha" 1 "actions/setup-python@v2"

# A lock close-lock.sh cannot read (here a duplicate mapping key, which the
# parser refuses) is not a dangling edge: closure was never examined, so the
# verdict is UNEXAMINED, and the SHA is still unsafe to pin to.
cat > "$WF/actions.lock" <<EOF
version: 'v0.0.2'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$LOCKED'
dependencies:
    'actions/checkout@$LOCKED':
        ref: 'v7.0.1'
        ref: 'v7.0.1'
        commit: 'sha1-$LOCKED'
        owner_id: 1
        repo_id: 2
EOF
sha=$(commit_ci <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$LOCKED # v7.0.1
EOF
)
expect "an unreadable lock is UNEXAMINED, not a dangling edge" "$sha" 1 \
  "VERDICT: UNEXAMINED — close-lock.sh --check exited 2" \
  "actions-lock: malformed YAML, multiple documents or duplicate mapping keys" \
  -- "VERDICT: POISON"

# With both causes at once, each UNEXAMINED verdict is reported.
sha=$(printf '{\n  jobs: {\n' | commit_ci)
expect "an unparseable workflow and an unreadable lock are both reported" "$sha" 1 \
  "yq could not parse" "close-lock.sh --check exited 2" -- "VERDICT: POISON"

echo
echo "lock-selfcheck: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
