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
#   * the 007 repository, under ANY owner -- out of scope for any normalisation
#     (owner rule). It was transferred, so it is matched by name, not by the
#     historical hyperpolymath/007 path, which a listing never returns.
#
# WHY EACH REPO IS READ ON ITS OWN
#   docs/REPO-SETTINGS.adoc: settings are read per repository, never from a
#   list endpoint. Lists only supply the names.
#
# FAILS CLOSED
#   A listing or read that fails stops the run with exit 2: a repository that
#   could not be examined is never reported as compliant, nor written on a
#   guess. So does an `--owners` list with no owner in it. Once writing has
#   started, a rejected write or a failed read-back is reported as FAIL and the
#   batch carries on, so one bad repository does not strand the rest.
#
# CREDENTIAL
#   Run it with your own `gh auth login` session. The listings only return what
#   the credential can see: a fine-grained token limited to selected
#   repositories would make a partial walk look complete.
#
# USAGE
#   scripts/apply-branch-autodelete.sh                    # report only (default)
#   scripts/apply-branch-autodelete.sh --apply            # write, then read back
#   scripts/apply-branch-autodelete.sh --owners a,b [--apply]
#
# EXIT: 0 = nothing left to change (or report printed); 1 = a write was
#       rejected, or its read-back failed or was not true; 2 = usage or
#       `gh` error before any write.
set -euo pipefail

# die: report a usage or `gh` error and stop with exit 2.
die() { echo "apply-branch-autodelete: $*" >&2; exit 2; }

APPLY=0
OWNERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --owners)
      case "${2:-}" in ''|-*) die "--owners needs a comma-separated list" ;; esac
      OWNERS="$2"; shift 2 ;;
    -h|--help) sed -n '3,48p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
command -v gh >/dev/null || die "gh not found"

me="$(gh api user --jq .login)" || die "gh is not logged in"
if [ -z "$OWNERS" ]; then
  orgs="$(gh api --paginate user/memberships/orgs \
    --jq '.[] | select(.state == "active" and .role == "admin") | .organization.login')" \
    || die "could not list organisation memberships"
  OWNERS="$me${orgs:+,$(paste -sd, - <<<"$orgs")}"
fi
echo "Owners: $OWNERS"

todo=()
walked=0
IFS=',' read -r -a owner_list <<<"$OWNERS"
for o in "${owner_list[@]}"; do
  [ -n "$o" ] || continue
  walked=$((walked + 1))
  if [ "$o" = "$me" ]; then ep="user/repos?affiliation=owner&per_page=100"
  else ep="orgs/$o/repos?type=all&per_page=100"; fi
  listing="$(gh api --paginate "$ep" --jq '.[] | select((.fork or .archived) | not) | .full_name')" \
    || die "could not list repositories for $o"
  while read -r r; do
    if [ -z "$r" ] || [ "${r#*/}" = "007" ]; then continue; fi
    state="$(gh api "repos/$r" --jq .delete_branch_on_merge)" || die "could not read $r"
    [ "$state" = "true" ] || todo+=("$r")
  done <<<"$listing"
done
[ "$walked" -gt 0 ] || die "--owners names no owner"

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
  if ! gh api -X PATCH "repos/$r" -F delete_branch_on_merge=true >/dev/null; then
    echo "FAIL $r (PATCH rejected)" >&2; failed=1; continue
  fi
  # A 200 is not proof; read the setting back (docs/REPO-SETTINGS.adoc).
  if ! after="$(gh api "repos/$r" --jq .delete_branch_on_merge)"; then
    echo "FAIL $r (could not read back)" >&2; failed=1
  elif [ "$after" = "true" ]; then
    echo "ON   $r"
  else
    echo "FAIL $r (did not read back true)" >&2; failed=1
  fi
done
exit "$failed"
