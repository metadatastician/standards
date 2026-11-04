#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Check the LIVE GitHub Actions policy for a repository (standards#486).
#
# Usage: check-actions-policy.sh <owner/repo> [allowed-actions.json]
# Exit: 0 compliant | 1 policy violation | 2 local setup error |
#       3 live policy unavailable (authentication/API failure)
set -euo pipefail

REPOSITORY="${1:?usage: check-actions-policy.sh <owner/repo> [allowed-actions.json]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="${2:-${ALLOWLIST_JSON:-$SCRIPT_DIR/../config/settings/actions-allowlist.json}}"
GH_BIN="${GH_BIN:-gh}"

[ -f "$CANON" ] || { echo "ERROR: canonical allowlist not found: $CANON" >&2; exit 2; }
command -v "$GH_BIN" >/dev/null 2>&1 || { echo "ERROR: GitHub CLI not found: $GH_BIN" >&2; exit 2; }

permissions="$($GH_BIN api "repos/$REPOSITORY/actions/permissions")" || {
  echo "ERROR: could not read live Actions permissions for $REPOSITORY" >&2
  exit 3
}

enabled="$(jq -r '.enabled // false' <<<"$permissions")"
allowed="$(jq -r '.allowed_actions // "missing"' <<<"$permissions")"
sha_pin="$(jq -r '.sha_pinning_required // false' <<<"$permissions")"

[ "$enabled" = true ] || { echo "ERROR: Actions are disabled for $REPOSITORY" >&2; exit 1; }
[ "$sha_pin" = true ] || { echo "ERROR: sha_pinning_required is OFF for $REPOSITORY" >&2; exit 1; }

case "$allowed" in
  all)
    echo "policy ok: repository=$REPOSITORY allowed=all sha_pin=true"
    ;;
  selected)
    selected="$($GH_BIN api "repos/$REPOSITORY/actions/permissions/selected-actions")" || {
      echo "ERROR: could not read selected Actions policy for $REPOSITORY" >&2
      exit 3
    }
    count="$(jq -r '(.patterns_allowed // []) | length' <<<"$selected")"
    [ "$count" -gt 0 ] || {
      echo "ERROR: allowed_actions=selected with EMPTY patterns_allowed for $REPOSITORY" >&2
      exit 1
    }
    missing="$(jq -n --argjson canon "$(<"$CANON")" --argjson live "$selected" '
      [($canon.patterns_allowed // [])[] as $required
       | select((($live.patterns_allowed // []) | index($required)) == null)
       | $required]')"
    if [ "$(jq 'length' <<<"$missing")" -ne 0 ]; then
      echo "ERROR: live selected allowlist is not a superset of the canonical policy:" >&2
      jq -r '.[] | "  missing: \(.)"' <<<"$missing" >&2
      exit 1
    fi
    for flag in github_owned_allowed verified_allowed; do
      required="$(jq -r --arg flag "$flag" '.[$flag] // false' "$CANON")"
      live="$(jq -r --arg flag "$flag" '.[$flag] // false' <<<"$selected")"
      if [ "$required" = true ] && [ "$live" != true ]; then
        echo "ERROR: selected policy disables required flag $flag" >&2
        exit 1
      fi
    done
    echo "policy ok: repository=$REPOSITORY allowed=selected patterns=$count sha_pin=true"
    ;;
  *)
    echo "ERROR: unsupported allowed_actions value '$allowed' for $REPOSITORY" >&2
    exit 1
    ;;
esac
