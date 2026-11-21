#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# bump-action-pins-test.sh — offline known-answer tests for
# scripts/bump-action-pins.sh. `gh` is a stub answering from fixed tables.
#
# Run: bash scripts/tests/bump-action-pins-test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../bump-action-pins.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
expect() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi; }

cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$2" in
  repos/foo/bar/releases/latest)   echo v2.1.0 ;;
  repos/foo/same/releases/latest)  echo v3.0.0 ;;
  repos/foo/old/releases/latest)   echo v9.0.0 ;;
  repos/foo/rc/releases/latest)    echo v5.0.0-rc1 ;;
  repos/foo/ann/releases/latest)   echo v1.0.0 ;;
  repos/foo/shared/releases/latest) echo v2.0.0 ;;
  repos/foo/bar/git/ref/tags/v2.1.0)  echo "commit 4444444444444444444444444444444444444444" ;;
  repos/foo/ann/git/ref/tags/v1.0.0)  echo "tag aaaa" ;;
  repos/foo/ann/git/tags/aaaa)        echo "commit 6666666666666666666666666666666666666666" ;;
  repos/foo/shared/git/ref/tags/v2.0.0) echo "commit 7777777777777777777777777777777777777777" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/gh"
export GH_BIN="$WORK/gh" GH_LOG="$WORK/gh.log"
echo '# test holds
held/thing*' > "$WORK/holds"
export BUMP_HOLDS="$WORK/holds"

D="$WORK/repo"; mkdir -p "$D/.github/workflows" "$D/.github/actions/x"
A=1111111111111111111111111111111111111111
cat > "$D/.github/workflows/ci.yml" <<YML
jobs:
  a:
    steps:
      - uses: foo/bar@$A # v2.0
      - uses: foo/bar@$A # v2.0 extra words
      - uses: "foo/bar@$A" # v2.0
      - uses: foo/same@3333333333333333333333333333333333333333 # v3.0.0
      - uses: foo/old@2222222222222222222222222222222222222222 # v9.9.9
      - uses: foo/rc@2222222222222222222222222222222222222222 # v4.0.0
      - uses: foo/ann@$A # v0.9.0
      - uses: foo/shared@$A # v1.0.0
      - uses: held/thing/sub@$A # v1.0.0
      - uses: hyperpolymath/x/.github/workflows/y.yml@$A # v1
      - uses: foo/nocomment@$A
      - uses: foo/branch@main
      - uses: ./.github/actions/x
      - uses: foo/unversioned@$A # stable
      - uses: foo/missing@$A # v1.0.0
YML
cat > "$D/.github/actions/x/action.yml" <<YML
runs:
  using: composite
  steps:
    - uses: foo/bar@$A # v2.0
YML
rows="$(bash "$TARGET" "$D")"; rc=$?
verdict() { printf '%s\n' "$rows" | awk -F'\t' -v a="$1" -v f="${2:-ci.yml}" '$2==a && index($1,f){print $5; exit}'; }
expect "exits 0" 0 "$rc"
expect "an older pin is bumped" bumped "$(verdict foo/bar)"
expect "a pin already at the latest is current" current "$(verdict foo/same)"
expect "a pin newer than the latest release is never downgraded" current "$(verdict foo/old)"
expect "a pre-release latest tag is not compared" unparsed "$(verdict foo/rc)"
expect "an annotated tag is peeled to its commit" bumped "$(verdict foo/ann)"
expect "a held repository is skipped (subpath matches by glob)" held "$(verdict held/thing/sub)"
expect "a first-party ref is left to apply-workflow-pins" first-party "$(verdict hyperpolymath/x/.github/workflows/y.yml)"
expect "a repository with no readable release is reported" no-release "$(verdict foo/missing)"
expect "a non-version pin comment is unparsed" unparsed "$(verdict foo/unversioned)"
W="$D/.github/workflows/ci.yml"
expect "every foo/bar line in the workflow carries the new SHA" 3 "$(grep -c 'foo/bar.*@4444444444444444444444444444444444444444' "$W")"
expect "…and the new tag in the comment" 3 "$(grep 'foo/bar@4444' "$W" | grep -c '# v2.1.0')"
expect "…trailing words on the comment survive" 1 "$(grep -c '# v2.1.0 extra words' "$W")"
expect "…the quoted form keeps its quotes" 1 "$(grep -c '"foo/bar@4444444444444444444444444444444444444444"' "$W")"
expect "…the composite action is bumped too" 1 "$(grep -c '4444444444444444444444444444444444444444 # v2.1.0' "$D/.github/actions/x/action.yml")"
expect "…an annotated tag lands on the commit, not the tag object" 1 "$(grep -c 'foo/ann@6666666666666666666666666666666666666666 # v1.0.0' "$W")"
expect "…a pin at the same SHA for a different action keeps its own SHA" 1 "$(grep -c "foo/shared@7777777777777777777777777777777777777777 # v2.0.0" "$W")"
expect "…nothing else moved (held, first-party, no comment, non-version comment, no release)" 5 "$(grep -c "$A" "$W" | awk '{print $1}')"
expect "one release lookup per repository, not per line" 1 "$(grep -c 'repos/foo/bar/releases/latest' "$GH_LOG")"
expect "a second run changes nothing" "0" "$(bash "$TARGET" "$D" | grep -c '	bumped$')"
bash "$TARGET" "$WORK/none" >/dev/null 2>&1; expect "a directory with no .github is an error" 2 "$?"

echo; echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
