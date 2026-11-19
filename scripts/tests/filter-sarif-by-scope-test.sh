#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for scripts/filter-sarif-by-scope.sh.
#
# Weighted towards the failures that would be INVISIBLE: over-exclusion (a real
# finding dropped by a prefix that should not have matched) and a filter that
# exits 0 having silently written nothing. A filter that under-excludes is
# merely noisy and is covered by one positive case.
#
# Run: bash scripts/tests/filter-sarif-by-scope-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/filter-sarif-by-scope.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
# check NAME [--detail TEXT] -- COMMAND [ARGS...]
# Runs COMMAND directly (never a string to re-parse); it passes when COMMAND exits 0.
check() {
  local name="$1" detail=""; shift
  if [ "${1:-}" = "--detail" ]; then detail="$2"; shift 2; fi
  [ "${1:-}" = "--" ] && shift
  if "$@"; then ok "$name"; else bad "$name" "$detail"; fi
}
# eq WANT GOT: string equality.
eq() { [ "$1" = "$2" ]; }
# not COMMAND...: COMMAND exits non-zero.
not() { ! "$@"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mk_sarif() { # mk_sarif FILE  (uri tab ...)
  local out="$1"; shift
  local results="[]"
  for uri in "$@"; do
    [ "$uri" = "NONE" ] && uri=""
    results=$(printf '%s' "$results" | jq --arg u "$uri" '. + [{
      ruleId: "hypatia/content_patterns/http_in_docs",
      level: "warning",
      message: {text: "t"},
      locations: (if $u == "" then [] else [{physicalLocation: {artifactLocation: {uri: $u}}}] end)
    }]')
  done
  jq -n --argjson r "$results" '{version: "2.1.0", runs: [{tool: {driver: {name: "Hypatia"}}, results: $r}]}' > "$out"
}

uris_of() { jq -r '[.runs[].results[].locations[]?.physicalLocation.artifactLocation.uri] | join(",")' "$1"; }

# uris_has PATTERN FILE / uris_has_line PATTERN FILE: a listed URI matches (substring of the joined list / whole URI, one per line).
uris_has()      { grep -q -- "$1" <<<"$(uris_of "$2")"; }
uris_has_line() { grep -Fxq -- "$1" <<<"$(jq -r '.runs[].results[].locations[]?.physicalLocation.artifactLocation.uri' "$2")"; }
# result_count FILE / location_counts FILE: values the old checks compared.
result_count()    { jq '[.runs[].results[]] | length' "$1"; }
location_counts() { jq -r '[.runs[].results[] | (.locations|length)] | @csv' "$1" | tr -d '"'; }
# runs_is_one_array / driver_is_hypatia FILE: jq -e assertions on the output document.
runs_is_one_array() { jq -e '.runs | type == "array" and length == 1' "$1" >/dev/null; }
driver_is_hypatia() { jq -e '.runs[0].tool.driver.name == "Hypatia"' "$1" >/dev/null; }
# runs_cleanly COMMAND...: COMMAND with output discarded exits 0.
runs_cleanly()  { "$@" >/dev/null 2>&1; }
# exit_is WANT COMMAND...: COMMAND, output discarded, exits WANT.
exit_is() { local want="$1"; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }

echo "== a prefix removes exactly the results under it =="
mk_sarif "$TMP/a.sarif" "9-archive/x.adoc" "9-archive/deep/y.adoc" "scripts/a.sh" "docs/b.adoc"
bash "$SCRIPT" "$TMP/a.sarif" "$TMP/a.out" "9-archive/" >/dev/null 2>&1
check "only the two archive results remain out" --detail "$(uris_of "$TMP/a.out")" -- \
  eq 'scripts/a.sh,docs/b.adoc' "$(uris_of "$TMP/a.out")"

echo "== prefix matching is on a path boundary, not a substring =="
mk_sarif "$TMP/b.sarif" "9-archive-not-really/x.adoc" "scripts/9-archive/x.sh" "9-archive/x.adoc"
bash "$SCRIPT" "$TMP/b.sarif" "$TMP/b.out" "9-archive/" >/dev/null 2>&1
check "a sibling directory named 9-archive-not-really is KEPT" -- \
  uris_has '9-archive-not-really/x.adoc' "$TMP/b.out"
check "a file merely containing the word 9-archive is KEPT" -- \
  uris_has 'scripts/9-archive/x.sh' "$TMP/b.out"
check "the real archive path is removed" -- \
  not uris_has_line '9-archive/x.adoc' "$TMP/b.out"

echo "== leading ./ and / are normalised =="
mk_sarif "$TMP/c.sarif" "./9-archive/x.adoc" "/9-archive/y.adoc" "9-archive/z.adoc"
bash "$SCRIPT" "$TMP/c.sarif" "$TMP/c.out" "9-archive/" >/dev/null 2>&1
check "all three spellings are removed" --detail "$(uris_of "$TMP/c.out")" -- \
  eq '' "$(uris_of "$TMP/c.out")"

echo "== a location-less result is KEPT (cannot be shown out of scope) =="
mk_sarif "$TMP/d.sarif" "NONE" "9-archive/x.adoc"
bash "$SCRIPT" "$TMP/d.sarif" "$TMP/d.out" "9-archive/" >/dev/null 2>&1
check "the aggregate result survives" -- eq 1 "$(result_count "$TMP/d.out")"
check "...and it is the location-less one" -- eq 0 "$(location_counts "$TMP/d.out")"

echo "== multiple prefixes =="
mk_sarif "$TMP/e.sarif" "9-archive/a.adoc" "vendor/b.go" "src/c.rs"
bash "$SCRIPT" "$TMP/e.sarif" "$TMP/e.out" "9-archive/" "vendor/" >/dev/null 2>&1
check "both prefixes apply" --detail "$(uris_of "$TMP/e.out")" -- eq 'src/c.rs' "$(uris_of "$TMP/e.out")"

echo "== fail-open =="
printf 'not json at all' > "$TMP/bad.sarif"
bash "$SCRIPT" "$TMP/bad.sarif" "$TMP/bad.out" "9-archive/" >/dev/null 2>&1
check "unparseable input is copied through unchanged" -- cmp -s "$TMP/bad.sarif" "$TMP/bad.out"
check "...with exit 0 (an upload of unreadable input is a later failure, not this one)" -- \
  runs_cleanly bash "$SCRIPT" "$TMP/bad.sarif" "$TMP/bad2.out" '9-archive/'

echo "== the output is always a complete SARIF document =="
mk_sarif "$TMP/f.sarif" "9-archive/x.adoc"
bash "$SCRIPT" "$TMP/f.sarif" "$TMP/f.out" "9-archive/" >/dev/null 2>&1
check "runs array survives even when every result is dropped" -- runs_is_one_array "$TMP/f.out"
check "the tool driver is preserved" -- driver_is_hypatia "$TMP/f.out"

echo "== usage =="
check "no prefixes exits 2" -- exit_is 2 bash "$SCRIPT" "$TMP/a.sarif" "$TMP/z.out"
check "missing arguments exits 2" -- exit_is 2 bash "$SCRIPT"

echo "== an empty input is not an error =="
: > "$TMP/empty.sarif"
check "empty SARIF exits 0" -- runs_cleanly bash "$SCRIPT" "$TMP/empty.sarif" "$TMP/empty.out" '9-archive/'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
