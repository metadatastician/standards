#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -uo pipefail
#
# Wave-6 regression: the canonical-names reintroduction guard must block a NEW
# deprecated token while leaving grandfathered existing occurrences alone.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check-canonical-names.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

# Exercise the guard in a private repository so unrelated changes in the caller's
# worktree cannot turn the clean-name case into a false failure.
mkdir -p "$TMP/repo/scripts"
cp "$CHK" "$TMP/repo/scripts/check-canonical-names.sh"
cd "$TMP/repo" || exit
git init -q
git config user.name "Standards regression test"
git config user.email "standards-regression@example.invalid"
git add scripts/check-canonical-names.sh
git commit -qm "baseline"
CHK="$TMP/repo/scripts/check-canonical-names.sh"

echo "== guard blocks a newly-added deprecated token =="
f="wave6_guard_probe.txt"
printf 'this file uses the 6a2 layout\n' > "$f"
git add "$f" 2>/dev/null
if bash "$CHK" HEAD >/dev/null 2>&1; then bad "new '6a2' token not blocked"; else ok "new '6a2' token blocked"; fi
# agent_instructions too
printf 'agent_instructions live here\n' > "$f"
git add "$f" 2>/dev/null
if bash "$CHK" HEAD >/dev/null 2>&1; then bad "new 'agent_instructions' not blocked"; else ok "new 'agent_instructions' blocked"; fi
git reset -q "$f" 2>/dev/null; rm -f "$f"

echo "== guard blocks a newly-added deprecated directory =="
legacy_dir=".machine_readable/6a2"
mkdir -p "$legacy_dir"
printf '[metadata]\nstatus = "probe"\n' > "$legacy_dir/STATE.a2ml"
git add "$legacy_dir/STATE.a2ml" 2>/dev/null
if bash "$CHK" HEAD >/dev/null 2>&1; then bad "new deprecated directory not blocked"; else ok "new deprecated directory blocked"; fi
git reset -q "$legacy_dir/STATE.a2ml" 2>/dev/null
rm -rf "$legacy_dir"

echo "== guard passes with no offending additions =="
printf 'a perfectly canonical descriptiles + bot_directives line\n' > "$f"
git add "$f" 2>/dev/null
bash "$CHK" HEAD >/dev/null 2>&1 && ok "canonical names pass" || bad "canonical names wrongly blocked"
git reset -q "$f" 2>/dev/null; rm -f "$f"

echo "== the frozen scorecard archive is excluded record by record =="
# The real move: a record is renamed into the archive AND one line of it is
# edited, so the diff carries a rename with a '+' line under the new path.
old=".machine_readable/scorecards/probe.scorecard.a2ml"
arc=".machine_readable/archive/scorecards-v1"
mkdir -p "$(dirname "$old")" "$arc"
printf '[scorecard]\nspec_id = "probe"\nversion = "0.1.0"\nassessor = "estate-audit"\nevidence = "x"\n' > "$old"
git add "$old" && git commit -qm "scorecard fixture"
git mv "$old" "$arc/probe.scorecard.a2ml"
sed -i 's#^evidence = "x"$#evidence = ".machine_readable/6a2/STATE.a2ml"#' "$arc/probe.scorecard.a2ml"
git add "$arc/probe.scorecard.a2ml"
if bash "$CHK" HEAD >/dev/null 2>&1; then ok "archived scorecard record (moved + edited) excluded"; else bad "archived scorecard record wrongly blocked"; fi
# Planted positives: the exclusion must not reach the archive's README or a
# sibling archive. Without these, an exclusion of the whole tree would pass.
printf 'see .machine_readable/6a2/STATE.a2ml\n' > "$arc/README.adoc"
git add "$arc/README.adoc"
if bash "$CHK" HEAD >/dev/null 2>&1; then bad "archive README escaped the guard"; else ok "archive README still guarded"; fi
git rm -q --cached "$arc/README.adoc"; rm -f "$arc/README.adoc"
sib=".machine_readable/archive/scorecards-v2"
mkdir -p "$sib"
printf 'evidence = ".machine_readable/6a2/STATE.a2ml"\n' > "$sib/probe.scorecard.a2ml"
git add "$sib/probe.scorecard.a2ml"
if bash "$CHK" HEAD >/dev/null 2>&1; then bad "sibling archive escaped the guard"; else ok "sibling archive still guarded"; fi
git rm -q --cached "$sib/probe.scorecard.a2ml"; rm -rf "$sib"

echo "== 9-archive/ is frozen history and excluded whole =="
# A record archived at its original path keeps the names of its day.
frozen="9-archive/a2ml/.machine_readable/6a2/STATE.a2ml"
mkdir -p "$(dirname "$frozen")"
printf '[metadata]\nstatus = "frozen"\nsee = ".machine_readable/6a2/STATE.a2ml"\n' > "$frozen"
git add "$frozen"
if bash "$CHK" HEAD >/dev/null 2>&1; then ok "record under 9-archive/ excluded"; else bad "record under 9-archive/ wrongly blocked"; fi
git rm -q --cached "$frozen"; rm -rf 9-archive
# Planted positives: the prefix is anchored. A sibling that merely starts
# with the name, and a nested .../9-archive/, are both still guarded.
for probe in "9-archives/STATE.a2ml" "docs/9-archive/STATE.a2ml"; do
  mkdir -p "$(dirname "$probe")"
  printf 'see .machine_readable/6a2/STATE.a2ml\n' > "$probe"
  git add "$probe"
  if bash "$CHK" HEAD >/dev/null 2>&1; then bad "$probe escaped the guard"; else ok "$probe still guarded"; fi
  git rm -q --cached "$probe"; rm -rf "${probe%%/*}"
done

echo "== the legacy A2ML ledger names real legacy paths and is excluded =="
grep -qF '.machine_readable/a2ml-legacy-allow.txt|' "$CHK" && ok "legacy A2ML ledger is excluded from the guard" || bad "legacy A2ML ledger not excluded"

echo "== the guard excludes 0-canon/CANONICAL-NAMES.adoc itself =="
grep -q '0-canon/CANONICAL-NAMES.adoc' "$CHK" && ok "mandate doc is excluded from the guard" || bad "mandate doc not excluded"

echo
echo "Wave-6 canonical-names regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
