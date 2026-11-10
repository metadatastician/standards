#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# propagate-hypatia-caller-id-test.sh — fixture suite for
# scripts/propagate-hypatia-caller-id.sh.
#
# Builds synthetic consumer repositories in a temp directory and drives the
# audit / --fix / refused paths. No network, no gh, no token: the requirement
# probe is supplied through the HYPATIA_REQUIRED_JSON seam.
#
# Branches driven:
#   * caller already canonical                  -> canonical, --fix is a no-op
#   * caller `scan`, nothing requires the old name -> stage, --fix rewrites the
#     job key and NOTHING else in the file
#   * caller `scan`, a rule requires `scan / …`  -> BLOCKED, --fix refuses and the
#     file is byte-identical afterwards
#   * workflow with no reusable call             -> unchanged-shape
#   * repository without the wrapper             -> absent
#   * requirements unreadable (offline)          -> UNVERIFIED, --fix refuses
#
# Run: bash scripts/tests/propagate-hypatia-caller-id-test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../propagate-hypatia-caller-id.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/fleet"

wrapper() { # $1 dir, $2 caller id
  mkdir -p "$1/.github/workflows"
  cat > "$1/.github/workflows/hypatia-scan.yml" <<EOF
# fixture wrapper
name: Hypatia Scan
on:
  push:
  pull_request:

jobs:
  $2:
    name: Hypatia Neurosymbolic Analysis
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@84355587cb2a1f86e6882de83514a32db2646e7a
    secrets: inherit
EOF
}

wrapper "$work/fleet/aaa-canonical" hypatia
wrapper "$work/fleet/bbb-needs-rename" scan
wrapper "$work/fleet/ccc-blocked" scan
wrapper "$work/fleet/ddd-absent" scan && rm "$work/fleet/ddd-absent/.github/workflows/hypatia-scan.yml"

mkdir -p "$work/fleet/eee-inline/.github/workflows"
cat > "$work/fleet/eee-inline/.github/workflows/hypatia-scan.yml" <<'EOF'
name: Hypatia Scan
on: [push]
jobs:
  scan:
    name: Hypatia Neurosymbolic Analysis
    runs-on: ubuntu-latest
    steps:
      - run: echo inline
EOF

# Nothing requires the old prefixed name anywhere in the safe fixture.
printf '["hypatia / Hypatia Neurosymbolic Analysis","CodeRabbit"]' > "$work/safe.json"
# One rule requires it -> the rename must be refused for that repository.
printf '["scan / Hypatia Neurosymbolic Analysis"]' > "$work/blocking.json"

out="$(HYPATIA_REQUIRED_JSON="$work/safe.json" bash "$SCRIPT" "$work/fleet" 2>/dev/null)"
check "canonical-caller-is-reported-canonical" "canonical" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="aaa-canonical"{print $4}')"
check "differing-caller-is-stage"            "stage"     "$(printf '%s\n' "$out" | awk -F'\t' '$1=="bbb-needs-rename"{print $4}')"
check "no-wrapper-is-absent"                 "absent"    "$(printf '%s\n' "$out" | awk -F'\t' '$1=="ddd-absent"{print $4}')"
check "non-reusable-is-unchanged-shape"      "unchanged-shape" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="eee-inline"{print $4}')"

out="$(HYPATIA_REQUIRED_JSON="$work/blocking.json" bash "$SCRIPT" "$work/fleet" 2>/dev/null)"
check "required-old-name-blocks-the-rename"  "BLOCKED"   "$(printf '%s\n' "$out" | awk -F'\t' '$1=="ccc-blocked"{print $4}')"

# --fix must refuse the blocked repo and stage the safe one.
before_blocked="$(cat "$work/fleet/ccc-blocked/.github/workflows/hypatia-scan.yml")"
HYPATIA_REQUIRED_JSON="$work/blocking.json" bash "$SCRIPT" --fix "$work/fleet" >/dev/null 2>&1
after_blocked="$(cat "$work/fleet/ccc-blocked/.github/workflows/hypatia-scan.yml")"
check "fix-leaves-blocked-file-untouched" "$before_blocked" "$after_blocked"
check "fix-refuses-blocked-repo" "scan" "$(awk '/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/{k=$1; sub(/:$/,"",k)} /uses:.*hypatia-scan-reusable/{print k; exit}' "$work/fleet/ccc-blocked/.github/workflows/hypatia-scan.yml")"

before_safe="$(cat "$work/fleet/bbb-needs-rename/.github/workflows/hypatia-scan.yml")"
out="$(HYPATIA_REQUIRED_JSON="$work/safe.json" bash "$SCRIPT" --fix "$work/fleet" 2>/dev/null)"
check "fix-reports-staged" "staged" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="bbb-needs-rename"{print $4}')"
after_safe="$(cat "$work/fleet/bbb-needs-rename/.github/workflows/hypatia-scan.yml")"
check "fix-renames-the-caller-key" "hypatia" "$(awk '/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/{k=$1; sub(/:$/,"",k)} /uses:.*hypatia-scan-reusable/{print k; exit}' "$work/fleet/bbb-needs-rename/.github/workflows/hypatia-scan.yml")"
# Only the key line may differ: the pin, the secrets line and the comments stay.
check "fix-touches-only-the-job-key" "2" "$(diff <(printf '%s\n' "$before_safe") <(printf '%s\n' "$after_safe") | grep -c '^[<>]')"
check "fix-keeps-the-pin" "1" "$(printf '%s\n' "$after_safe" | grep -c '84355587cb2a1f86e6882de83514a32db2646e7a')"
check "fix-keeps-secrets-inherit" "1" "$(printf '%s\n' "$after_safe" | grep -c '^[[:space:]]*secrets: inherit$')"
check "fix-is-idempotent" "canonical" "$(HYPATIA_REQUIRED_JSON="$work/safe.json" bash "$SCRIPT" "$work/fleet" 2>/dev/null | awk -F'\t' '$1=="bbb-needs-rename"{print $4}')"

# --- shapes seen in the live estate, which the first detection missed -------

# ggg: a job-level `permissions:` block inside the caller job. The old
#      "last bare `key:` line" heuristic reported the caller as `permissions`
#      and rewrote the permissions key itself.
mkdir -p "$work/fleet/ggg-job-permissions/.github/workflows"
cat > "$work/fleet/ggg-job-permissions/.github/workflows/hypatia-scan.yml" <<'EOF'
name: Hypatia Security Scan
on:
  push:
  pull_request:

permissions:
  actions: read
  contents: read

jobs:
  scan:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@210f14e753c80064ec1bcae72f1d654dd9b0e687
    secrets: inherit
EOF

# hhh: the job key carries a trailing comment. The old heuristic skipped it (the
#      line is not a "bare" key) and picked up `jobs:` instead.
mkdir -p "$work/fleet/hhh-commented-key/.github/workflows"
cat > "$work/fleet/hhh-commented-key/.github/workflows/hypatia-scan.yml" <<'EOF'
name: Hypatia Security Scan
on: [push]

jobs:
  scan: # estate scan gate
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@210f14e753c80064ec1bcae72f1d654dd9b0e687
    secrets: inherit
EOF

# iii: no trailing newline on the last line. The rewrite must still be a
#      single-line replacement (a `\ No newline at end of file` marker is not
#      a changed line).
mkdir -p "$work/fleet/iii-no-newline/.github/workflows"
printf '%s' 'name: Hypatia Security Scan
on: [push]

jobs:
  scan:
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@8f2ee50841e216cd8c192eeb68953118190f105c' > "$work/fleet/iii-no-newline/.github/workflows/hypatia-scan.yml"

job_key() { # the job key governing the reusable call, detected structurally
  local n; n="$(awk '/^[[:space:]]*uses:.*hypatia-scan-reusable\.ya?ml@/ { print NR; exit }' "$1")"
  awk -v n="$n" 'NR<n && /^  [A-Za-z0-9_.-]+:[[:space:]]*(#.*)?$/ { k=$1; sub(/:$/,"",k) } END { print k }' "$1"
}
changed_lines() { diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep -c '^[<>]'; }

before_ggg="$(cat "$work/fleet/ggg-job-permissions/.github/workflows/hypatia-scan.yml")"
before_hhh="$(cat "$work/fleet/hhh-commented-key/.github/workflows/hypatia-scan.yml")"
before_iii="$(cat "$work/fleet/iii-no-newline/.github/workflows/hypatia-scan.yml")"

out="$(HYPATIA_REQUIRED_JSON="$work/safe.json" bash "$SCRIPT" --fix "$work/fleet" 2>/dev/null)"
check "job-level-permissions: the caller is the job key, not permissions" "scan" \
      "$(printf '%s\n' "$out" | awk -F'\t' '$1=="ggg-job-permissions"{print $3}')"
check "job-level-permissions: staged" "staged" \
      "$(printf '%s\n' "$out" | awk -F'\t' '$1=="ggg-job-permissions"{print $4}')"
check "job-level-permissions: job key renamed" "hypatia" \
      "$(job_key "$work/fleet/ggg-job-permissions/.github/workflows/hypatia-scan.yml")"
check "job-level-permissions: nested permissions block untouched" "1" \
      "$(grep -c '^    permissions:$' "$work/fleet/ggg-job-permissions/.github/workflows/hypatia-scan.yml")"
check "job-level-permissions: one-line replacement" "2" \
      "$(changed_lines "$before_ggg" "$(cat "$work/fleet/ggg-job-permissions/.github/workflows/hypatia-scan.yml")")"
check "commented-key: job key renamed" "hypatia" \
      "$(job_key "$work/fleet/hhh-commented-key/.github/workflows/hypatia-scan.yml")"
check "commented-key: trailing comment preserved" "1" \
      "$(grep -c '^  hypatia: # estate scan gate$' "$work/fleet/hhh-commented-key/.github/workflows/hypatia-scan.yml")"
check "commented-key: one-line replacement" "2" \
      "$(changed_lines "$before_hhh" "$(cat "$work/fleet/hhh-commented-key/.github/workflows/hypatia-scan.yml")")"
check "no-newline: job key renamed" "hypatia" \
      "$(job_key "$work/fleet/iii-no-newline/.github/workflows/hypatia-scan.yml")"
check "no-newline: one-line replacement" "2" \
      "$(changed_lines "$before_iii" "$(cat "$work/fleet/iii-no-newline/.github/workflows/hypatia-scan.yml")")"
check "fix-is-idempotent-for-the-new-shapes" "canonical" \
      "$(HYPATIA_REQUIRED_JSON="$work/safe.json" bash "$SCRIPT" "$work/fleet" 2>/dev/null | awk -F'\t' '$1=="ggg-job-permissions"{print $4}')"

# Unreadable requirements: never rename on an unknown requirement set.
wrapper "$work/fleet/fff-unverified" scan
out="$(bash "$SCRIPT" --no-network "$work/fleet" 2>/dev/null)"
check "unreadable-requirements-are-unverified" "UNVERIFIED" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="fff-unverified"{print $4}')"
before="$(cat "$work/fleet/fff-unverified/.github/workflows/hypatia-scan.yml")"
bash "$SCRIPT" --no-network --fix "$work/fleet" >/dev/null 2>&1
check "fix-refuses-when-requirements-unreadable" "$before" "$(cat "$work/fleet/fff-unverified/.github/workflows/hypatia-scan.yml")"

if [ "$fail" -gt 0 ]; then
  echo "::error file=$SCRIPT::$fail fixture(s) failed"
  exit 1
fi
echo "PASS $0"
