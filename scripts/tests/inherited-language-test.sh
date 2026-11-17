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
# check NAME -- COMMAND [ARGS...]
# Runs COMMAND directly (never a string to re-parse); it passes when COMMAND exits 0.
check() {
  local name="$1"; shift
  [ "${1:-}" = "--" ] && shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
# eq WANT GOT: string equality.
eq() { [ "$1" = "$2" ]; }
# jq_eq WANT JQ_ARGS...: the jq output equals WANT.
jq_eq() { local want="$1"; shift; [ "$(jq "$@")" = "$want" ]; }
# jq_true FILTER FILE: the filter is true for FILE.
jq_true() { jq -e "$1" "$2" >/dev/null; }
# refused RC OUT: exit 2 and nothing on stdout.
refused() { [ "$1" = 2 ] && [ ! -s "$2" ]; }
# refused_saying RC OUT ERR PATTERN: refused, and ERR names PATTERN.
refused_saying() { refused "$1" "$2" && grep -q -- "$4" "$3"; }
# exit2_saying RC ERR PATTERN: exit 2 and ERR names PATTERN.
exit2_saying() { [ "$1" = 2 ] && grep -q -- "$3" "$2"; }
# refused_no_file RC FILE: exit 2 and FILE was not written.
refused_no_file() { [ "$1" = 2 ] && [ ! -e "$2" ]; }
# copied_unfiltered RC IN OUT MSG: exit 0, OUT is IN unchanged, MSG says so.
copied_unfiltered() { [ "$1" = 0 ] && cmp -s "$2" "$3" && grep -q "copied UNFILTERED" "$4"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# ── paths: fail closed ──────────────────────────────────────────────────────
printf '# files received from upstream\n./frontend/a.ts\nfrontend/b.tsx\n\nfrontend/a.ts\r\n' > raw.txt
bash "$SCRIPT" paths raw.txt > list.txt 2>/dev/null
check "paths: comments, blanks, ./ and CR are normalised, duplicates removed" -- \
  eq "$(cat list.txt)" "$(printf 'frontend/a.ts\nfrontend/b.tsx')"

for entry in 'tool.py' 'cmd/main.go' 'Makefile' 'Gemfile' '/abs/a.ts' '../a.ts' 'a/./b.ts' 'a\b.ts' 'frontend/' 'README.md'; do
  printf '%s\n' "$entry" > bad.txt
  bash "$SCRIPT" paths bad.txt > out.txt 2> err.txt; rc=$?
  check "paths: '$entry' is refused, with nothing on stdout" -- \
    refused_saying "$rc" out.txt err.txt "not an inherited-language path"
done
printf 'frontend/a.ts\ntool.py\n' > mixed.txt
bash "$SCRIPT" paths mixed.txt > out.txt 2>/dev/null; rc=$?
check "paths: one bad entry refuses the whole list" -- refused "$rc" out.txt
printf '# only a comment\n\n' > empty.txt
bash "$SCRIPT" paths empty.txt > out.txt 2> err.txt; rc=$?
check "paths: an empty list is refused" -- \
  exit2_saying "$rc" err.txt "the list is empty"
bash "$SCRIPT" paths not-there.txt > out.txt 2>/dev/null; rc=$?
check "paths: a missing list is refused" -- refused "$rc" out.txt

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
check "sarif: only the rule on exact listed paths is dropped (7 -> 5)" -- \
  jq_eq 5 '[.runs[].results[]] | length' out.sarif
check "sarif: the fork-only file still gates" -- \
  jq_true '[.runs[].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == "frontend/fork-only.ts")] | length == 1' out.sarif
check "sarif: a path that only starts with a listed path still gates" -- \
  jq_true '[.runs[].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == "frontend/a.ts.bak")] | length == 1' out.sarif
check "sarif: another rule on a listed path still gates" -- \
  jq_true '[.runs[].results[] | select(.ruleId == "hypatia/security_errors/secret_detected")] | length == 1' out.sarif
check "sarif: a result with one unlisted location still gates" -- \
  jq_true '[.runs[].results[] | select((.locations | length) == 2)] | length == 1' out.sarif
check "sarif: a result with no location still gates" -- \
  jq_true '[.runs[].results[] | select((.locations | length) == 0)] | length == 1' out.sarif
check "sarif: the input is not modified" -- jq_eq 7 '[.runs[].results[]] | length' in.sarif
cp in.sarif inplace.sarif
bash "$SCRIPT" sarif inplace.sarif inplace.sarif list.txt >/dev/null
check "sarif: filtering in place works" -- jq_eq 5 '[.runs[].results[]] | length' inplace.sarif

printf 'not json\n' > broken.sarif
bash "$SCRIPT" sarif broken.sarif broken-out.sarif list.txt > msg.txt; rc=$?
check "sarif: unreadable input is copied through unchanged, exit 0" -- \
  copied_unfiltered "$rc" broken.sarif broken-out.sarif msg.txt
bash "$SCRIPT" sarif in.sarif out2.sarif no-list.txt >/dev/null 2>&1; rc=$?
check "sarif: a missing normalised list is a usage error, and writes nothing" -- \
  refused_no_file "$rc" out2.sarif

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
check "findings: only the rule on exact listed paths is dropped (5 -> 3)" -- jq_eq 3 length out.json
check "findings: another rule on a listed path still gates" -- \
  jq_true '[.[] | select(.type == "secret_detected")] | length == 1' out.json
check "findings: a finding with no path still gates" -- \
  jq_true '[.[] | select(has("file") | not)] | length == 1' out.json
printf '{"not":"an array"}\n' > odd.json
bash "$SCRIPT" findings odd.json odd-out.json list.txt > msg.txt; rc=$?
check "findings: an unexpected shape is copied through unchanged, exit 0" -- \
  copied_unfiltered "$rc" odd.json odd-out.json msg.txt

bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check "no command is a usage error" -- eq 2 "$rc"

printf 'inherited-language-test: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
