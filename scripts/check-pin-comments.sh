#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# check-pin-comments.sh — the `# <ref>` comment on a SHA-pinned `uses:` must
# agree with the reviewed ref actions.lock records for that pin (standards#1440).
#
# Usage: check-pin-comments.sh [WORKFLOW_DIR] [LOCKFILE]
#   WORKFLOW_DIR  default .github/workflows
#   LOCKFILE      default WORKFLOW_DIR/actions.lock
# Exit: 0 every judged comment agrees · 1 at least one disagrees · 2 usage,
#       missing tool, or a file yq cannot parse (never a pass).
#
# WHY. The trailing comment is load-bearing (YAML-POLICY §2.1): Dependabot
# reads it to bump the pin, and scripts/close-lock.sh reads it as its
# last-resort source for a leaf's `ref:` when no current tag names the pin
# (#1323). MEASURED 2026-11-09: six `dtolnay/rust-toolchain@683b588… # stable`
# pins, where 683b588 is the tag v1 and `stable` is a branch at another commit,
# so the comment named something that cannot resolve to the pin. The same scan
# found `actions/checkout@3d3c42e5… # v4` on a commit the lock reviewed as
# v7.0.1.
#
# THE RULE, offline. The lock's `dependencies['owner/repo@<sha>'].ref` is the
# ref gh actions-lock resolved for the pin, i.e. a tag that names the commit.
# The comment's first word C agrees with that reviewed ref R when
#   C == R                     (v7.0.1 for v7.0.1), or
#   R starts with "C."         (v2 for v2.9.3: the major/minor tag of the
#                               same release line, which close-lock's
#                               moved_tag accepts as descending from the pin).
# Anything else (a branch name, another major, a different release) disagrees.
#
# NOT JUDGED, and counted so a green says what it covered:
#   * a pin with no comment (it makes no claim);
#   * a pin with no lock record, or whose record's ref repeats the SHA (a
#     caller-side reusable-workflow edge, check-lock-pin-contract.sh's case);
#   * a comment in a KYAML flow mapping, which yq attaches to the enclosing
#     collection rather than to the `uses` scalar — it reads as no comment.
# Whether the tag still resolves upstream is a network question, answered by
# close-lock.sh and check-action-pins-resolve.sh, not here.
set -euo pipefail

workflows=${1:-.github/workflows}
lock=${2:-$workflows/actions.lock}
yq_bin=${YQ_BIN:-yq}

[ -d "$workflows" ] || { echo "check-pin-comments: missing workflow directory: $workflows" >&2; exit 2; }
[ -f "$lock" ] || { echo "check-pin-comments: missing lockfile: $lock" >&2; exit 2; }
"$yq_bin" --version 2>/dev/null | grep -q 'mikefarah' \
  || { echo "check-pin-comments: mikefarah yq v4 is required (YQ_BIN=$yq_bin)" >&2; exit 2; }

# owner/repo@sha (lower-cased) -> reviewed ref, one per line.
if ! locked="$("$yq_bin" -r '.dependencies // {} | to_entries[] | [(.key | downcase), (.value.ref // "" | tostring)] | @tsv' "$lock")"; then
  echo "check-pin-comments: cannot read $lock" >&2; exit 2
fi

files=0 pins=0 judged=0 uncommented=0 unrecorded=0 bad=0
while IFS= read -r -d '' wf; do
  files=$((files + 1))
  if ! rows="$("$yq_bin" -r '.. | select(tag == "!!map") | select(has("uses")) | .uses | select(tag == "!!str") | [., (line_comment | split(" ") | map(select(. != "")) | .[0] // "")] | @tsv' "$wf")"; then
    echo "check-pin-comments: cannot parse $wf" >&2; exit 2
  fi
  while IFS=$'\t' read -r ref comment; do
    [[ "$ref" =~ ^([^/@]+)/([^/@]+)(/[^@]*)?@([0-9a-fA-F]{40})$ ]] || continue
    pins=$((pins + 1))
    key="$(printf '%s/%s@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" | tr '[:upper:]' '[:lower:]')"
    sha="${BASH_REMATCH[4],,}"
    word="${comment%%[[:space:]]*}"
    if [ -z "$word" ]; then uncommented=$((uncommented + 1)); continue; fi
    reviewed="$(printf '%s\n' "$locked" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')"
    if [ -z "$reviewed" ] || [ "${reviewed,,}" = "$sha" ]; then
      unrecorded=$((unrecorded + 1)); continue
    fi
    judged=$((judged + 1))
    if [ "$word" = "$reviewed" ] || [ "${reviewed#"$word".}" != "$reviewed" ]; then
      continue
    fi
    echo "$wf: uses: $ref # $comment — the lock reviewed this pin as '$reviewed'; '$word' does not name it. Write '# $reviewed'." >&2
    bad=$((bad + 1))
  done <<< "$rows"
done < <(find "$workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

[ "$files" -gt 0 ] || { echo "check-pin-comments: no workflow YAML in $workflows" >&2; exit 2; }
summary="$pins SHA pin(s) in $files workflow(s): $judged judged, $uncommented without a comment, $unrecorded without a reviewed lock ref"
if [ "$bad" -gt 0 ]; then
  echo "check-pin-comments: $bad pin comment(s) disagree with actions.lock ($summary)" >&2
  exit 1
fi
echo "OK: pin comments agree with actions.lock ($summary)"
