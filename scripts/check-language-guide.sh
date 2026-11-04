#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-language-guide.sh — structural lint for per-language testing guides.
#
# Every guide built from 4-readiness/toolchain-readiness-grades/testing/language-testing-guide-TEMPLATE.adoc
# MUST carry
# the required sections and the R1–R9 requirement-mapping table. A guide that
# silently omits a section (e.g. "Known gaps") is a false-completeness hole —
# this fails loudly instead.
#
# Usage: check-language-guide.sh [guide.adoc ...]
#   With no args, checks every guide in 4-readiness/toolchain-readiness-grades/testing/.
# Exit: 0 all valid · 1 a guide is missing a required section

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

REQUIRED_SECTIONS=(
  "Requirement mapping"
  "Tools"
  "Recommended CI pipeline"
  "Best practices"
  "Known gaps"
  "Resources"
)

check_one() { # file
  local f="$1" rc=0 sec
  if [ ! -f "$f" ]; then echo "  ❌ $f: not found"; return 1; fi
  for sec in "${REQUIRED_SECTIONS[@]}"; do
    grep -Eq "^(#{2,4}|={2,4})[[:space:]]+${sec}$" "$f" || { echo "  ❌ $(basename "$f"): missing section '$sec'"; rc=1; }
  done
  # The requirement mapping MUST reference the R1..R9 rows (at least R1 and R9).
  grep -Eq '\bR1\b' "$f" && grep -Eq '\bR9\b' "$f" || { echo "  ❌ $(basename "$f"): requirement mapping does not reference R1..R9"; rc=1; }
  # A SPDX header is required.
  head -3 "$f" | grep -q 'SPDX-License-Identifier' || { echo "  ❌ $(basename "$f"): missing SPDX header"; rc=1; }
  [ "$rc" -eq 0 ] && echo "  ✅ $(basename "$f")"
  return $rc
}

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(find "$ROOT/4-readiness/toolchain-readiness-grades/testing" -maxdepth 1 -type f -name '*-testing-guide.adoc' -print 2>/dev/null | LC_ALL=C sort)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no language testing guides found (4-readiness/toolchain-readiness-grades/testing/*-testing-guide.adoc)"; exit 0
fi

rc=0
echo "Language testing guides:"
for f in "${files[@]}"; do check_one "$f" || rc=1; done
exit $rc
