#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for the body assembly in .github/workflows/fork-governance-publish-reusable.yml
# (SPEC §4.1). The fork's artifact is untrusted: its body must not be able to
# hide the publisher's notice, so the notice is line 2, before any fork text,
# and line 1 must be exactly the marker.
#
# The assembly is executed from the workflow file itself (the lines from the
# "Line 1 must be exactly the marker" comment to the write of published.md),
# so the test cannot drift from what runs.
#
# Run: bash scripts/tests/fork-governance-publish-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WF="$ROOT/.github/workflows/fork-governance-publish-reusable.yml"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the assembly snippet and strip the YAML block indentation.
awk '/# Line 1 must be exactly the marker/ {p=1}
     p {print}
     p && /\} > "\$dir\/published.md"/ {exit}' "$WF" | sed -E 's/^          //' > "$TMP/assemble.sh"
if ! grep -q 'published.md' "$TMP/assemble.sh" || ! grep -q 'marker=' "$TMP/assemble.sh"; then
  echo "FAIL: could not extract the assembly from $WF"; exit 1
fi

MARKER='<!-- fork-governance-verdict: regenerated on every run -->'
RUN_URL='https://github.com/o/r/actions/runs/42'
RUN_ID=42; RUN_ATTEMPT=1

# assemble BODY_FILE -> exit status of the snippet; output in $TMP/out/published.md
assemble() {
  rm -rf "$TMP/out"; mkdir -p "$TMP/out"
  # shellcheck disable=SC2034  # dir and body are read by the sourced snippet
  ( dir="$TMP/out"; body="$1"
    export RUN_URL RUN_ID RUN_ATTEMPT
    # shellcheck disable=SC1091
    set -e; . "$TMP/assemble.sh" ) > "$TMP/out/log" 2>&1
}

# 1. A well-formed body: marker, notice on line 2, fork text, stamp last.
printf '%s\n# Fork governance\n\nlanes\n' "$MARKER" > "$TMP/good.md"
if assemble "$TMP/good.md"; then
  out="$TMP/out/published.md"
  [[ "$(sed -n 1p "$out")" == "$MARKER" ]] && ok "line 1 is the marker" || bad "line 1 is the marker" "$(sed -n 1p "$out")"
  sed -n 2p "$out" | grep -qF "Rendered by the fork pull request run $RUN_URL" \
    && ok "line 2 is the publisher notice" || bad "line 2 is the publisher notice" "$(sed -n 2p "$out")"
  [[ "$(sed -n 3p "$out")" == "# Fork governance" ]] && ok "fork text follows the notice" || bad "fork text follows the notice"
  [[ "$(tail -n 1 "$out")" == "<!-- fork-governance-publish-run: 42.1 -->" ]] && ok "stamp is the last line" || bad "stamp is the last line" "$(tail -n 1 "$out")"
  [[ "$(grep -c 'fork-governance-verdict' "$out")" -eq 1 ]] && ok "the marker appears once" || bad "the marker appears once"
else
  bad "a well-formed body is published" "$(cat "$TMP/out/log")"
fi

# 2. A body that opens an HTML comment and never closes it cannot hide the
#    notice: everything the fork wrote comes after it.
printf '%s\n# Fork governance\n<!--\nlooks clean\n' "$MARKER" > "$TMP/hide.md"
if assemble "$TMP/hide.md"; then
  out="$TMP/out/published.md"
  notice=$(grep -n 'Rendered by the fork pull request run' "$out" | cut -d: -f1)
  opener=$(grep -n '^<!--$' "$out" | head -1 | cut -d: -f1)
  [[ -n "$notice" && -n "$opener" && "$notice" -lt "$opener" ]] \
    && ok "an unclosed comment in the body comes after the notice" || bad "an unclosed comment in the body comes after the notice" "notice=$notice opener=$opener"
else
  bad "a body with an unclosed comment is still assembled" "$(cat "$TMP/out/log")"
fi

# 3. Line 1 must be exactly the marker: a marker with an unclosed comment
#    appended (which would hide line 2) is refused, as is a missing marker.
printf '%s<!--\n# Fork governance\n' "$MARKER" > "$TMP/tail.md"
if assemble "$TMP/tail.md"; then bad "a marker with text appended is refused" "it was published"
else grep -q 'not exactly the fork-governance marker' "$TMP/out/log" && ok "a marker with text appended is refused" || bad "a marker with text appended is refused" "$(cat "$TMP/out/log")"; fi

printf '# Fork governance\n' > "$TMP/none.md"
if assemble "$TMP/none.md"; then bad "a body without the marker is refused" "it was published"
else ok "a body without the marker is refused"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
