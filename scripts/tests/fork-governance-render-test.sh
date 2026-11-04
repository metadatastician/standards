#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for scripts/fork-governance-render.sh.
#
# Weighted towards the cases that produce a CONFIDENT WRONG ANSWER, because
# those are the ones a green-looking PR comment hides:
#
#   * a missing lane silently dropped, so the summary looks complete
#   * a failed job whose stale grid said green reported as green
#   * an unrecognised state word treated as a pass
#   * the lanes emitted in a different order on different runs
#
# Run: bash scripts/tests/fork-governance-render-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RENDER="$ROOT/scripts/fork-governance-render.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

grid_k9="$TMP/k9.md"
grid_hyp="$TMP/hyp.md"
printf '<!-- verdict-grid:k9 regenerated on every run -->\n\nK9-GRID-BODY\n' > "$grid_k9"
printf '<!-- verdict-grid:hypatia regenerated on every run -->\n\nHYP-GRID-BODY\n' > "$grid_hyp"

render() { # render <outdir> [extra args...]
  local d="$1"; shift
  bash "$RENDER" --out "$d" --sha abcdef123456 --run 4242 \
    --url https://github.com/o/r/actions/runs/4242 --repo o/r "$@" >/dev/null 2>&1
}

echo "== order: summary, then k9-deed, then hypatia =="
d="$TMP/a"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict purple --hypatia-report "$grid_hyp"
sum_at=$(grep -n '^| Lane | Status | Run |$' "$d/body.md" | cut -d: -f1)
k9_at=$(grep -n '^## K9-DEED conformance$' "$d/body.md" | cut -d: -f1)
hyp_at=$(grep -n '^## Hypatia verdict grid$' "$d/body.md" | cut -d: -f1)
check "summary precedes k9-deed section" "[ -n '$sum_at' ] && [ -n '$k9_at' ] && [ '$sum_at' -lt '$k9_at' ]" "sum=$sum_at k9=$k9_at"
check "k9-deed precedes hypatia" "[ '$k9_at' -lt '$hyp_at' ]" "k9=$k9_at hyp=$hyp_at"

echo "== the lane is named K9-DEED conformance, not K9 =="
check "summary row says K9-DEED conformance" \
  "grep -q '| K9-DEED conformance (L0–L2; L3 not verified) |' '$d/body.md'"
check "no bare '| K9 conformance' row survives" \
  "! grep -q '| K9 conformance' '$d/body.md'"

echo "== markers =="
check "the comment carries the fork-governance marker" \
  "head -1 '$d/body.md' | grep -q '<!-- fork-governance-verdict: regenerated on every run -->'"
check "the k9 lane marker survives inside the combined body" \
  "grep -q '<!-- verdict-grid:k9 regenerated on every run -->' '$d/body.md'"
check "the hypatia lane marker survives inside the combined body" \
  "grep -q '<!-- verdict-grid:hypatia regenerated on every run -->' '$d/body.md'"
check "k9 report body is embedded verbatim" "grep -q 'K9-GRID-BODY' '$d/body.md'"
check "hypatia report body is embedded verbatim" "grep -q 'HYP-GRID-BODY' '$d/body.md'"

echo "== a missing lane is orange and stays in the table =="
d="$TMP/b"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --hypatia-result skipped
check "skipped hypatia still has a table row" \
  "grep -Fq '| Hypatia verdict grid | 🟠 indeterminate (job: skipped)' '$d/body.md'"
check "the missing hypatia grid is called out, not omitted" \
  "grep -q 'no verdict-grid artifact was produced' '$d/body.md'"
check "overall badge is orange when any lane is indeterminate" \
  "grep -q '\"message\": \"indeterminate\"' '$d/badge.json'"

echo "== a failed job outranks its own stale green grid =="
d="$TMP/c"; render "$d" --deed-result success --k9-result failure --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "k9 row is failing, not green" \
  "grep -Fq '| K9-DEED conformance (L0–L2; L3 not verified) | 🔴 failing (job: failure; grid: 🟢 conformant) |' '$d/body.md'"
check "overall badge is red" "grep -q '\"message\": \"failing\"' '$d/badge.json'"

echo "== Hypatia job failure and findings-grid state remain distinct =="
d="$TMP/c2"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result failure --hypatia-verdict yellow \
  --hypatia-report "$grid_hyp" --hypatia-advisory "green:0:0"
check "failed Hypatia job stays red while its grid remains yellow" \
  "grep -Fq '| Hypatia verdict grid | 🔴 failing (job: failure; grid: 🟡 medium findings) · advisory in grid scope: 🟢 green (0 critical, 0 high, not grading) |' '$d/body.md'"
check "scope note explains a gate can fail outside the delta grid" \
  "grep -q 'blocking gate may inspect findings outside the delta grid' '$d/body.md'"
check "the rendered grid is still embedded" "grep -q 'HYP-GRID-BODY' '$d/body.md'"
check "overall badge remains red for the failed job" "grep -q '\"message\": \"failing\"' '$d/badge.json'"

echo "== an unknown state word is indeterminate, never green =="
d="$TMP/d"; render "$d" --deed-result success --k9-result success --k9-verdict 'looks-fine' \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "unrecognised verdict renders orange" \
  "grep -Fq '| K9-DEED conformance (L0–L2; L3 not verified) | 🟠 indeterminate (job: success) |' '$d/body.md'"
d="$TMP/d2"; render "$d" --deed-result success --k9-result success --k9-verdict purple \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "findings-only purple is invalid for K9 conformance" \
  "grep -Fq '| K9-DEED conformance (L0–L2; L3 not verified) | 🟠 indeterminate (job: success) |' '$d/body.md'"

echo "== findings labels do not borrow conformance vocabulary =="
d="$TMP/d3"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict yellow --hypatia-report "$grid_hyp"
check "medium findings are not labelled as conformance debt" \
  "grep -Fq '| Hypatia verdict grid | 🟡 medium findings (job: success) |' '$d/body.md'"
check "overall yellow badge is neutral across grading families" \
  "grep -q '\"message\": \"attention\"' '$d/badge.json'"
d="$TMP/d4"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict blue --hypatia-report "$grid_hyp"
check "blue means minor findings" \
  "grep -Fq '| Hypatia verdict grid | 🔵 minor findings (job: success) |' '$d/body.md'"
check "overall blue badge says minor findings" \
  "grep -q '\"message\": \"minor findings\"' '$d/badge.json'"

echo "== cross-family colour precedence =="
d="$TMP/blue-vs-yellow"; render "$d" --deed-result success --k9-result success --k9-verdict yellow \
  --hypatia-result success --hypatia-verdict blue
check "yellow conformance debt outranks blue minor findings" "grep -q '\"color\": \"yellow\"' '$d/badge.json'"
d="$TMP/blue-vs-orange"; render "$d" --deed-result success --k9-result success --k9-verdict orange \
  --hypatia-result success --hypatia-verdict blue
check "orange missing evidence outranks blue minor findings" "grep -q '\"color\": \"orange\"' '$d/badge.json'"
d="$TMP/red-vs-purple"; render "$d" --deed-result failure --k9-result success --k9-verdict green \
  --hypatia-result success --hypatia-verdict purple
check "purple critical is not masked by red" "grep -q '\"color\": \"blueviolet\"' '$d/badge.json'"

echo "== DEED lane =="
d="$TMP/e"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "DEED success is conformant" "grep -q '| DEED syntax (repo deed) | 🟢 conformant |' '$d/body.md'"
check "all-green overall badge" "grep -q '\"message\": \"conformant\"' '$d/badge.json'"
d="$TMP/f"; render "$d" --deed-result failure --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "DEED failure is failing" "grep -q '| DEED syntax (repo deed) | 🔴 failing |' '$d/body.md'"
d="$TMP/g"; render "$d" --deed-result '' --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp"
check "DEED with no result is indeterminate" "grep -q '| DEED syntax (repo deed) | 🟠 indeterminate |' '$d/body.md'"

echo "== findings-family purple is carried through, not flattened =="
d="$TMP/h"; render "$d" --deed-result success --k9-result success --k9-verdict green \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict purple --hypatia-report "$grid_hyp"
check "purple hypatia row uses findings-family wording" \
  "grep -Fq '| Hypatia verdict grid | 🟣 critical findings (job: success) |' '$d/body.md'"
check "purple overall badge colour" "grep -q '\"color\": \"blueviolet\"' '$d/badge.json'"

echo "== determinism =="
d1="$TMP/i"; d2="$TMP/j"
render "$d1" --deed-result success --k9-result success --k9-verdict yellow \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict orange --hypatia-report "$grid_hyp"
render "$d2" --deed-result success --k9-result success --k9-verdict yellow \
  --k9-report "$grid_k9" --hypatia-result success --hypatia-verdict orange --hypatia-report "$grid_hyp"
check "same inputs produce a byte-identical body" "cmp -s '$d1/body.md' '$d2/body.md'"

echo "== advisory is shown beside the verdict, never inside it =="
d="$TMP/k"
render "$d" --deed-result success --k9-result success --k9-verdict green --k9-report "$grid_k9" \
  --hypatia-result success --hypatia-verdict green --hypatia-report "$grid_hyp" \
  --hypatia-advisory "purple:4:1"
check "a clean grid stays green and labels advisory counts as grid-scoped" \
  "grep -Fq '| Hypatia verdict grid | 🟢 no graded findings (job: success) · advisory in grid scope: 🟣 purple (4 critical, 1 high, not grading) |' '$d/body.md'"
check "the overall badge is green, not purple" "grep -q '\"message\": \"conformant\"' '$d/badge.json'"
check "the advisory counts are not folded into the row state" \
  "! grep -q '| Hypatia verdict grid | 🟣' '$d/body.md'"

check "advisory=none adds nothing" \
  "bash '$RENDER' --out '$TMP/l' --deed-result success --k9-result success --k9-verdict green --hypatia-result success --hypatia-verdict green --hypatia-advisory none >/dev/null 2>&1; ! grep -q 'advisory:' '$TMP/l/body.md'"
check "an empty advisory adds nothing" \
  "bash '$RENDER' --out '$TMP/m' --deed-result success --k9-result success --k9-verdict green --hypatia-result success --hypatia-verdict green >/dev/null 2>&1; ! grep -q 'advisory:' '$TMP/m/body.md'"
check "an unparseable advisory is shown, not dropped" \
  "bash '$RENDER' --out '$TMP/n' --deed-result success --k9-result success --k9-verdict green --hypatia-result success --hypatia-verdict green --hypatia-advisory 'wat' >/dev/null 2>&1; grep -q 'advisory: wat (unparsed)' '$TMP/n/body.md'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
