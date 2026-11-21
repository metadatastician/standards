#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# bump-action-pins.sh — move third-party `uses: owner/repo@<sha> # vX.Y.Z` pins
# to the latest release, in ONE checkout, WITHOUT touching actions.lock.
#
# WHY THIS EXISTS (owner ruling "single writer")
# ----------------------------------------------
# Dependabot bumped `uses:` SHAs and nothing regenerated .github/workflows/
# actions.lock, so the two drifted (lock-sync red on standards main; affinescript
# CI dark from 11 Oct). The fix is one writer: the applier
# (scripts/regen-dependabot-locks.sh, BUMP_PINS=1) runs this script on a clone,
# commits the bump locally, regenerates the lock on top of it, and pushes the
# workflow edits and the lock in ONE commit. This script is the bump half only.
#
# WHAT IT BUMPS
# -------------
# Every `uses: owner/repo[/path]@<40-hex> # <tag>` in .github/workflows/*.y*ml
# and .github/actions/**/action.y*ml whose
#   * owner is not first-party (those re-point through apply-workflow-pins),
#   * repository matches no pattern in the holds file, and
#   * latest release (the releases/latest endpoint: no drafts, no pre-releases)
#     is a strictly newer version than the pin comment.
# The SHA is the commit the release tag points at (annotated tags are peeled).
# The pin comment is rewritten to the new tag and nothing else on the line moves.
# An unpinned ref, a local `./` ref, a `docker://` ref, a pin with no version
# comment, or a tag that is not a version is left alone and reported.
#
# Output (stdout): one TSV row per decision: file, action, old, new, verdict.
# Verdicts: bumped | current | held | first-party | no-release | unparsed |
# unresolved. It exits 0 unless the arguments are wrong; the caller decides from
# `git status` whether anything changed.
#
# Usage: bump-action-pins.sh [DIR]            (default: the current directory)
# Env:   GH_BIN (default gh; GH_TOKEN must read public repositories),
#        BUMP_HOLDS (holds file; default config/settings/actions-bump-holds.txt
#        next to this script's repository root),
#        FIRST_PARTY_OWNERS (space list; default the three estate owners).
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUMP_HOLDS="${BUMP_HOLDS:-$HERE/../config/settings/actions-bump-holds.txt}"
FIRST_PARTY_OWNERS="${FIRST_PARTY_OWNERS:-hyperpolymath metadatastician catachresis-colloquium}"
dir="${1:-.}"
[ -d "$dir/.github" ] || { echo "bump-action-pins: no .github in $dir" >&2; exit 2; }

# held <owner/repo>: true when a holds pattern (shell glob) matches. Blank lines
# and `#` comments are ignored.
held() {
  local pat
  [ -f "$BUMP_HOLDS" ] || return 1
  while IFS= read -r pat; do
    pat="${pat%%#*}"; pat="${pat//[[:space:]]/}"
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$1" in $pat) return 0 ;; esac
  done < "$BUMP_HOLDS"
  return 1
}

# first_party <owner>: true for an estate owner.
first_party() {
  local o
  for o in $FIRST_PARTY_OWNERS; do [ "$o" = "$1" ] && return 0; done
  return 1
}

# version_of <tag>: print the dotted numeric part of a tag (v1.2.3 -> 1.2.3),
# or fail when the tag does not start with one. A `-rc1` style suffix is a
# pre-release and fails too: only plain releases are compared.
version_of() {
  local t="${1#v}"
  [[ "$t" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  printf '%s' "$t"
}

# newer <new> <old>: true when version $1 is strictly greater than $2 (padded
# to the same length so 2 equals 2.0.0).
newer() {
  local a b hi
  a="$1"; b="$2"
  [ "$a" = "$b" ] && return 1
  hi="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)"
  [ "$hi" = "$a" ]
}

declare -A LATEST_TAG LATEST_SHA
# latest_tag <owner/repo>: set LATEST_TAG to the latest release tag, "-" when
# the repository has no readable release, or "?" for a tag that is not plain.
latest_tag() {
  local repo="$1" tag
  [ -n "${LATEST_TAG[$repo]:-}" ] && return 0
  if ! tag="$("$GH_BIN" api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null)" || [ -z "$tag" ]; then
    LATEST_TAG[$repo]="-"; return 0
  fi
  if [[ "$tag" =~ ^[A-Za-z0-9._+-]+$ ]]; then LATEST_TAG[$repo]="$tag"; else LATEST_TAG[$repo]="?"; fi
}

# tag_sha <owner/repo> <tag>: print the 40-hex commit the tag points at, peeling
# annotated tags (bounded); fail when it does not resolve to a commit. Only
# called once a bump is certain, so a pin that is current costs one API call.
tag_sha() {
  local repo="$1" tag="$2" ref type sha n
  ref="$("$GH_BIN" api "repos/$repo/git/ref/tags/$tag" --jq '.object.type + " " + .object.sha' 2>/dev/null)" || return 1
  type="${ref%% *}"; sha="${ref#* }"
  for n in 1 2 3; do
    [ "$type" = tag ] || break
    ref="$("$GH_BIN" api "repos/$repo/git/tags/$sha" --jq '.object.type + " " + .object.sha' 2>/dev/null)" || return 1
    type="${ref%% *}"; sha="${ref#* }"
  done
  [ "$type" = commit ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$sha"
}

# One pass per file. A bump is applied to the lines that carry exactly the old
# 40-hex SHA for exactly that action, so two actions that share a SHA never
# trade pins.
while IFS= read -r -d '' file; do
  rel="${file#"$dir"/}"
  while IFS= read -r line; do
    # shellcheck disable=SC2001
    spec="$(sed -E 's/^.*uses:[[:space:]]*["'"'"']?([^[:space:]"'"'"'@]+)@([0-9a-f]{40})["'"'"']?[[:space:]]*#[[:space:]]*([^[:space:]]+).*$/\1 \2 \3/' <<< "$line")"
    read -r action old comment <<< "$spec"
    repo="$(cut -d/ -f1,2 <<< "$action")"
    owner="${repo%%/*}"
    if first_party "$owner"; then printf '%s\t%s\t%s\t-\tfirst-party\n' "$rel" "$action" "${old:0:12}"; continue; fi
    if held "$repo" || held "$action"; then printf '%s\t%s\t%s\t-\theld\n' "$rel" "$action" "${old:0:12}"; continue; fi
    # Untrusted repo text reaches a sed expression below: accept only the strict
    # action grammar (owner/repo[/path]) and a plain version token. Anything else
    # is reported as unparsed and never interpolated.
    if ! [[ "$action" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?$ && "$old" =~ ^[0-9a-f]{40}$ && "$comment" =~ ^[A-Za-z0-9._+-]+$ ]]; then
      printf '%s\t%s\t%s\t-\tunparsed\n' "$rel" "${action:0:80}" "${old:0:12}"; continue
    fi
    cur="$(version_of "$comment")" || { printf '%s\t%s\t%s\t-\tunparsed\n' "$rel" "$action" "${old:0:12}"; continue; }
    latest_tag "$repo"
    tag="${LATEST_TAG[$repo]}"
    case "$tag" in
      -) printf '%s\t%s\t%s\t-\tno-release\n' "$rel" "$action" "${old:0:12}"; continue ;;
      '?') printf '%s\t%s\t%s\t-\tunparsed\n' "$rel" "$action" "${old:0:12}"; continue ;;
    esac
    latest="$(version_of "$tag")" || { printf '%s\t%s\t%s\t-\tunparsed\n' "$rel" "$action" "${old:0:12}"; continue; }
    if ! newer "$latest" "$cur"; then printf '%s\t%s\t%s\t-\tcurrent\n' "$rel" "$action" "${old:0:12}"; continue; fi
    if [ -z "${LATEST_SHA[$repo]:-}" ]; then
      LATEST_SHA[$repo]="$(tag_sha "$repo" "$tag")" || LATEST_SHA[$repo]="?"
    fi
    new="${LATEST_SHA[$repo]}"
    if [ "$new" = "?" ]; then printf '%s\t%s\t%s\t-\tunresolved\n' "$rel" "$action" "${old:0:12}"; continue; fi
    # Rewrite SHA and the first token of the pin comment on this action's lines.
    esc_action="$(sed 's/[.[\*^$/]/\\&/g' <<< "$action")"
    esc_comment="$(sed 's/[.[\*^$/]/\\&/g' <<< "$comment")"
    sed -E -i "s|(uses:[[:space:]]*[\"']?${esc_action})@${old}([\"']?[[:space:]]*#[[:space:]]*)${esc_comment}|\1@${new}\2${tag}|" "$file"
    printf '%s\t%s\t%s\t%s\tbumped\n' "$rel" "$action" "${old:0:12}" "${new:0:12}"
  done < <(grep -E 'uses:[[:space:]]*["'"'"']?[^[:space:]"'"'"'@]+@[0-9a-f]{40}["'"'"']?[[:space:]]*#' "$file" | sort -u)
done < <(find "$dir/.github/workflows" "$dir/.github/actions" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null | sort -z)
exit 0
