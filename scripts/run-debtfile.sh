#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# run-debtfile.sh — EXECUTE the probes declared in a Debtfile.a2ml.
#
# This is the executable half of Debtfile checking;
# scripts/check-debtfile-structure.sh is the structural half.
#
# Each '### <id>' block declares a `- probe:` — a shell command that prints a
# single non-negative integer: how much of that debt exists right now. The
# runner re-measures every entry and compares against the declared `ceiling`.
#
#   measured >  ceiling   ❌ debt grew past what this repo tolerates
#   measured <  ceiling   ✅ paid down (with --write, the ceiling follows it down)
#   measured == 0         🎉 resolved
#   accepted-until passed  ⏰ expired — the acceptance was time-boxed and the time is up
#
# ⚠ NO FALLBACK. A probe that fails to run, or prints anything other than an
#   integer, is a HARD FAILURE. This is the single most important property of
#   the whole mechanism. A probe that returns 0 on error is indistinguishable
#   from zero debt, and zero is the state that passes — so a broken probe would
#   silently report a clean repo. Every estate gate that has ever lied did it
#   this way. See scripts/count-ledger-entries.sh for the same rule stated for
#   the exemption ledgers.
#   Enforces docs/DEBTFILE-SPEC.adoc, "No fallback".
#
# ⚠ A PROBE MUST RESPECT EXISTING CARVE-OUTS. Naive probes manufacture debt.
#   During this file's own authoring, three candidate probes were rejected for
#   counting comments and documentation examples as violations:
#     * `uses:` without a 40-char SHA        → matched usage examples in comments
#     * scripts containing `python3`         → matched a comment saying "not python3"
#     * scripts with no matching test file   → counted the test files themselves
#   Validate a new probe against a hand-checked number before committing it.
#
# Usage: run-debtfile.sh [--write] [path/to/Debtfile.a2ml]
#   --write   update `count` in place, and lower `ceiling` to match when debt
#             has been paid down (the auto-ratchet). Never raises a ceiling.
#   Default path: .machine_readable/Debtfile.a2ml
#
# Exit: 0 all entries at or under ceiling · 1 a ceiling was breached, a probe
#       failed, or an acceptance expired · 2 file missing / bad invocation

set -uo pipefail

WRITE=0
DEBT=""
for arg in "$@"; do
  case "$arg" in
    --write) WRITE=1 ;;
    -*) echo "usage: run-debtfile.sh [--write] [path/to/Debtfile.a2ml]" >&2; exit 2 ;;
    *) if [ -n "$DEBT" ]; then echo "error: more than one Debtfile given" >&2; exit 2; fi; DEBT="$arg" ;;
  esac
done
DEBT="${DEBT:-.machine_readable/Debtfile.a2ml}"

if [ ! -f "$DEBT" ]; then
  echo "error: Debtfile not found: $DEBT" >&2
  exit 2
fi

TODAY="$(date -u +%Y-%m-%d)"

fail=0 ok=0 paid=0 resolved=0 breached=0 expired=0 broke=0
name="" probe="" count="" ceiling="" severity="" policy="" accepted=""
declare -a NEW_COUNT_IDS=() NEW_COUNT_VALS=() NEW_CEIL_IDS=() NEW_CEIL_VALS=()

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

measure() {
  [ -n "$name" ] || return 0

  if [ -z "$probe" ]; then
    printf '  ❓ NOPROBE  [%-8s] %s\n' "${severity:-?}" "$name"
    broke=$((broke + 1)); fail=1; return 0
  fi

  local out rc
  out="$(bash -c "$probe" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | tr -d ' \t\n\r')"

  if [ "$rc" -ne 0 ] || ! is_uint "$out"; then
    printf '  💥 PROBEFAIL [%-7s] %s  (exit %s, output %s)\n' "${severity:-?}" "$name" "$rc" "${out:-<empty>}"
    printf '               a probe that cannot measure must never report zero\n'
    broke=$((broke + 1)); fail=1; return 0
  fi

  # Time-boxed acceptance.
  local is_expired=0
  if [ -n "$accepted" ] && [ "$accepted" \< "$TODAY" ]; then is_expired=1; fi

  if [ "$out" -gt "$ceiling" ]; then
    printf '  ❌ BREACH   [%-8s] %-34s %s > ceiling %s\n' "$severity" "$name" "$out" "$ceiling"
    breached=$((breached + 1)); fail=1
  elif [ "$out" -eq 0 ]; then
    printf '  🎉 RESOLVED [%-8s] %-34s 0 (was %s)\n' "$severity" "$name" "$ceiling"
    resolved=$((resolved + 1))
  elif [ "$out" -lt "$ceiling" ]; then
    printf '  ✅ PAID     [%-8s] %-34s %s (ceiling %s -> %s)\n' "$severity" "$name" "$out" "$ceiling" "$out"
    paid=$((paid + 1))
    NEW_CEIL_IDS+=("$name"); NEW_CEIL_VALS+=("$out")
  else
    printf '  ·  HOLDING  [%-8s] %-34s %s\n' "$severity" "$name" "$out"
    ok=$((ok + 1))
  fi

  if [ "$is_expired" -eq 1 ]; then
    printf '  ⏰ EXPIRED  [%-8s] %-34s accepted-until %s has passed\n' "$severity" "$name" "$accepted"
    printf '               re-accept with a new date and a reason, or pay it down\n'
    expired=$((expired + 1)); fail=1
  fi

  if [ "$out" != "$count" ]; then
    NEW_COUNT_IDS+=("$name"); NEW_COUNT_VALS+=("$out")
  fi
}

reset_block() { name="$1"; probe=""; count=""; ceiling=""; severity=""; policy=""; accepted=""; }

echo "Debtfile: $DEBT"
echo
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw#"${raw%%[![:space:]]*}"}"
  case "$line" in
    '### '*)              measure; reset_block "${line:4}" ;;
    '- probe: '*)         probe="${line#- probe: }" ;;
    '- count: '*)         count="${line#- count: }" ;;
    '- ceiling: '*)       ceiling="${line#- ceiling: }" ;;
    '- severity: '*)      severity="${line#- severity: }" ;;
    '- policy: '*)        policy="${line#- policy: }" ;;
    '- accepted-until: '*) accepted="${line#- accepted-until: }" ;;
  esac
done < "$DEBT"
measure  # flush last block

# ---------------------------------------------------------------------------
# --write: update `count` everywhere it moved, and lower `ceiling` where debt
# was paid down. A ceiling is NEVER raised here — raising one is a deliberate
# act that must go through the ratchet's commit-message declaration.
# ---------------------------------------------------------------------------
if [ "$WRITE" -eq 1 ] && { [ "${#NEW_COUNT_IDS[@]}" -gt 0 ] || [ "${#NEW_CEIL_IDS[@]}" -gt 0 ]; }; then
  tmp="$(mktemp)"
  cur=""
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    case "$line" in
      '### '*) cur="${line:4}" ;;
      '- count: '*)
        for i in "${!NEW_COUNT_IDS[@]}"; do
          if [ "${NEW_COUNT_IDS[$i]}" = "$cur" ]; then raw="- count: ${NEW_COUNT_VALS[$i]}"; break; fi
        done ;;
      '- ceiling: '*)
        for i in "${!NEW_CEIL_IDS[@]}"; do
          if [ "${NEW_CEIL_IDS[$i]}" = "$cur" ]; then raw="- ceiling: ${NEW_CEIL_VALS[$i]}"; break; fi
        done ;;
    esac
    printf '%s\n' "$raw"
  done < "$DEBT" > "$tmp"
  mv "$tmp" "$DEBT"
  echo
  echo "  ✍  wrote ${#NEW_COUNT_IDS[@]} count update(s), ${#NEW_CEIL_IDS[@]} ceiling reduction(s)"
fi

echo
echo "Debtfile: $ok holding · $paid paid-down · $resolved resolved · $breached breached · $expired expired · $broke broken-probe"
if [ "$fail" -ne 0 ]; then
  echo "❌ Debtfile run FAILED" >&2
  exit 1
fi
echo "✅ Debtfile run passed (no ceiling breached, no probe broken, no acceptance expired)"
