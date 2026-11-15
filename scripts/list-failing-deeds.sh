#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# list-failing-deeds.sh — advisory: every tracked .deed that deed_lint
# rejects, one ::warning:: each, with an exact count. Always exits 0 once it
# has run: it reports, it never turns a repository red or edits a file.
#
# Usage: list-failing-deeds.sh ROOT DEED_LINT_JS
set -uo pipefail
ROOT="${1:-.}"; LINT="${2:-}"
[ -f "$LINT" ] || { echo "::warning::deed_lint not found at '$LINT'; listing skipped"; exit 0; }
command -v bun >/dev/null || { echo "::warning::bun not found; listing skipped"; exit 0; }

# Negative fixtures are meant to fail: any path that runs through a
# fixtures/ directory and then an invalid/ one (the deed_lint test layout).
is_negative_fixture() { [[ "/$1" =~ /fixtures/(.*/)?invalid/ ]]; }
total=0; failing=0
while IFS= read -r -d '' path; do
  is_negative_fixture "$path" && continue
  total=$((total + 1))
  if ! out="$(cd "$ROOT" && bun "$LINT" "./$path" 2>&1)"; then
    failing=$((failing + 1))
    reason="$(printf '%s\n' "$out" | grep -m1 '^FAIL' | sed "s|^FAIL \./${path}: ||")"
    echo "::warning file=${path}::not a deed: ${reason:-deed_lint failed}"
  fi
done < <(git -C "$ROOT" ls-files -z -- '*.deed')
echo "failing-deeds: ${failing} of ${total} tracked .deed file(s) fail deed_lint."
exit 0
