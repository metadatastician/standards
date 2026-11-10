#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for scripts/inherited-language.sh.
#
# Weighted towards the failures that would be INVISIBLE: a list that excuses
# more than one rule on one exact path, a list that brings back a language the
# scanner bans without exception, and a filter that exits 0 having silently
# written nothing.
#
# Run: bash scripts/tests/inherited-language-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/inherited-language.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# ── paths: fail closed ──────────────────────────────────────────────────────
printf '# files received from upstream\n./frontend/a.ts\nfrontend/b.tsx\n\nfrontend/a.ts\r\n' > raw.txt
bash "$SCRIPT" paths raw.txt > list.txt 2>/dev/null
check "paths: comments, blanks, ./ and CR are normalised, duplicates removed" \
  '[ "$(cat list.txt)" = "$(printf "frontend/a.ts\nfrontend/b.tsx")" ]'

for entry in 'tool.py' 'cmd/main.go' 'Makefile' 'Gemfile' '/abs/a.ts' '../a.ts' 'a/./b.ts' 'a\b.ts' 'frontend/' 'README.md'; do
  printf '%s\n' "$entry" > bad.txt
  bash "$SCRIPT" paths bad.txt > out.txt 2> err.txt; rc=$?
  check "paths: '$entry' is refused, with nothing on stdout" \
    '[ "$rc" = 2 ] && [ ! -s out.txt ] && grep -q "not an inherited-language path" err.txt'
done
printf 'frontend/a.ts\ntool.py\n' > mixed.txt
bash "$SCRIPT" paths mixed.txt > out.txt 2>/dev/null; rc=$?
check "paths: one bad entry refuses the whole list" '[ "$rc" = 2 ] && [ ! -s out.txt ]'
printf '# only a comment\n\n' > empty.txt
bash "$SCRIPT" paths empty.txt > out.txt 2> err.txt; rc=$?
check "paths: an empty list is refused" '[ "$rc" = 2 ] && grep -q "the list is empty" err.txt'
bash "$SCRIPT" paths not-there.txt > out.txt 2>/dev/null; rc=$?
check "paths: a missing list is refused" '[ "$rc" = 2 ] && [ ! -s out.txt ]'

# ── sarif ───────────────────────────────────────────────────────────────────
result() { # result RULE URI...
  local rule="$1"; shift
  printf '%s\n' "$@" | jq -R -s --arg rule "$rule" '
    {ruleId: $rule, level: "error", message: {text: "t"},
     locations: [split("\n")[] | select(length > 0) | {physicalLocation: {artifactLocation: {uri: .}}}]}'
}
{
  result hypatia/cicd_rules/banned_language_file frontend/a.ts            # listed: dropped
  result hypatia/cicd_rules/banned_language_file ./frontend/b.tsx         # listed after ./: dropped
  result hypatia/cicd_rules/banned_language_file frontend/fork-only.ts    # not listed: kept
  result hypatia/cicd_rules/banned_language_file frontend/a.ts.bak        # a prefix is not a match: kept
  result hypatia/security_errors/secret_detected frontend/a.ts            # another rule: kept
  result hypatia/cicd_rules/banned_language_file frontend/a.ts frontend/fork-only.ts  # mixed locations: kept
  result hypatia/cicd_rules/banned_language_file                          # no location: kept
} | jq -s '{version: "2.1.0", runs: [{tool: {driver: {name: "Hypatia"}}, results: .}]}' > in.sarif
bash "$SCRIPT" sarif in.sarif out.sarif list.txt >/dev/null
check "sarif: only the rule on exact listed paths is dropped (7 -> 5)" \
  '[ "$(jq "[.runs[].results[]] | length" out.sarif)" = 5 ]'
check "sarif: the fork-only file still gates" \
  'jq -e "[.runs[].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == \"frontend/fork-only.ts\")] | length == 1" out.sarif >/dev/null'
check "sarif: a path that only starts with a listed path still gates" \
  'jq -e "[.runs[].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == \"frontend/a.ts.bak\")] | length == 1" out.sarif >/dev/null'
check "sarif: another rule on a listed path still gates" \
  'jq -e "[.runs[].results[] | select(.ruleId == \"hypatia/security_errors/secret_detected\")] | length == 1" out.sarif >/dev/null'
check "sarif: a result with one unlisted location still gates" \
  'jq -e "[.runs[].results[] | select((.locations | length) == 2)] | length == 1" out.sarif >/dev/null'
check "sarif: a result with no location still gates" \
  'jq -e "[.runs[].results[] | select((.locations | length) == 0)] | length == 1" out.sarif >/dev/null'
check "sarif: the input is not modified" '[ "$(jq "[.runs[].results[]] | length" in.sarif)" = 7 ]'
cp in.sarif inplace.sarif
bash "$SCRIPT" sarif inplace.sarif inplace.sarif list.txt >/dev/null
check "sarif: filtering in place works" '[ "$(jq "[.runs[].results[]] | length" inplace.sarif)" = 5 ]'

printf 'not json\n' > broken.sarif
bash "$SCRIPT" sarif broken.sarif broken-out.sarif list.txt > msg.txt; rc=$?
check "sarif: unreadable input is copied through unchanged, exit 0" \
  '[ "$rc" = 0 ] && cmp -s broken.sarif broken-out.sarif && grep -q "copied UNFILTERED" msg.txt'
bash "$SCRIPT" sarif in.sarif out2.sarif no-list.txt >/dev/null 2>&1; rc=$?
check "sarif: a missing normalised list is a usage error, and writes nothing" '[ "$rc" = 2 ] && [ ! -e out2.sarif ]'

# ── findings ────────────────────────────────────────────────────────────────
cat > in.json <<'JSON'
[
 {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/a.ts"},
 {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"./frontend/b.tsx"},
 {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/fork-only.ts"},
 {"severity":"high","rule_module":"security_errors","type":"secret_detected","file":"frontend/a.ts"},
 {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file"}
]
JSON
bash "$SCRIPT" findings in.json out.json list.txt >/dev/null
check "findings: only the rule on exact listed paths is dropped (5 -> 3)" '[ "$(jq length out.json)" = 3 ]'
check "findings: another rule on a listed path still gates" \
  'jq -e "[.[] | select(.type == \"secret_detected\")] | length == 1" out.json >/dev/null'
check "findings: a finding with no path still gates" \
  'jq -e "[.[] | select(has(\"file\") | not)] | length == 1" out.json >/dev/null'
printf '{"not":"an array"}\n' > odd.json
bash "$SCRIPT" findings odd.json odd-out.json list.txt > msg.txt; rc=$?
check "findings: an unexpected shape is copied through unchanged, exit 0" \
  '[ "$rc" = 0 ] && cmp -s odd.json odd-out.json && grep -q "copied UNFILTERED" msg.txt'

bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check "no command is a usage error" '[ "$rc" = 2 ]'

printf 'inherited-language-test: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
