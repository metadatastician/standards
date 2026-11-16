#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_settings_drift_canon_patterns.sh — scripts/check-settings-drift.sh must
# report a NON-empty Actions allow-list that has lost canonical patterns.
#
# Why: from 2026-11-09 (ordinal-notation) and 2026-11-14 (mathesis) the live
# selected-actions list of each repository lacked
# editorconfig-checker/action-editorconfig-checker@* and haskell-actions/setup@*.
# Every run of a workflow using one died at startup_failure with no check run.
# The drift sweep passed both repos, because it checked only for an EMPTY list
# and verified_allowed=false. These cases pin the canon ⊆ live check:
#
#   1. a list missing canonical patterns is reported, naming them;
#   2. a list holding every canonical pattern is not reported;
#   3. an EMPTY list is reported once (as EMPTY), not twice.
#
# No network: `gh` is a stub on PATH that answers from fixtures.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/scripts/check-settings-drift.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

cat > "$tmp/repo.json" <<'EOF'
{"repo":{"security_and_analysis":{}},
 "actions_permissions":{"allowed_actions":"selected","sha_pinning_required":true},
 "actions_workflow_permissions":{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}}
EOF
cat > "$tmp/allow.json" <<'EOF'
{"github_owned_allowed":true,"verified_allowed":true,
 "patterns_allowed":["editorconfig-checker/action-editorconfig-checker@*","haskell-actions/setup@*","oven-sh/setup-bun@*"]}
EOF

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fixture gh: repos `narrowed`, `complete`, `empty` under owner `o`.
case "$1 $2" in
  "repo list") printf 'narrowed\ncomplete\nempty\n'; exit 0 ;;
esac
path="$2"
case "$path" in
  repos/o/*/actions/permissions/selected-actions)
    r=${path#repos/o/}; r=${r%%/*}
    case "$r" in
      narrowed) echo '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["oven-sh/setup-bun@*","some/other@*"]}' ;;
      complete) echo '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["editorconfig-checker/action-editorconfig-checker@*","haskell-actions/setup@*","oven-sh/setup-bun@*","extra/repo-specific@*"]}' ;;
      empty)    echo '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":[]}' ;;
    esac ;;
  repos/o/*/actions/permissions/workflow)
    echo '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' ;;
  repos/o/*/actions/permissions)
    echo '{"allowed_actions":"selected","sha_pinning_required":true}' ;;
  repos/o/*/contents/*) exit 1 ;;
  repos/o/*) echo '{"private":false,"security_and_analysis":{}}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

set +e
out=$(PATH="$tmp/bin:$PATH" bash "$script" --owner o --canon "$tmp/repo.json" --actions-canon "$tmp/allow.json")
rc=$?
set -e

row() { printf '%s\n' "$out" | awk -F'\t' -v r="$1" -v k="$2" '$1==r && $2==k'; }

n=$(row narrowed actions.patterns_allowed)
if [ -n "$n" ] && printf '%s' "$n" | grep -q 'missing 2: editorconfig-checker/action-editorconfig-checker@\*, haskell-actions/setup@\*'; then
  pass "a narrowed list is reported, naming both missing canonical patterns"
else
  bad "a narrowed list was not reported with its missing patterns: '${n}'"
fi

if [ -z "$(row complete actions.patterns_allowed)" ]; then
  pass "a list holding every canonical pattern (plus a repo-specific one) is not reported"
else
  bad "a complete list was reported: '$(row complete actions.patterns_allowed)'"
fi

e=$(row empty actions.patterns_allowed)
if [ "$(printf '%s\n' "$e" | grep -c .)" = 1 ] && printf '%s' "$e" | grep -q EMPTY; then
  pass "an empty list is reported once, as EMPTY"
else
  bad "an empty list should give exactly one EMPTY row, got: '${e}'"
fi

if [ "$rc" = 1 ]; then pass "drift exits 1"; else bad "expected exit 1 on drift, got $rc"; fi

[ "$fail" = 0 ] && echo "test_settings_drift_canon_patterns: all passed" || { echo "test_settings_drift_canon_patterns: FAILED"; exit 1; }
