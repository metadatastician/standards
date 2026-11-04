#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# run-mustfile.sh — EXECUTE the checks declared in A2ML or DEED Mustfiles.
#
# The Mustfile declares hard repository invariants. Each '### <id>' block has a
# severity and a means of discharge:
#   * `- run: <command>`      — executable; run it, pass iff exit 0.
#   * `- verification: <text>`— governance / manually-verified; reported as
#                               MANUAL (counted, never silently green).
#
# Blocking policy (fail loudly): a failing check of severity `critical` or
# `high` fails the run (exit 1). A failing `warning`/lower check is advisory
# (reported, non-blocking). This is the executable half of Mustfile checking;
# scripts/check-mustfile-structure.sh is the structural half.
#
# Usage: run-mustfile.sh [path/to/Mustfile.a2ml]
#   Default: .machine_readable/contractiles/must/Mustfile.a2ml
# Exit: 0 all blocking checks pass · 1 a blocking check failed · 2 file missing

set -uo pipefail

MUST="${1:-.machine_readable/contractiles/must/Mustfile.a2ml}"
if [ ! -f "$MUST" ]; then
  echo "error: Mustfile not found: $MUST" >&2
  exit 2
fi


# Parse live DEED checks with the normative parser; a syntactically legal but
# unknown or empty check set must never be presented as a passing run.
if [ "${MUST##*.}" = "deed" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if ! command -v bun >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "error: bun and jq are required for DEED Mustfile execution" >&2
    exit 2
  fi
  if ! records="$(bun "$ROOT/1-formats/deed/tools/deed_lint.js" --mustfile-json "$MUST")"; then
    echo "❌ Mustfile parse or profile check failed: $MUST" >&2
    exit 1
  fi
  if ! jq -e 'type == "array" and length > 0' <<< "$records" >/dev/null; then
    echo "❌ Mustfile has no executable/inspectable check records" >&2
    exit 1
  fi
  pass=0 warn=0 manual=0 blocking_fail=0
  while IFS= read -r record; do
    name="$(jq -er '.id' <<< "$record")" || exit 1
    sev="$(jq -er '.severity' <<< "$record")" || exit 1
    kind="$(jq -er '.discharge' <<< "$record")" || exit 1
    body="$(jq -er '.body' <<< "$record")" || exit 1
    if [ "$kind" = "verification" ]; then
      printf '  MANUAL [%-8s] %s\n' "$sev" "$name"
      manual=$((manual + 1))
    elif bash -c "$body" >/dev/null 2>&1; then
      printf '  PASS   [%-8s] %s\n' "$sev" "$name"
      pass=$((pass + 1))
    else
      case "$sev" in
        critical|high)
          printf '  FAIL   [%-8s] %s\n' "$sev" "$name"
          blocking_fail=$((blocking_fail + 1)) ;;
        medium|low)
          printf '  WARN   [%-8s] %s\n' "$sev" "$name"
          warn=$((warn + 1)) ;;
        *) echo "error: invalid severity reached executor: $sev" >&2; exit 1 ;;
      esac
    fi
  done < <(jq -c '.[]' <<< "$records")
  printf '\nMustfile: %s passed · %s warning · %s manual · %s blocking-fail\n' "$pass" "$warn" "$manual" "$blocking_fail"
  if [ "$blocking_fail" -gt 0 ]; then
    echo "❌ Mustfile check FAILED ($blocking_fail blocking failure(s))" >&2
    exit 1
  fi
  echo "✅ Mustfile checks passed (all critical/high checks green; manual checks reported)"
  exit 0
fi

name="" sev="" cmd="" kind=""
pass=0 warn=0 manual=0 blocking_fail=0

discharge() {
  [ -n "$name" ] || return 0
  if [ "$kind" = "run" ]; then
    if bash -c "$cmd" >/dev/null 2>&1; then
      printf '  ✅ PASS   [%-8s] %s\n' "$sev" "$name"; pass=$((pass + 1))
    else
      case "$sev" in
        critical|high)
          printf '  ❌ FAIL   [%-8s] %s\n' "$sev" "$name"; blocking_fail=$((blocking_fail + 1)) ;;
        *)
          printf '  ⚠️  WARN   [%-8s] %s\n' "$sev" "$name"; warn=$((warn + 1)) ;;
      esac
    fi
  elif [ "$kind" = "verification" ]; then
    printf '  🔎 MANUAL [%-8s] %s\n' "$sev" "$name"; manual=$((manual + 1))
  else
    # A block with neither run nor verification is a structural defect; the
    # structural validator owns that, but flag it here too rather than ignore.
    printf '  ❓ NODISCHARGE [%-4s] %s\n' "$sev" "$name"; blocking_fail=$((blocking_fail + 1))
  fi
}

# Trim leading whitespace so indented list items are still recognised.
while IFS= read -r raw; do
  line="${raw#"${raw%%[![:space:]]*}"}"
  case "$line" in
    '### '*)            discharge; name="${line:4}"; sev=""; cmd=""; kind="" ;;
    '- run: '*)         cmd="${line#- run: }"; kind="run" ;;
    '- verification: '*) cmd="${line#- verification: }"; [ "$kind" = "run" ] || kind="verification" ;;
    '- severity: '*)    sev="${line#- severity: }" ;;
  esac
done < "$MUST"
discharge  # flush last block

echo ""
echo "Mustfile: $pass passed · $warn warning · $manual manual · $blocking_fail blocking-fail"
if [ "$blocking_fail" -gt 0 ]; then
  echo "❌ Mustfile check FAILED ($blocking_fail blocking failure(s))" >&2
  exit 1
fi
echo "✅ Mustfile check passed (all critical/high checks green)"
