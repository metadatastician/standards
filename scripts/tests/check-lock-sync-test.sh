#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression tests for issue #968: compare workflow refs in both directions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_SCRIPT="$ROOT/scripts/check-lock-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WF="$TMP/workflows"
mkdir -p "$WF"
pass=0
fail=0

expect() {
  local want="$1" label="$2" out rc=0
  out="$(bash "$CHECK_SCRIPT" "$WF" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (expected $want, got $rc)"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
}

cat > "$WF/test.yml" <<'YAML'
jobs:
  test:
    steps:
      - uses: Actions/Checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
expect 1 'missing lockfile fails closed'
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/test.yml':
        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
YAML
expect 0 'repository names compare case-insensitively'
sed -i 's/Actions\/Checkout/actions\/checkout/' "$WF/test.yml"
expect 0 'matching block workflow is accepted'

cat > "$WF/test.yml" <<'YAML'
{
  jobs: {
    test: {
      steps: [
        {
          uses: "actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", # pinned
        },
        {
          uses: 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
      ],
    },
  },
}
YAML
expect 0 'KYAML quoted refs exclude the trailing comma'
sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/g' "$WF/test.yml"
expect 1 'KYAML changed SHA remains a failure'

cat > "$WF/test.yml" <<'YAML'
jobs:
  test:
    uses: owner/repo/.github/workflows/test.yml@Release
YAML
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/test.yml':
        - 'Owner/Repo@Release'
YAML
expect 0 'job-level reusable workflow is checked and lock names normalised'
sed -i 's/@Release/@release/' "$WF/test.yml"
expect 1 'ref case remains significant'
sed -i 's/@release/@Release/' "$WF/test.yml"
printf "        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\n" >> "$WF/actions.lock"
expect 1 'stale lock entries remain failures'
sed -i '/actions\/checkout/d' "$WF/actions.lock"
# A workflow with no lockfile entry is fatal when it has a STEP-LEVEL use (the
# ref GitHub must find under that path), and harmless when its only use is a
# job-level reusable call — measured across 159 repositories (standards#968) and
# the shape hyperpolymath/unified-dataset-vocab#81 ships.
cp "$WF/test.yml" "$WF/unlocked.yml"
expect 0 'job-level-only workflow with no lock entry is not fatal (standards#968)'
cat > "$WF/unlocked.yml" <<'YAML'
jobs:
  test:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
expect 1 'workflow missing from lock remains a failure (step-level)'
rm "$WF/unlocked.yml"
rm "$WF/test.yml"
expect 1 'deleted workflow lock entries remain failures'

# Local composite actions (standards#1122): the refs a local composite uses,
# nested composites included, are locked under the calling workflow.
R="$TMP/r"
WF="$R/.github/workflows"
mkdir -p "$WF" "$R/.github/actions/push" "$R/.github/actions/token"
cat > "$WF/smoke.yml" <<'YAML'
jobs:
  smoke:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - uses: ./.github/actions/push
      - uses: ./.github/workflows/not-followed.yml
YAML
cat > "$R/.github/actions/push/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: ./.github/actions/token
    - uses: asana/push-signed-commits@cccccccccccccccccccccccccccccccccccccccc # v1
YAML
cat > "$R/.github/actions/token/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: "actions/create-github-app-token@dddddddddddddddddddddddddddddddddddddddd",
YAML
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/smoke.yml':
        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        - 'actions/create-github-app-token@dddddddddddddddddddddddddddddddddddddddd'
        - 'asana/push-signed-commits@cccccccccccccccccccccccccccccccccccccccc'
YAML
expect 0 'refs used through local composites (nested, KYAML) count as used'
cp "$WF/actions.lock" "$TMP/full.lock"
# The planted negative from the issue: the two composite lines deleted.
sed -i '/create-github-app-token/d; /push-signed-commits/d' "$WF/actions.lock"
expect 1 'composite deps missing from the calling workflow entry fail'
cp "$TMP/full.lock" "$WF/actions.lock"
sed -i '/push-signed-commits/d' "$R/.github/actions/push/action.yml"
expect 1 'a ref no composite uses any more is stale'

printf '\ncheck-lock-sync regression: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
