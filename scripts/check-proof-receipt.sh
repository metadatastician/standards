#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-proof-receipt.sh: the git checks of PROOF-POLICY §8.5.3.
#
# The reader (deed_lint.js --proof-receipt-json) checks what the text of a
# proof receipt shows. This script checks the warrant with git: that the
# commits a receipt names hold what the receipt says they hold. The home
# repository's gate and every consumer that catalogues PWG-1 (such as
# Mathesis) run it, so that each one checks in the same way.
#
# Usage: check-proof-receipt.sh [--branch REF] [--import OWNER/REPO=DIR]... RECEIPT REPO
#
#   RECEIPT  the *_praxis.deed proof receipt
#   REPO     a clone of the receipt's :repository. Every commit the receipt
#            names must be present: fetch a squashed or rebased source by
#            the reference the forge keeps (on GitHub refs/pull/<n>/head).
#   --branch the default-branch ref in REPO (default: HEAD)
#   --import a clone of a repository that a receipt's (import …) names; give
#            one for each imported repository
#
# Checks, each reported by name:
#   1. the reader accepts the receipt;
#   2. the :source-commit is REF or an ancestor of REF;
#   3. for each current receipt, of a leg or of a negative control, every
#      (inputs-manifest …) entry is a file at the receipt's :commit, and the
#      SHA-256 of its git blob is the recorded :sha256 (so :inputs-sha256
#      holds there, because the reader derived it from the manifest); and
#      every (import …) holds in the same way in its --import clone at its
#      :commit;
#   4. for each (echo …):
#      * inputs-sha256: for each prover, a manifest in the receipt has the
#        echo's digest, and that manifest holds at the source and at the
#        image;
#      * tree-sha256: scripts/proof-inputs-sha256.sh COMMIT gives the
#        recorded :tree-sha256 at the source and at the image.
#
# Exit: 0 every check holds; 1 a check fails (each failure is named);
# 2 the check could not run (a tool is missing, or REPO is not a git clone).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$HERE/../1-formats/deed/tools/deed_lint.js"
DIGEST="$HERE/proof-inputs-sha256.sh"

branch=HEAD
declare -A import_dir=()
while [ $# -gt 0 ]; do
  case $1 in
    --branch) [ $# -ge 2 ] || { echo "usage: --branch needs a ref" >&2; exit 2; }; branch=$2; shift 2 ;;
    --import)
      [ $# -ge 2 ] && [[ $2 == */*=* ]] || { echo "usage: --import needs OWNER/REPO=DIR" >&2; exit 2; }
      import_dir[${2%%=*}]=${2#*=}; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { echo "usage: check-proof-receipt.sh [--branch REF] [--import OWNER/REPO=DIR]... RECEIPT REPO" >&2; exit 2; }
receipt=$1 repo=$2
for tool in bun jq git sha256sum; do
  command -v "$tool" >/dev/null || { echo "cannot run: $tool is not installed" >&2; exit 2; }
done
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "cannot run: $repo is not a git clone" >&2; exit 2; }
git -C "$repo" rev-parse --verify --quiet "$branch^{commit}" >/dev/null \
  || { echo "cannot run: $branch is not a commit in $repo" >&2; exit 2; }

failures=0
fail() { failures=$((failures + 1)); echo "FAIL $*"; }
ok() { echo "ok   $*"; }

# 1. The reader.
if ! json=$(bun "$READER" --proof-receipt-json "$receipt" 2>&1); then
  fail "reader: $json"
  exit 1
fi
ok "reader accepts $receipt"

have_commit() { git -C "${2:-$repo}" cat-file -e "$1^{commit}" 2>/dev/null; }

# 2. The :source-commit is on the default branch.
src=$(jq -r .source_commit <<<"$json")
if ! have_commit "$src"; then
  fail ":source-commit $src is not in $repo"
elif git -C "$repo" merge-base --is-ancestor "$src" "$branch"; then
  ok ":source-commit $src is on $branch"
else
  fail ":source-commit $src is not on $branch"
fi

# The manifest a commit really holds for PATHs, in the §8.5.1 form.
manifest_at() { # DIR COMMIT PATH...
  local dir=$1 commit=$2; shift 2
  bash "$DIGEST" -C "$dir" --manifest "$commit" "$@" 2>&1
}
# The manifest a receipt records, in the same form.
manifest_text() { # JSON array of {path, sha256}
  jq -r '.[] | "\(.sha256)  \(.path)"' <<<"$1"
}
check_manifest() { # LABEL COMMIT MANIFEST-JSON [DIR]
  local label=$1 commit=$2 mj=$3 dir=${4:-$repo} want got
  if ! have_commit "$commit" "$dir"; then fail "$label: commit $commit is not in $dir"; return; fi
  mapfile -t paths < <(jq -r '.[].path' <<<"$mj")
  want=$(manifest_text "$mj")
  if ! got=$(manifest_at "$dir" "$commit" "${paths[@]}"); then fail "$label: at $commit: $got"; return; fi
  if [ "$got" = "$want" ]; then
    ok "$label: the manifest holds at $commit"
  else
    fail "$label: the manifest does not hold at $commit"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed -n 's/^[<>] /     /p' | head -10
  fi
}

# 3. Each current receipt's manifest holds at its :commit, and so does each
# of its imports, in the clone given for it.
while IFS= read -r r; do
  label=$(jq -r '"claim \(.claim) \(.what) receipt"' <<<"$r")
  check_manifest "$label" "$(jq -r .commit <<<"$r")" "$(jq -c .manifest <<<"$r")"
  while IFS= read -r i; do
    irepo=$(jq -r .repository <<<"$i")
    if [ -z "${import_dir[$irepo]+x}" ]; then
      fail "$label: import $irepo: no clone given (--import $irepo=DIR)"
      continue
    fi
    # A clone that holds the home :source-commit is the home repository (or a
    # fork of it) under another name: its files belong in (inputs-manifest …).
    if have_commit "$src" "${import_dir[$irepo]}"; then
      fail "$label: import $irepo: its clone holds the home :source-commit $src, so it is the home repository"
      continue
    fi
    check_manifest "$label: import $irepo" "$(jq -r .commit <<<"$i")" "$(jq -c .files <<<"$i")" "${import_dir[$irepo]}"
  done < <(jq -c '.imports[]' <<<"$r")
done < <(jq -c '.claims[] as $c
  | ( ($c.legs[] | {what: .prover, receipts}),
      ($c.controls[] | {what: "\(.prover) control \(.path)", receipts}) ) as $l
  | $l.receipts[]
  | select(.state == "current" and .inputs_manifest != null)
  | {claim: $c.id, what: $l.what, commit, manifest: .inputs_manifest, imports}' <<<"$json")

# 4. Each echo's witness holds at its source and its image.
while IFS= read -r e; do
  s=$(jq -r .source <<<"$e") i=$(jq -r .image <<<"$e") w=$(jq -r .witness <<<"$e")
  label="echo $s -> $i"
  if [ "$w" = tree-sha256 ]; then
    want=$(jq -r .tree_sha256 <<<"$e")
    for c in "$s" "$i"; do
      if ! have_commit "$c"; then fail "$label: commit $c is not in $repo"; continue; fi
      got=$(bash "$DIGEST" -C "$repo" "$c" 2>&1) || { fail "$label: at $c: $got"; continue; }
      if [ "$got" = "$want" ]; then ok "$label: tree-sha256 holds at $c"; else fail "$label: tree-sha256 at $c is $got, not $want"; fi
    done
  else
    while IFS=$'\t' read -r prover d; do
      mj=$(jq -c --arg d "$d" '[.claims[].legs[].receipts[] | select(."inputs-sha256" == $d and .inputs_manifest != null)
        | .inputs_manifest] | first // empty' <<<"$json")
      if [ -z "$mj" ]; then
        fail "$label: no (inputs-manifest …) in the receipt has the $prover digest $d, so it cannot be checked"
        continue
      fi
      check_manifest "$label ($prover) source" "$s" "$mj"
      check_manifest "$label ($prover) image" "$i" "$mj"
    done < <(jq -r '.inputs | to_entries[] | "\(.key)\t\(.value)"' <<<"$e")
  fi
done < <(jq -c '.echoes[]' <<<"$json")

if [ "$failures" -gt 0 ]; then
  echo "check-proof-receipt: $failures check(s) failed"
  exit 1
fi
echo "check-proof-receipt: every check holds"
