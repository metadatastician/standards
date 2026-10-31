#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-lock-pin-contract.sh — the REPRESENTATION, PROVENANCE and CLOSURE
# contract of `.github/workflows/actions.lock`.
#
# WHY THIS EXISTS (measured, not theorised)
# -----------------------------------------
# GitHub validates a reusable workflow against the CALLEE repository's own
# actions.lock AS IT EXISTS AT THE PINNED COMMIT. A record the runner cannot
# accept therefore does not break this repository first — it breaks every
# caller, at `Set up job`, before a single policy step executes.
#
# MEASURED: metadatastician/svalinn, run 40108154356 (2026-10-24), pinned to
# standards fad242d3. Twelve governance jobs, each with exactly ONE step
# (`Set up job`), each failing, none running policy:
#
#   Unable to resolve action `actions/checkout@3d3c42e5…`: invalid lockfile
#   pin. Run `gh actions-lock` to update the lockfile
#
# The cause was the record's own representation: `.ref` repeated the commit
# SHA instead of naming the reviewed tag (`ref: 3d3c42e5…` where the key was
# already `actions/checkout@3d3c42e5…`). standards#1271 corrected nine such
# leaves; standards#1290 measured four that survived and named the missing
# control: "a guard is added so a leaf entry whose `ref:` equals the 40-hex
# SHA in its own key cannot be committed again … nothing enforces the rule."
# This script is that guard.
#
# It is ADOPTED from hyperpolymath/cicd-suite#66 (`scripts/check-lock-pin-
# contract.sh`), which is the reviewed statement of the representation rule,
# and it is not the same thing as that guard:
#   * it keeps every rule cicd-suite#66 enforces (ref must name a reviewed
#     ref, commit must be `sha1-<40 hex>` agreeing with the key, unknown
#     schema is UNINSPECTED rather than clean, empty population is not a pass);
#   * it adds the standards-specific exemption #1290 states explicitly —
#     a CALLER-SIDE record for this repository's own reusable workflows
#     (`metadatastician/standards@<sha>` carrying a nested `uses:` list) is a
#     reusable-workflow edge, not a leaf action, and legitimately records the
#     requested ref verbatim. Exempting it is not a widening: it is confined
#     to (a) this repository — either of its two slugs, because the transfer
#     kept the repository ID and old locks name the old one, (b) records that
#     carry a `uses:` list, (c) `ref` exactly equal to the key's own SHA.
#     Anything else is still RED.
#   * it conjugates the two halves of provenance (`commit` ↔ key SHA) rather
#     than only checking shapes;
#   * it requires the lock to be CLOSED, by delegating to close-lock.sh
#     --check, because standards#963 and cicd-squabbler#101 measured that a
#     dangling edge also kills a run at startup. PR66 says of itself: "checks
#     lock representation only; it does not verify remote existence, workflow
#     closure, allowlist admission, or policy validity." This is the closure
#     half of that sentence, in the same gate, so the two cannot be run one
#     without the other.
#
# WHAT IT STILL DOES NOT PROVE (stated so a green is not misread)
# --------------------------------------------------------------
#   * Remote existence/reachability of a pinned commit — check-action-pins-
#     resolve.sh and lock-selfcheck.sh's separate probe own that.
#   * That a tag still points at the pinned SHA (a moved tag is invisible
#     here; close-lock.sh documents the measured tolerance for that).
#   * That GitHub itself accepts the file. This is a static contract over the
#     representations the runner is known to reject.
#   * Policy validity: that the workflows/gates are any good.
#
# EXIT
#   0 = every record conforms, the lock is closed, population inspected > 0
#   1 = at least one contract violation (each named, with the fix)
#   2 = NOT INSPECTED: no yq/jq, no lock, unreadable, non-map dependencies,
#       untested schema version, empty population, or no close-lock.sh. A
#       gate that cannot inspect must never report clean.
#
# USAGE
#   check-lock-pin-contract.sh [LOCKFILE] [--self-repo OWNER/REPO]
#   (default lockfile: .github/workflows/actions.lock)
#
# TESTS: scripts/tests/check-lock-pin-contract-test.sh
set -uo pipefail

LOCK=".github/workflows/actions.lock"
SELF_REPO=""
SELF_REPO_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-repo) SELF_REPO="${2:-}"; SELF_REPO_GIVEN=1; shift 2 ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) LOCK="$1"; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default the "caller-side" repository from the checkout itself, so a fork or
# a rename cannot silently turn the exemption into a no-op: an unset value
# would exempt nothing and redden the two legitimate records; a wrong value
# could exempt someone else's. Both are visible below.
if [ -z "$SELF_REPO" ]; then
  remote="$(git -C "$SCRIPT_DIR/.." remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    *github.com[:/]*/*.git) SELF_REPO="${remote#*github.com}"; SELF_REPO="${SELF_REPO#[:/]}"; SELF_REPO="${SELF_REPO%.git}" ;;
    *github.com[:/]*/*)     SELF_REPO="${remote#*github.com}"; SELF_REPO="${SELF_REPO#[:/]}" ;;
  esac
fi
SELF_REPO_LC="$(printf '%s' "$SELF_REPO" | tr 'A-Z' 'a-z')"

# The repository was transferred, and its ID (1116521501) did not change with
# the slug: old locks carry `hyperpolymath/standards@<sha>` for the same
# repository this file now calls `metadatastician/standards`. Recognising both
# is the same doctrine the reusable-workflow contract test enforces, and it is
# confined to these two slugs — never a pattern, never a wildcard. An explicit
# --self-repo disables the alias, so an operator can ask the narrow question.
SELF_REPO_ALIASES=""
if [ "$SELF_REPO_GIVEN" -eq 0 ]; then
  case "$SELF_REPO_LC" in
    metadatastician/standards|hyperpolymath/standards)
      SELF_REPO_ALIASES='metadatastician/standards hyperpolymath/standards' ;;
  esac
fi
is_self_repo() {
  local candidate=$1 alias
  [ "$candidate" = "$SELF_REPO_LC" ] && return 0
  for alias in $SELF_REPO_ALIASES; do
    [ "$candidate" = "$alias" ] && return 0
  done
  return 1
}

not_inspected() { echo "::error::$* — NOT INSPECTED, which is not a pass." >&2; exit 2; }

command -v yq >/dev/null 2>&1 ||
  not_inspected "yq not found (mikefarah yq v4 is required to read YAML; YAML-POLICY Y-1)"
yq --version 2>/dev/null | grep -q mikefarah ||
  not_inspected "yq on PATH is not mikefarah yq v4 (got: $(yq --version 2>&1 | head -1))"
command -v jq >/dev/null 2>&1 || not_inspected "jq not found (structured record comparison)"
[ -f "$LOCK" ] || not_inspected "lockfile not found: $LOCK"

JSON="$(yq -o json -I 0 '.' "$LOCK" 2>&1)" ||
  not_inspected "yq could not parse $LOCK: $(printf '%s' "$JSON" | head -1)"
printf '%s' "$JSON" | jq -e 'type == "object"' >/dev/null 2>&1 ||
  not_inspected "$LOCK is not a YAML mapping"

VERSION="$(printf '%s' "$JSON" | jq -r '.version // ""')"
case "$VERSION" in
  # Only the schemas this contract has been reviewed against. A newer lock
  # schema is UNINSPECTED: passing it would be an assertion about a format
  # nobody has read.
  v0.0.2|v0.0.3) ;;
  *) not_inspected "untested lock schema version: '${VERSION}'" ;;
esac

printf '%s' "$JSON" | jq -e '.dependencies | type == "object"' >/dev/null 2>&1 ||
  not_inspected "dependencies: must be a mapping of 'owner/repo@ref' records"

# Population is stated, and an empty one is not a pass: a lock that keys
# nothing is a lock nobody has checked.
COUNT="$(printf '%s' "$JSON" | jq -r '.dependencies | length')"
[ "${COUNT:-0}" -gt 0 ] 2>/dev/null ||
  not_inspected "the lock keys no dependencies; zero records is no assurance"

# One row per record: key, ref type, ref, commit type, commit, owner_id,
# repo_id, whether the record carries a nested `uses:` (i.e. it is a
# reusable-workflow edge, not a leaf action).
ROWS="$(printf '%s' "$JSON" | jq -r '
  .dependencies | to_entries[] |
  [ .key,
    (.value.ref    | type),
    (if (.value.ref    | type) == "string" then .value.ref    else "" end),
    (.value.commit | type),
    (if (.value.commit | type) == "string" then .value.commit else "" end),
    (if (.value.owner_id | type) == "number" then (.value.owner_id|tostring) else "" end),
    (if (.value.repo_id  | type) == "number" then (.value.repo_id |tostring) else "" end),
    (if (.value.uses != null) then "yes" else "no" end)
  ] | @tsv
')" || not_inspected "could not enumerate .dependencies records"

failed=0
count=0
exempt=0
fail() { echo "$*"; failed=$((failed + 1)); }

while IFS=$'\t' read -r key reftype ref committtype commit owner_id repo_id has_uses; do
  [ -n "$key" ] || continue
  count=$((count + 1))

  # ── key shape ────────────────────────────────────────────────────────
  case "$key" in
    *@*) ;;
    *) fail "INVALID ${key}: key is not 'owner/repo@ref'"; continue ;;
  esac
  repo_lc="$(printf '%s' "${key%@*}" | tr 'A-Z' 'a-z')"
  pin="${key##*@}"
  pin_lc="$(printf '%s' "$pin" | tr 'A-Z' 'a-z')"

  # A key that is not a commit is not an immutable pin. The lock exists to
  # make every action's identity a commit; a tag-keyed record (measured at
  # fad242d3: `actions/setup-python@v2`) records a moving target.
  if ! printf '%s' "$pin_lc" | grep -Eq '^[0-9a-f]{40}$'; then
    fail "INVALID ${key}: key ref is not a 40-hex commit — lock keys must be SHA-pinned (canon rule 10)"
  fi

  # ── record.ref ───────────────────────────────────────────────────────
  if [ "$reftype" != "string" ] || [ -z "$ref" ]; then
    fail "INVALID ${key}: ref must be a non-empty string naming the reviewed ref (got ${reftype})"
  elif printf '%s' "$ref" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    # The historical defect. Permitted ONLY for a caller-side record of this
    # repository's own reusable workflows (standards#1290), where the
    # requested ref genuinely IS the caller's pin and no tag exists to name.
    if [ "$has_uses" = "yes" ] && is_self_repo "$repo_lc"; then
      exempt=$((exempt + 1))
      echo "  ok (caller-side reusable edge) ${key}: ref repeats the pin by design"
    else
      fail "INVALID ${key}: ref repeats the commit SHA; it must name the reviewed branch/tag (runner: 'invalid lockfile pin', standards#1271/#1290)"
    fi
  fi

  # ── record.commit, conjugated with the key ───────────────────────────
  if [ "$committtype" != "string" ] || ! printf '%s' "$commit" | grep -Eq '^sha1-[0-9a-f]{40}$'; then
    fail "INVALID ${key}: commit must be 'sha1-<40 hex>' (got ${committtype}: '${commit}')"
  elif printf '%s' "$pin_lc" | grep -Eq '^[0-9a-f]{40}$' && [ "$commit" != "sha1-${pin_lc}" ]; then
    fail "INVALID ${key}: commit '${commit}' disagrees with the key's own pin 'sha1-${pin_lc}'"
  fi

  # ── provenance ids ───────────────────────────────────────────────────
  if [ -z "$owner_id" ] || [ -z "$repo_id" ]; then
    fail "INVALID ${key}: owner_id/repo_id missing — the record cannot be attributed to an owner"
  fi
done <<< "$ROWS"

[ "$count" -gt 0 ] || not_inspected "no dependency records were inspected"

# ── closure ────────────────────────────────────────────────────────────
# Every ref named under `workflows:` and inside a record's nested `uses:`
# needs its own top-level record. Delegated, not reimplemented: close-lock.sh
# owns the contract and its fixture corpus.
CLOSE_LOCK="$SCRIPT_DIR/close-lock.sh"
[ -f "$CLOSE_LOCK" ] ||
  not_inspected "close-lock.sh not found beside this script ($CLOSE_LOCK): closure cannot be judged here"

# close-lock.sh reads the emitted text shape (4-space quoted record keys,
# 8-space quoted list items) rather than re-parsing YAML. Delegating closure to
# it is right — it owns that contract and its fixture corpus — but it means a
# lock that yq can read and close-lock cannot would be reported "closed" over
# an empty key set. Cross-check the two population counts so that mismatch is
# UNINSPECTED, not clean.
canonical_keys="$(awk '/^dependencies:/{f=1;next} f&&/^    '\''[^'\'']+'\'':$/{n++} END{print n+0}' "$LOCK")"
if [ "${canonical_keys:-0}" -ne "$COUNT" ]; then
  not_inspected "close-lock.sh reads ${canonical_keys:-0} record key(s) but the document has ${COUNT}: the file is not in the emitted shape closure can be judged over"
fi
closure_out="$(bash "$CLOSE_LOCK" --check "$LOCK" 2>&1)"
closure_rc=$?
if [ "$closure_rc" -ne 0 ]; then
  if [ "$closure_rc" -eq 2 ]; then
    not_inspected "close-lock.sh could not read $LOCK: $(printf '%s' "$closure_out" | head -1)"
  fi
  fail "INVALID closure: the lock names refs it does not record (standards#963, cicd-squabbler#101):"
  printf '%s\n' "$closure_out" | sed 's/^/  /'
fi

echo "inspected ${count} dependency record(s) in ${LOCK} (schema ${VERSION}); caller-side reusable edges exempted: ${exempt}; contract violations: ${failed}"
if [ "$failed" -ne 0 ]; then
  echo "::error::actions.lock violates the pin contract in ${failed} place(s). Fix the RECORD, not this gate: a leaf action's ref names the reviewed tag that resolves to its pin (run \`gh actions-lock\`, then close-lock.sh)." >&2
  exit 1
fi
echo "PASS: every record names a reviewed ref, conjugates its commit, carries provenance, and the lock is closed."
echo "       (Remote reachability and tag movement are NOT proven here.)"
exit 0
