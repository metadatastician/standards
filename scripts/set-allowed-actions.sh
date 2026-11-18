#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Apply and verify the canonical GitHub Actions policy (standards#486).
#
# Estate canon is config/settings/repo.json: allowed_actions=selected +
# sha_pinning_required=true for EVERY repository, with the allow-list payload in
# config/settings/actions-allowlist.json. `selected` is therefore the default
# posture here; ACTIONS_POSTURE=all exists only to relax a single repository
# deliberately. There is no "designated high-sensitivity" subset — an earlier
# header claimed one, but no such designation list has ever existed.
#
# ORDERING AND ROLLBACK (the reason this script was rewritten):
#   `selected` with an empty patterns_allowed refuses every third-party action.
#   Runs then die at startup with jobs.total_count == 0 and NO check run at all,
#   so a *required* context never reports and the repo looks GREENER than a
#   healthy one. The previous version flipped allowed_actions=selected FIRST and
#   installed the payload SECOND, with no rollback — so any failure of the second
#   call (the /actions/* endpoints have a hidden quota that 403s a contiguous
#   tail of a batch) left the repository strictly WORSE than before the script
#   ran. Measured on 239 repositories, 2026-09-14.
#
#   GitHub refuses PUT /actions/permissions/selected-actions unless the
#   repository is ALREADY on the selected posture, so "payload before flip" is
#   only literally possible when no flip is needed. This script therefore:
#     * installs the payload FIRST when the target is already `selected`
#       (monotone — adding patterns only ever grants), and
#     * when a flip IS required, captures the prior state and RESTORES it if the
#       payload fails, so a partial run is a no-op rather than an outage.
#
# Usage: set-allowed-actions.sh <owner/repo> [allowed-actions.json] [enterprise]
#   ACTIONS_NO_ESCALATE=1  stop at the repository level: when the policy is
#   governed higher up, exit 3 instead of writing the payload to the
#   organisation or enterprise (used by scripts/apply-settings-canon.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:?usage: set-allowed-actions.sh <owner/repo> [allowed-actions.json] [enterprise]}"
CANON="${2:-$SCRIPT_DIR/../config/settings/actions-allowlist.json}"
ENTERPRISE="${3:-${ENTERPRISE:-}}"
POSTURE="${ACTIONS_POSTURE:-selected}"
GH_BIN="${GH_BIN:-gh}"
OWNER="${REPO%%/*}"

[ "$POSTURE" = all ] || [ "$POSTURE" = selected ] || {
  echo "ERROR: ACTIONS_POSTURE must be 'all' or 'selected'" >&2
  exit 2
}
[ -f "$CANON" ] || { echo "ERROR: canonical allowlist not found: $CANON" >&2; exit 2; }
command -v "$GH_BIN" >/dev/null 2>&1 || { echo "ERROR: GitHub CLI not found: $GH_BIN" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 2; }
PATTERN_COUNT="$(jq -r '.patterns_allowed | length' "$CANON")"

# The canon file carries documentation keys (version, purpose, pruned_from_*,
# ...) that are not part of the API schema. Send only the three real fields.
PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq '{github_owned_allowed, verified_allowed, patterns_allowed}' "$CANON" > "$PAYLOAD" || {
  echo "ERROR: canonical allowlist is not valid JSON: $CANON" >&2
  exit 2
}

governed_higher_up() { grep -qiE 'organization or enterprise level|enterprise level' <<<"$1"; }

# Restore a repository to the posture it had before this script touched it.
# Best-effort by definition: it is called on a path that is already failing.
restore_prior() {
  local label="$1" prefix="$2" prior_allowed="$3" prior_sha="$4" out
  out="$($GH_BIN api -X PUT "$prefix/actions/permissions" \
    "${ENABLED_FIELDS[@]}" -f "allowed_actions=$prior_allowed" \
    -F "sha_pinning_required=$prior_sha" 2>&1)" || {
    echo "ERROR: $label ROLLBACK FAILED — repository is left on allowed_actions=$POSTURE with an incomplete allow-list and MUST be repaired by hand: $out" >&2
    return 1
  }
  echo "   $label rolled back to allowed_actions=$prior_allowed" >&2
}

# Return 0=applied+verified, 42=governed at a higher scope, 1=other failure.
apply_policy() {
  local label="$1" prefix="$2" current enabled_key enabled_value out rc verify
  local prior_allowed prior_sha selected

  current="$($GH_BIN api "$prefix/actions/permissions" 2>&1)" || {
    echo "ERROR: cannot read $label Actions permissions: $current" >&2
    return 1
  }
  prior_allowed="$(jq -r '.allowed_actions // "all"' <<<"$current")"
  prior_sha="$(jq -r '.sha_pinning_required // false' <<<"$current")"

  case "$prefix" in
    repos/*)
      enabled_key=enabled
      enabled_value="$(jq -r '.enabled // true' <<<"$current")"
      ENABLED_FIELDS=(-F "enabled=$enabled_value")
      ;;
    *)
      enabled_key=enabled_repositories
      enabled_value="$(jq -r '.enabled_repositories // "all"' <<<"$current")"
      ENABLED_FIELDS=(-f "enabled_repositories=$enabled_value")
      ;;
  esac

  # PAYLOAD FIRST whenever the repository is already on the selected posture:
  # adding patterns to a live allow-list only ever grants permission, so there is
  # no window in which the repository is stricter than either end state.
  if [ "$POSTURE" = selected ] && [ "$prior_allowed" = selected ]; then
    out="$($GH_BIN api -X PUT "$prefix/actions/permissions/selected-actions" --input "$PAYLOAD" 2>&1)" || {
      governed_higher_up "$out" && { echo "   $label selected policy is governed higher up (409) — escalating"; return 42; }
      echo "ERROR: $label selected-actions update failed: $out" >&2
      return 1
    }
  fi

  out="$($GH_BIN api -X PUT "$prefix/actions/permissions" \
    "${ENABLED_FIELDS[@]}" -f "allowed_actions=$POSTURE" -F sha_pinning_required=true 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    governed_higher_up "$out" && { echo "   $label policy is governed higher up (409) — escalating"; return 42; }
    echo "ERROR: $label permissions update failed: $out" >&2
    return 1
  fi

  # A flip WAS required, so the payload could not go first. If it fails now the
  # repository is disarmed — put it back the way we found it.
  if [ "$POSTURE" = selected ] && [ "$prior_allowed" != selected ]; then
    out="$($GH_BIN api -X PUT "$prefix/actions/permissions/selected-actions" --input "$PAYLOAD" 2>&1)" || {
      if governed_higher_up "$out"; then
        restore_prior "$label" "$prefix" "$prior_allowed" "$prior_sha"
        echo "   $label selected policy is governed higher up (409) — escalating"
        return 42
      fi
      echo "ERROR: $label selected-actions update failed: $out" >&2
      restore_prior "$label" "$prefix" "$prior_allowed" "$prior_sha"
      return 1
    }
  fi

  # The read-after-write is mandatory: an endpoint that silently drops or
  # resets sha_pinning_required must never be reported as successfully fixed.
  verify="$($GH_BIN api "$prefix/actions/permissions")" || {
    echo "ERROR: $label policy update could not be verified" >&2
    return 1
  }
  if [ "$(jq -r '.sha_pinning_required // false' <<<"$verify")" != true ]; then
    echo "ERROR: $label update left sha_pinning_required=false; refusing success" >&2
    return 1
  fi
  if [ "$(jq -r '.allowed_actions // "missing"' <<<"$verify")" != "$POSTURE" ]; then
    echo "ERROR: $label update did not retain allowed_actions=$POSTURE" >&2
    return 1
  fi
  if [ "$(jq -r --arg key "$enabled_key" '.[$key]' <<<"$verify")" != "$enabled_value" ]; then
    echo "ERROR: $label update changed $enabled_key unexpectedly" >&2
    return 1
  fi

  if [ "$POSTURE" = selected ]; then
    selected="$($GH_BIN api "$prefix/actions/permissions/selected-actions")" || return 1
    if [ "$(jq -r '(.patterns_allowed // []) | length' <<<"$selected")" -lt "$PATTERN_COUNT" ]; then
      echo "ERROR: selected-actions verification returned fewer than $PATTERN_COUNT patterns" >&2
      return 1
    fi
    # An empty allow-list is the disarming state this script exists to prevent.
    if [ "$(jq -r '(.patterns_allowed // []) | length' <<<"$selected")" -eq 0 ]; then
      echo "ERROR: $label is on allowed_actions=selected with an EMPTY allow-list; refusing success" >&2
      return 1
    fi
  fi

  echo "OK: $label policy verified (allowed=$POSTURE sha_pinning_required=true)"
}

echo "==> repository level: $REPO"
apply_policy repository "repos/$REPO"; rc=$?
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -ne 42 ] && exit 1

# A caller applying a per-repository payload (scripts/apply-settings-canon.sh
# unions the canon with that repository's live list) must not have it written
# to the whole organisation. Exit 3 = governed higher up, not escalated.
if [ "${ACTIONS_NO_ESCALATE:-0}" = 1 ]; then
  echo "   repository policy is governed higher up; not escalating (ACTIONS_NO_ESCALATE=1)"
  exit 3
fi

echo "==> organization level: $OWNER"
apply_policy organization "orgs/$OWNER"; rc=$?
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -ne 42 ] && exit 1

if [ -n "$ENTERPRISE" ]; then
  echo "==> enterprise level: $ENTERPRISE"
  apply_policy enterprise "enterprises/$ENTERPRISE"; rc=$?
  [ "$rc" -eq 0 ] && exit 0
  exit 1
fi

echo "ERROR: policy is enterprise-governed; provide the enterprise slug" >&2
exit 1
