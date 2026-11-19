#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-debt-ratchet.sh — a Debtfile's ceilings may fall, never rise silently.
#
# Sibling to scripts/check-exemption-ratchet.sh, which does the same job for
# the four exemption ledgers. The two govern different populations:
#
#   exemption ratchet — debt you have EXCUSED   (baseline, ignores, allowlists)
#                       "did you quietly excuse more?"
#   debt ratchet      — debt you have MEASURED  (Debtfile.a2ml)
#                       "did the number go up?"
#
# Three rules:
#
#   1. NO SILENT RAISE. A ceiling may fall freely. Raising one needs a
#      declaration in the commit message.
#
#   2. NO SILENT DELETION. An entry leaves the Debtfile by reaching zero, not
#      by being deleted. Deleting an entry is how measured debt becomes
#      invisible debt, and it is the exact analogue of the `**` wildcard the
#      exemption ratchet rejects in the migration ledger: the file appears to
#      hold steady while what it covers quietly changes. Deletion needs the
#      same declaration a raise does.
#
#   3. NO UNDECLARED NEW CEILING ABOVE ZERO for an entry that did not exist.
#      Adding an entry is honest and welcome — that is how debt gets recorded.
#      It is allowed without ceremony.  (Rule kept explicit so nobody "fixes"
#      the gate by making declaration mandatory here; that would punish the
#      one behaviour this file wants to encourage.)
#
# Escape hatch, per-entry, never blanket:
#
#     Debt-exception: <entry id> — <why>
#     Debt-exception(<entry id>): <why>
#
# ⚠ A declaration naming no known entry is REJECTED rather than treated as
#   blanket permission, because "unparseable" must never mean "allowed". This
#   is the bug the exemption ratchet shipped with and had to fix: a single bare
#   `Ratchet-exception:` licensed growth in all four ledgers at once.
#
# Usage: check-debt-ratchet.sh <base-ref> [path/to/Debtfile.a2ml]
# Exit: 0 ok · 1 violation · 2 bad invocation

set -uo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: check-debt-ratchet.sh <base-ref> [path/to/Debtfile.a2ml]" >&2
  exit 2
fi
BASE_REF="$1"
DEBT="${2:-.machine_readable/Debtfile.a2ml}"

fail=0
note() { printf '  %s\n' "$*"; }

# Emit "<id> <ceiling>" for every entry in the Debtfile at a given revision.
# A missing file yields nothing — that is a real state (the Debtfile has not
# been adopted yet), not an error.
ceilings_at() {
  local ref="$1" blob
  blob="$(git show "${ref}:${DEBT}" 2>/dev/null)" || return 0
  printf '%s\n' "$blob" | awk '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line ~ /^### /            { id = substr(line, 5); next }
    line ~ /^- ceiling: / && id != "" {
      v = substr(line, 12); gsub(/[ \t\r]/, "", v)
      print id, v; id = ""
    }
  '
}

# Does the pull request declare that a SPECIFIC entry may rise or vanish?
# Checks both commit messages (for non-squash merges) and PR body (for squash merges
# where commit messages are lost).
declared_for() {
  local entry="$1" msgs
  msgs="$(git log --format=%B "${BASE_REF}..HEAD" 2>/dev/null || true)"
  
  # Check commit messages. The declarations are captured, then matched: a
  # three-stage pipe into grep -q lost the race to SIGPIPE on a long message
  # (status 141) and a declared raise read as undeclared. grep exits 1 when
  # no line declares anything, which is a normal outcome here.
  local decl
  decl="$(grep -iE '^Debt-exception' <<<"$msgs")" || [ $? -eq 1 ]
  if grep -qF "$entry" <<<"$decl"; then
    return 0
  fi
  
  # Also check PR body if available (for squash merges where commit messages are discarded)
  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    local pr_body
    pr_body="$(jq -r '.pull_request.body // ""' "${GITHUB_EVENT_PATH}" 2>/dev/null || true)"
    decl="$(grep -iE '^Debt-exception' <<<"$pr_body")" || [ $? -eq 1 ]
    if grep -qF "$entry" <<<"$decl"; then
      return 0
    fi
  fi
  
  return 1
}

before_list="$(ceilings_at "$BASE_REF")"
after_list="$(ceilings_at "HEAD")"

if [ -z "$before_list" ] && [ -z "$after_list" ]; then
  echo "Debt ratchet: no Debtfile at ${BASE_REF} or HEAD — nothing to ratchet."
  exit 0
fi

echo "Debt ratchet — comparing ${DEBT} against ${BASE_REF}"

# --- rules 1 and 2: walk what existed before ---
while read -r id before; do
  [ -n "$id" ] || continue
  after="$(printf '%s\n' "$after_list" | awk -v k="$id" '$1 == k { print $2; exit }')"

  if [ -z "$after" ]; then
    if declared_for "$id"; then
      note "OK (declared)  ${id}: removed  [Debt-exception present]"
    else
      note "DELETED        ${id}: ceiling ${before} -> entry removed"
      note "               An entry leaves by reaching zero, not by deletion."
      fail=1
    fi
    continue
  fi

  if [ "$after" -gt "$before" ]; then
    if declared_for "$id"; then
      note "OK (declared)  ${id}: ${before} -> ${after}  [Debt-exception present]"
    else
      note "RAISED         ${id}: ceiling ${before} -> ${after}"
      fail=1
    fi
  elif [ "$after" -lt "$before" ]; then
    note "LOWERED        ${id}: ${before} -> ${after}  <- debt paid down"
  else
    note "unchanged      ${id}: ${before}"
  fi
done <<EOF
$before_list
EOF

# --- rule 3: entries that are new in HEAD are welcome, and are reported ---
while read -r id after; do
  [ -n "$id" ] || continue
  if ! printf '%s\n' "$before_list" | awk -v k="$id" '$1 == k { found = 1 } END { exit !found }'; then
    note "NEW            ${id}: ceiling ${after}  <- newly recorded debt"
  fi
done <<EOF
$after_list
EOF

# --- a declaration that names nothing real is itself a failure ---
decls="$(git log --format=%B "${BASE_REF}..HEAD" 2>/dev/null | grep -iE '^Debt-exception' || true)"
if [ -n "$decls" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    matched=0
    while read -r id _; do
      [ -n "$id" ] || continue
      case "$d" in *"$id"*) matched=1; break;; esac
    done <<EOF
$before_list
$after_list
EOF
    if [ "$matched" -eq 0 ]; then
      note "UNPARSEABLE    declaration names no known entry: ${d}"
      note "               'unparseable' must never mean 'allowed'."
      fail=1
    fi
  done <<EOF
$decls
EOF
fi

echo
if [ "$fail" = "0" ]; then
  echo "Debt ratchet: OK."
else
  cat <<'MSG'
Debt ratchet: FAILED.

A debt ceiling rose, or an entry was deleted, without saying so.

If the change is correct — a newly vendored tree, a probe corrected to count
something it was wrongly excluding, a concern that genuinely moved elsewhere —
declare it in the commit message, naming the entry:

    Debt-exception: docs-md-not-adoc — vendored upstream handbook adds 40 .md
    files that are not ours to convert

If it is not correct, pay the debt down rather than raising the ceiling.
MSG
fi
exit "$fail"
