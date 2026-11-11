#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pin-ancestry.sh — the ONE ancestry assertion every pin bumper calls
# (owner ruling D5c, standards#787; mandatory under D19a).
#
# Source it; do not execute it:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/pin-ancestry.sh"
#   assert_pin_ancestry metadatastician/standards "$sha" || exit 1
#
# WHY: a pin can be a real commit that GitHub still refuses to run. A PR head
# that is later squash-merged, or a commit on a deleted unmerged branch, is an
# ancestor of nothing; `commits/<sha>` still answers 200, but a cross-repo
# reusable-workflow ref at that SHA dies at graph resolution (standards#782:
# 61 dead rows, 0 alive). Squash is the estate's only merge method (D19a), so
# every bumper that may be handed a PR head must prove ancestry before writing.
#
# PREDICATE: compare/<sha>...<branch> on the server.
#   identical | ahead   → <sha> is an ancestor of <branch>       → rc 0
#   behind | diverged   → NOT an ancestor; never pin it          → rc 1
#   not hex / not 40    → refuse; abbreviated SHAs are prefix
#                         queries, not existence tests            → rc 1
#   no/unknown answer   → indeterminate; callers must refuse too  → rc 2
# The comparison is server-side on purpose: `git merge-base --is-ancestor` in a
# shallow or partial clone reports false negatives (standards#782). A caller
# may try a full local clone first, but only this function may say "no" from
# incomplete local evidence.
#
# ENVIRONMENT
#   STANDARDS_REACHABILITY_API_BASE  API root (default https://api.github.com);
#                                    tests point it at an unreachable port.
#   GITHUB_TOKEN / GH_TOKEN          bearer token; else `gh auth token` if gh
#                                    is logged in; else unauthenticated.

# pin_ancestry_log <msg> — write one diagnostic line to stderr.
pin_ancestry_log() { printf '%s\n' "$*" >&2; }

# pin_ancestry_token — print the bearer token to use, or nothing.
pin_ancestry_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"
  elif command -v gh >/dev/null 2>&1; then gh auth token 2>/dev/null || true
  fi
}

# assert_pin_ancestry <owner/repo> <sha> [branch]
# Succeed only if <sha> is a full 40-hex commit that is an ancestor of
# <branch> (default: main) in <owner/repo>. Returns 0 ancestor, 1 not an
# ancestor or malformed, 2 indeterminate. Logs the reason on any refusal.
assert_pin_ancestry() {
  local repo="$1" sha="$2" branch="${3:-main}"
  if ! [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    pin_ancestry_log "ERROR: pin must be a full 40-character hex commit SHA, got '${sha}'; refusing."
    return 1
  fi

  local api="${STANDARDS_REACHABILITY_API_BASE:-https://api.github.com}"
  local token body status
  local -a auth=()
  token="$(pin_ancestry_token)"
  [ -n "$token" ] && auth=(-H "Authorization: Bearer ${token}")

  if ! body=$(curl -fsS --max-time 20 \
      -H 'Accept: application/vnd.github+json' \
      "${auth[@]}" \
      "$api/repos/${repo}/compare/${sha}...${branch}" 2>/dev/null); then
    pin_ancestry_log "ERROR: could not prove ${sha} is an ancestor of ${repo}@${branch} (compare request failed); refusing."
    return 2
  fi

  # The top-level "status" precedes the commits/files arrays, whose entries
  # carry their own "status" ("modified", …). GitHub pretty-prints this body
  # today, but compact JSON puts them all on one line, where a greedy
  # `sed 's/.*"status"…/'` takes the LAST one. bash =~ takes the leftmost in
  # either layout, and needs no pipe that could SIGPIPE on a large body.
  status=""
  local re='"status"[[:space:]]*:[[:space:]]*"([a-z]+)"'
  [[ "$body" =~ $re ]] && status="${BASH_REMATCH[1]}"
  case "$status" in
    identical|ahead) return 0 ;;
    behind|diverged)
      pin_ancestry_log "ERROR: ${sha} is NOT an ancestor of ${repo}@${branch} (compare status: ${status}). Repin to the merge commit, never a PR head; refusing."
      return 1 ;;
    *)
      pin_ancestry_log "ERROR: could not prove ${sha} is an ancestor of ${repo}@${branch} (compare status: ${status:-none}); refusing."
      return 2 ;;
  esac
}
