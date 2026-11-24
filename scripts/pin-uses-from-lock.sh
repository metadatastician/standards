#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# pin-uses-from-lock.sh — rewrite tag-form `uses:` refs in a repo's workflows
# to inline SHA pins, taking each SHA from that repo's own actions.lock.
#
# WHY THIS EXISTS
# ---------------
# The lock pin contract (canon rule 10; check-lock-pin-contract.sh, enforced on
# callers since standards 2b543da1, #1458) requires every leaf record of
# actions.lock to be keyed by a 40-hex commit. relock-sha-keys.sh re-keys a
# record to its SHA only when that SHA is written inline in a workflow, and on
# purpose keeps the tag key of any record whose tag is still written in a
# workflow (re-keying it would strand those workflows). A repo that writes
# `uses: actions/checkout@v7.0.1` therefore cannot satisfy the contract with
# the repair chain alone: its workflows have to say the SHA first. Measured on
# hyperpolymath/hypatia, 2026-11-24: 212 tag-form `uses:` in 26 workflows,
# 34 contract violations.
#
# The SHA for each tag is already in the lock: the record `owner/repo@<tag>`
# carries `commit: 'sha1-<sha>'`, the commit `gh actions-lock` resolved and the
# runner verifies. Writing that SHA inline changes no action version, so the
# rewrite needs no network and no judgement.
#
# WHAT IT DOES
# ------------
# For every line of every workflow (*.yml, *.yaml directly in <workflows-dir>,
# the set relock-sha-keys.sh reads) of the form
#     [- ]uses: owner/repo[/path]@<ref>
# with the ref optionally single- or double-quoted, it decides:
#   pinned          the ref is a tag the lock records: rewritten to
#                   `owner/repo[/path]@<sha> # <ref>` (inside the quotes when
#                   the ref was quoted; the comment always follows them)
#   already-pinned  the ref is a 40-hex SHA: left alone
#   expression      the ref holds `${{`: left alone
#   commented       the line already carries a `#` comment: left alone, since
#                   merging two comments is a judgement, not a rewrite
#   unlocked        the lock has no record `owner/repo@<ref>`: left alone
# Local (`./…`) and `docker://` refs never match the form and are not listed.
# Every other byte of a file is kept, including a missing final newline.
#
# OUTPUT AND EXIT
# ---------------
# stdout: one TSV row per `uses:` line it read:
#   file  line  old-ref  new-ref  verdict
# (new-ref is `-` unless the verdict is pinned.)
# stderr: a one-line summary.
# Exit 0 on success, 1 when the lock is missing or names a record with no
# 40-hex commit, 2 on a usage error.
#
# Dry run by default: nothing is written without --write.
#
# AFTER --write, run the estate repair chain on the same directory so the lock
# matches the new workflow bytes, then the gates:
#   relock-sha-keys.sh → complete-job-refs.sh → close-lock.sh → prune-stale.sh
#   check-lock-sync.sh, check-lock-pin-contract.sh
#
# NOT HANDLED (reported or left as they are):
#   * a `uses:` line inside a `run:` block scalar that happens to start the
#     line is read as a step (the same reading relock-sha-keys.sh makes);
#   * composite actions under .github/actions/ are not read, matching
#     relock-sha-keys.sh, whose inline-SHA scan reads only <workflows-dir>.
#
# Usage: pin-uses-from-lock.sh [--write] [<workflows-dir>]
#   <workflows-dir> defaults to .github/workflows and must hold actions.lock.
set -euo pipefail

WRITE=0
WF_DIR=".github/workflows"
while (($#)); do
  case "$1" in
    --write) WRITE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    -*) echo "pin-uses-from-lock: unknown option: $1" >&2; exit 2 ;;
    *) WF_DIR="$1"; shift ;;
  esac
done

LOCK="$WF_DIR/actions.lock"
if [[ ! -f "$LOCK" ]]; then
  echo "pin-uses-from-lock: no lock at $LOCK" >&2
  exit 1
fi

# The lock's dependency records as `key<TAB>sha`. A record is a 4-space
# indented quoted key under `dependencies:`; its `commit:` line follows. A
# record whose commit is not `sha1-<40 hex>` is a structural error: the SHA is
# the one thing this script trusts the lock for.
declare -A SHA_OF=()
records="$(awk '
  /^dependencies:/ { in_deps = 1; next }
  /^[^ ]/          { in_deps = 0 }
  in_deps && /^    '\''[^'\'']+'\'':[[:space:]]*$/ {
    key = $0; sub(/^    '\''/, "", key); sub(/'\'':[[:space:]]*$/, "", key); next
  }
  in_deps && key != "" && /^        commit:/ {
    c = $0; sub(/^        commit:[[:space:]]*/, "", c); gsub(/'\''/, "", c)
    printf "%s\t%s\n", key, c; key = ""
  }
' "$LOCK")"
while IFS=$'\t' read -r key commit; do
  [[ -n "$key" ]] || continue
  if [[ ! "$commit" =~ ^sha1-([0-9a-f]{40})$ ]]; then
    echo "pin-uses-from-lock: $LOCK record $key has commit '$commit', not sha1-<40 hex>" >&2
    exit 1
  fi
  # GitHub owner and repo names are case-insensitive, and gh actions-lock
  # writes keys in lower case (`swatinem/rust-cache` for `Swatinem/rust-cache`).
  # Only owner/repo folds; a ref keeps its case.
  repo_part="${key%%@*}"
  SHA_OF["${repo_part,,}@${key#*@}"]="${BASH_REMATCH[1]}"
done <<<"$records"

# One `uses:` line, split: indent-and-key, quote, owner/repo, path, ref,
# closing quote, trailing text. The ref stops at whitespace, a quote or `#`.
re='^([[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*)(["'\'']?)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/[^@"'\''[:space:]]*)?@([^"'\''[:space:]#]+)(["'\'']?)(.*)$'
sha_re='^[0-9a-f]{40}$'

pinned=0; kept=0; files_changed=0
while IFS= read -r -d '' wf; do
  out="$(mktemp)"
  changed=0; n=0
  # Read every line, including a last line with no newline; remember whether
  # the file ended in one, so the rewrite keeps its final byte.
  ends_nl=0
  [[ ! -s "$wf" ]] || [[ "$(tail -c1 "$wf" | od -An -c | tr -d ' ')" != '\n' ]] || ends_nl=1
  first=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    new="$line"
    if [[ "$line" =~ $re ]]; then
      lead="${BASH_REMATCH[1]}" q="${BASH_REMATCH[3]}" repo="${BASH_REMATCH[4]}"
      path="${BASH_REMATCH[5]}" ref="${BASH_REMATCH[6]}" q2="${BASH_REMATCH[7]}"
      rest="${BASH_REMATCH[8]}"
      verdict="" target="-"
      # shellcheck disable=SC2016 # `${{` below is a GitHub expression, matched literally
      if [[ "$q" != "$q2" ]]; then
        verdict="unlocked"   # unbalanced quotes: not a form this script owns
      elif [[ "$ref" =~ $sha_re ]]; then
        verdict="already-pinned"
      elif [[ "$ref" == *'${{'* || "$rest" == *'${{'* ]]; then
        verdict="expression"
      elif [[ "$rest" =~ ^[[:space:]]*# ]]; then
        verdict="commented"
      elif [[ -n "${SHA_OF["${repo,,}@$ref"]+set}" ]]; then
        verdict="pinned" target="${SHA_OF["${repo,,}@$ref"]}"
        new="${lead}${q}${repo}${path}@${target}${q2} # ${ref}${rest}"
      else
        verdict="unlocked"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "${wf#./}" "$n" "$ref" "$target" "$verdict"
      if [[ "$verdict" == pinned ]]; then pinned=$((pinned + 1)); changed=1; else kept=$((kept + 1)); fi
    fi
    if ((first)); then first=0; else printf '\n' >>"$out"; fi
    printf '%s' "$new" >>"$out"
  done <"$wf"
  ((ends_nl)) && printf '\n' >>"$out"
  if ((changed)); then
    files_changed=$((files_changed + 1))
    if ((WRITE)); then cat "$out" >"$wf"; fi
  fi
  rm -f "$out"
done < <(find "$WF_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

mode="dry run"; ((WRITE)) && mode="written"
echo "pin-uses-from-lock: $pinned uses: pinned in $files_changed file(s) ($mode); $kept left as they are" >&2
