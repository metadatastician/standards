#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# proof-inputs-sha256.sh: the reference digest of PROOF-POLICY §8.5.1.
#
# A proof receipt's :inputs-sha256, and the tree-sha256 witness of an echo
# (§8.5.2), are both the SHA-256 of a sorted manifest. This script computes
# that digest from git objects, so two repositories that run it on the same
# files get the same value.
#
# Usage:
#   proof-inputs-sha256.sh [-C REPO] [--manifest] COMMIT PATH...  the inputs digest of PATHs
#   proof-inputs-sha256.sh [-C REPO] [--manifest] COMMIT          the tree digest (every tracked file)
#
# The manifest has one line per file, in bytewise (C locale) order of path:
#
#   <sha256 of the file's bytes, 64 lowercase hex><two spaces><path><LF>
#
# * A path is relative to the repository root, with "/" separators and no
#   leading "./".
# * The file's bytes are the git blob stored at COMMIT, before any checkout
#   filter. For a symbolic link that is the link target.
# * Submodule entries (gitlinks) are not files and are left out. A PATH inside
#   a submodule is refused.
# * A path that holds a newline or a backslash is refused, because sha256sum
#   escapes such names and the manifest would then not match a shell rebuild.
#
# The digest is the SHA-256 of the manifest bytes, as 64 lowercase hex. For a
# clean checkout of COMMIT with no checkout filters, this shell line gives the
# same value:
#
#   printf '%s\n' PATH... | LC_ALL=C sort | xargs -d '\n' sha256sum -- | sha256sum
#
# --manifest prints the manifest instead of its digest.
#
# Exit: 0 digest printed; 1 a PATH is not a file at COMMIT, is repeated or is
# refused; 2 usage error, or git cannot read COMMIT.
set -euo pipefail

repo=. manifest=0
while [ $# -gt 0 ]; do
  case $1 in
    -C) [ $# -ge 2 ] || { echo "usage: -C needs a directory" >&2; exit 2; }; repo=$2; shift 2 ;;
    --manifest) manifest=1; shift ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "usage: proof-inputs-sha256.sh [-C REPO] [--manifest] COMMIT [PATH...]" >&2; exit 2; }
commit=$1; shift
git -C "$repo" rev-parse --verify --quiet "$commit^{commit}" >/dev/null \
  || { echo "cannot read commit $commit in $repo" >&2; exit 2; }

# Every blob at COMMIT: path -> object id.
declare -A blob=()
while IFS= read -r -d '' entry; do
  meta=${entry%%$'\t'*} path=${entry#*$'\t'}
  read -r _mode type oid <<<"$meta"
  [ "$type" = blob ] && blob[$path]=$oid
done < <(git -C "$repo" ls-tree -r -z --full-tree "$commit")

declare -a paths=()
if [ $# -eq 0 ]; then
  paths=("${!blob[@]}")
else
  declare -A seen=()
  for p in "$@"; do
    p=${p#./}
    [ -n "${blob[$p]+x}" ] || { echo "not a file at $commit: $p" >&2; exit 1; }
    [ -z "${seen[$p]+x}" ] || { echo "path given twice: $p" >&2; exit 1; }
    seen[$p]=1
    paths+=("$p")
  done
fi
[ ${#paths[@]} -gt 0 ] || { echo "no files to digest" >&2; exit 1; }

out=$(
  for p in "${paths[@]}"; do printf '%s\0' "$p"; done | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
    case $p in *$'\n'* | *\\*) echo "path holds a newline or a backslash: $p" >&2; exit 1 ;; esac
    h=$(git -C "$repo" cat-file blob "${blob[$p]}" | sha256sum)
    printf '%s  %s\n' "${h%% *}" "$p"
  done
) || exit 1
if [ "$manifest" = 1 ]; then
  printf '%s\n' "$out"
else
  h=$(printf '%s\n' "$out" | sha256sum)
  printf '%s\n' "${h%% *}"
fi
