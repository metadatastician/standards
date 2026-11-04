#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Check repository-name matching without changing the canonical allowlist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/workflows"
cat > "$WORK/allowed-actions.json" <<'JSON'
{"github_owned_allowed":true,"patterns_allowed": ["Swatinem/rust-cache@*", "ExampleOrg/*", "Tools/build-*@*", "metadatastician/standards/.github/workflows/*@*", "pinned/action@v1"]}
JSON
pass=0
fail=0

# Check one workflow reference against the same synthetic policy.
expect() {
  local want="$1" ref="$2" label="$3" rc=0 out
  printf 'jobs:\n  test:\n    steps:\n      - uses: %s\n' "$ref" > "$WORK/workflows/test.yml"
  out="$(bash "$ROOT/scripts/check-allowed-actions.sh" "$WORK/allowed-actions.json" "$WORK/workflows" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (expected $want, got $rc)"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
}

expect 0 'Swatinem/rust-cache@v2' 'exact spelling remains accepted'
expect 0 'swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6' 'lowercase owner matches mixed-case policy'
expect 0 'SWATINEM/RUST-CACHE@v2' 'owner and repository case are ignored'
expect 0 'exampleorg/repo/.github/workflows/build.yml@Release' 'owner wildcard covers mixed-case reusable workflow'
expect 0 'TOOLS/BUILD-helper@v1' 'repository glob ignores case'
expect 0 'Actions/Checkout@v4' 'GitHub-owned action ignores case'
expect 0 'metadatastician/standards/.github/workflows/governance-reusable.yml@abc' 'narrow canonical reusable pattern is accepted'
expect 0 'METADATASTICIAN/STANDARDS/.github/workflows/x.yml@abc' 'narrow pattern ignores owner/repo case'
expect 1 'metadatastician/standards/other/action@abc' 'narrow reusable pattern does not allow another path'
expect 1 'metadatastician/standards/.GITHUB/workflows/x.yml@abc' 'workflow path components remain case-sensitive'
expect 1 'metadatastician/standards@abc' 'narrow reusable pattern does not allow the repository root'
expect 1 'metadatastician/another/.github/workflows/x.yml@abc' 'narrow reusable pattern does not allow another repository'
expect 0 'pinned/action@v1' 'specific allowed ref matches exactly'
expect 1 'pinned/action@v2' 'specific allowed ref does not allow another version'
expect 1 'pinned/action/nested@v1' 'repository-only pattern does not widen to subpaths'
expect 1 'pinned/action@V1' 'action refs remain case-sensitive'
expect 1 'unlisted/rust-cache@v2' 'unlisted owner is rejected'
expect 1 'swatinem/other@v2' 'unlisted repository is rejected'
expect 1 'exampleorg-extra/repo@v1' 'owner wildcard cannot match a different owner'
expect 1 'tools/test-helper@v1' 'repository glob still rejects nonmatching names'

# GitHub-owned creators are not implicitly allowed when the flag is disabled.
jq '.github_owned_allowed = false' "$WORK/allowed-actions.json" > "$WORK/disabled.json"
mv "$WORK/disabled.json" "$WORK/allowed-actions.json"
expect 1 'actions/checkout@v4' 'disabled GitHub-owned flag is respected'

for policy in config/settings/actions-allowlist.json rhodium-standard-repositories/actions-allowlist/allowed-actions.json; do
  if jq -e '.patterns_allowed | index("metadatastician/standards/.github/workflows/*@*") != null' "$ROOT/$policy" >/dev/null; then
    echo "PASS: $policy carries the narrow reusable allowance"; pass=$((pass + 1))
  else
    echo "FAIL: $policy is missing the narrow reusable allowance"; fail=$((fail + 1))
  fi
done

# These two Google actions are already admitted by the canonical live-policy
# payload. Both explicit subpaths must also pass the conservative tree check;
# the repository-root pattern deliberately does not grant arbitrary subpaths.
for policy in config/settings/actions-allowlist.json rhodium-standard-repositories/actions-allowlist/allowed-actions.json; do
  cp "$ROOT/$policy" "$WORK/allowed-actions.json"
  expect 0 'google/clusterfuzzlite/actions/build_fuzzers@884713a6c30a92e5e8544c39945cd7cb630abcd1' "$policy admits the reviewed build action"
  expect 0 'google/clusterfuzzlite/actions/run_fuzzers@v1' "$policy admits the reviewed run action"
  expect 1 'google/clusterfuzzlite/actions/unreviewed-action@v1' "$policy rejects other action subpaths"
done

printf '\nallowlist regression: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
