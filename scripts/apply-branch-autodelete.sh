#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# apply-branch-autodelete.sh -- turn on "Automatically delete head branches"
# (`delete_branch_on_merge`, canon in config/settings/repo.json) on every
# repository the caller administers.
#
# WHY A SCRIPT AND NOT A WORKFLOW
#   The setting needs repository administration. No credential in this repo's
#   CI holds that today (ESTATE_ADMIN_TOKEN is unset: tag-ruleset-canon.yml has
#   failed on it every week). The owner runs this with their own `gh` login.
#
# WHICH OWNERS
#   By default: the logged-in account, plus every organisation where the caller
#   is an ACTIVE ADMIN (`user/memberships/orgs`). Organisations where the caller
#   is only a member are never walked, so third-party orgs are never touched.
#   `--owners a,b` names the owners explicitly instead.
#
# WHAT IT SKIPS
#   * forks -- other people's work (estate rule: never touch forks);
#   * archived repositories -- read-only, a PATCH would fail;
#   * hyperpolymath/007 -- out of scope for any normalisation (owner rule).
#
# WHY EACH REPO IS READ ON ITS OWN
#   docs/REPO-SETTINGS.adoc: settings are read per repository, never from a
#   list endpoint. Lists only supply the names.
#
# USAGE
#   scripts/apply-branch-autodelete.sh                    # report only (default)
#   scripts/apply-branch-autodelete.sh --apply            # write, then read back
#   scripts/apply-branch-autodelete.sh --owners a,b [--apply]
#
# EXIT: 0 = nothing left to change (or report printed); 1 = a write did not
#       read back true; 2 = usage or `gh` error.
set -euo pipefail

APPLY=0
OWNERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --owners) OWNERS="${2:?--owners needs a comma-separated list}"; shift 2 ;;
    -h|--help) sed -n '3,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }

me="$(gh api user --jq .login)" || { echo "gh is not logged in" >&2; exit 2; }
if [ -z "$OWNERS" ]; then
  OWNERS="$me,$(gh api --paginate user/memberships/orgs \
    --jq '.[] | select(.state == "active" and .role == "admin") | .organization.login' | paste -sd, -)"
fi
echo "Owners: ${OWNERS%,}"

todo=()
IFS=',' read -r -a owner_list <<<"$OWNERS"
for o in "${owner_list[@]}"; do
  [ -n "$o" ] || continue
  if [ "$o" = "$me" ]; then ep="user/repos?affiliation=owner&per_page=100"
  else ep="orgs/$o/repos?type=all&per_page=100"; fi
  while read -r r; do
    if [ -z "$r" ] || [ "$r" = "hyperpolymath/007" ]; then continue; fi
    [ "$(gh api "repos/$r" --jq .delete_branch_on_merge)" = "true" ] || todo+=("$r")
  done < <(gh api --paginate "$ep" --jq '.[] | select((.fork or .archived) | not) | .full_name')
done

if [ "${#todo[@]}" -eq 0 ]; then
  echo "Every repository already auto-deletes merged branches."
  exit 0
fi
printf 'OFF  %s\n' "${todo[@]}"
if [ "$APPLY" -eq 0 ]; then
  echo "${#todo[@]} repositor(y|ies) to change. Re-run with --apply to turn the setting on."
  exit 0
fi

failed=0
for r in "${todo[@]}"; do
  gh api -X PATCH "repos/$r" -F delete_branch_on_merge=true >/dev/null
  # A 200 is not proof; read the setting back (docs/REPO-SETTINGS.adoc).
  if [ "$(gh api "repos/$r" --jq .delete_branch_on_merge)" = "true" ]; then
    echo "ON   $r"
  else
    echo "FAIL $r (did not read back true)" >&2; failed=1
  fi
done
exit "$failed"
