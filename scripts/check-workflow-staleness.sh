#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -eo pipefail

# Staleness checker script for hyperpolymath estate repositories.
#
# Ensures consumer workflows do not use retired patterns or *genuinely* stale
# pins of the standards reusable workflows (governance / hypatia-scan /
# scorecard).
#
# ── Why this is a *window*, not an exact-HEAD match ─────────────────────────
# `standards` hosts reusable workflows that consumer repos pin by full SHA.
# The original gate failed a consumer whenever its pin != standards HEAD. That
# turned every standards commit into a fleet-wide red: HEAD can move several
# times an hour, and each move forced a manual pin bump in every consumer
# (observed live in stapeln — 5a93d9d→d72fe5a→4ddc926 in ~30 min, three
# forced 3-file bumps). The gate became a treadmill instead of a guard.
#
# The fix mirrored the staleness idiom of Hypatia HYP-S006
# `registry-staleness` (retired 2026-10-09), which tolerated drift for
# `stale_after_days` before it escalated. A pin PASSES if it is a genuine
# ancestor of standards HEAD that is *within a recency window* — at most
# STALENESS_WINDOW_COMMITS commits behind HEAD, OR at most
# STALENESS_WINDOW_DAYS days old (union; either qualifies).
#
# ── Why age alone no longer FAILS (2026-07-21) ──────────────────────────────
# The window was still a clock, just a slower one. standards moves ~2.6
# commits/day, so a consumer exhausts both budgets ~14 days after any
# propagation — measured: 294 of 350 consumers red on the single pin d7c22711,
# every one of them green a fortnight earlier, with nothing changed in any
# consumer. Keeping the fleet green would have meant re-pinning ~300 repos
# every fortnight (~7,800 PRs/year). A gate that fails everyone on a timer is
# not a guard; it trains the estate to ignore it, and it buries the findings
# that matter.
#
# So the gate now fails on facts about the pin, never on its age:
#   * KNOWN_BAD_BEFORE — the pin predates the fix for a *named* defect. This is
#     the honest expression of what the window was proxying for, and it is
#     strictly better in both directions: a recent pin carrying the defect is
#     still caught, and an old pin carrying none is not punished by the
#     calendar. The pre-cache-fix Hypatia scanner (#441) is the first entry.
#   * FORGED — the pin is not a commit of this repository reachable from the
#     default branch, confirmed server-side (supply-chain integrity).
#   * the two structural rules (retired scorecard-enforcer; direct consumer
#     Scorecard SARIF publication outside the canonical reusable).
# Age outside the window is reported as a ::notice for the propagation path to
# act on.
#
# Deliberately jumping a consumer to HEAD (e.g. to pick up a fix early) is the
# job of the propagation path — `scripts/propagate-workflow-pins.sh` plus the
# Hypatia `sha_bump_propagation` rule + gitbot-fleet — which opens an
# audit-first bump PR. See
# docs/decisions/ADR-003-workflow-pin-staleness-window.adoc.
#
# Environment knobs (all optional):
#   STALENESS_EXPECTED_SHA    — override the "current" standards HEAD SHA.
#   STALENESS_STANDARDS_DIR   — path to a git checkout carrying standards
#                               history (defaults to this script's own repo;
#                               in CI the governance reusable clones standards
#                               with `--filter=tree:0` so the full commit graph
#                               is available for ancestry/age math).
#   STALENESS_WINDOW_COMMITS  — max commits-behind-HEAD a pin may be (default 50).
#   STALENESS_WINDOW_DAYS     — max age in days a pin may be (default 14, matching
#                               the retired HYP-S006 stale_after_days). Advisory since
#                               2026-07-21: exceeding it emits a notice, not an
#                               error.
#   STALENESS_STANDARDS_NWO   — owner/repo a pin must belong to, used for the
#                               server-side integrity check (default
#                               metadatastician/standards).
#   STALENESS_STANDARDS_BRANCH— branch a pin must be reachable from (default main).
#   STALENESS_API_BASE        — API root for the server-side integrity check
#                               (default https://api.github.com; set for GHES,
#                               or to an unreachable host in tests).
#   STALENESS_KNOWN_BAD_BEFORE— override the known-bad deny-list, as space- or
#                               comma-separated <reusable>:<fix-sha> entries.
#                               "-" disables it. For the hermetic fixture tests
#                               and downstream forks.

REPO_ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WINDOW_COMMITS="${STALENESS_WINDOW_COMMITS:-50}"
WINDOW_DAYS="${STALENESS_WINDOW_DAYS:-14}"

# Where to ask when the local checkout cannot be trusted (see verify-by-API
# below). Overridable so a fork can point the gate at its own standards.
STANDARDS_NWO="${STALENESS_STANDARDS_NWO:-metadatastician/standards}"
STANDARDS_BRANCH="${STALENESS_STANDARDS_BRANCH:-main}"
STANDARDS_API="${STALENESS_API_BASE:-https://api.github.com}"

# ── Known-bad pins: hard fail regardless of age ─────────────────────────────
# A recency *window* is only a proxy for "this pin might contain a known
# defect". Where the defect is actually known, say so directly: name the commit
# that fixed it and reject anything strictly older. This is both stricter (a
# recent pin carrying the defect is still caught) and kinder (an old pin
# without it is not punished for the calendar).
#
# Each entry is <reusable-filename>:<fix-sha>.
#
#   e9c8888769a7 (2026-06-27, #441) — before this commit, hypatia-scan-reusable
#   and the validate-hypatia-baseline job in governance-reusable both cached the
#   built Hypatia scanner under the keyless key
#   `hypatia-scanner-v2-${{ runner.os }}-build`, while the clone/build steps
#   were guarded by `if [ ! -d ]` / `if [ ! -x ]`. The FIRST scanner build ever
#   cached was therefore restored and reused forever and scanner fixes never
#   took effect in CI. A pin older than this runs a frozen scanner and reports
#   a FALSE GREEN — the one failure mode this estate cannot tolerate. Such a
#   pin must be refreshed; it cannot be waited out.
KNOWN_BAD_BEFORE=(
  "hypatia-scan-reusable.yml:e9c8888769a703924cc3c0d717900960d78aea00"
  "governance-reusable.yml:e9c8888769a703924cc3c0d717900960d78aea00"
)
# Overridable (space- or comma-separated <reusable>:<fix-sha>) so the hermetic
# regression fixture and downstream forks can exercise this list without
# depending on real standards SHAs. Set to a single "-" to disable.
if [ -n "${STALENESS_KNOWN_BAD_BEFORE:-}" ]; then
  if [ "$STALENESS_KNOWN_BAD_BEFORE" = "-" ]; then
    KNOWN_BAD_BEFORE=()
  else
    IFS=', ' read -r -a KNOWN_BAD_BEFORE <<< "$STALENESS_KNOWN_BAD_BEFORE"
  fi
fi

# The standards reusables a consumer pins by SHA. The set is intentionally the
# trio named in the governance contract; extend here if a new reusable joins
# the freshness gate. Commented-out `uses:` examples are skipped (see below).
STANDARDS_REUSABLES=(
  "governance-reusable.yml"
  "hypatia-scan-reusable.yml"
  "scorecard-reusable.yml"
)

# Determine if we are in standards repo. The repository was transferred
# hyperpolymath -> metadatastician (measured 2026-10-25: with only the old
# slug recognised, the canon failed its own consumer rules — its canonical
# scorecard-reusable.yml read as a "consumer-owned direct SARIF publisher"
# and its template scorecard-enforcer.yml as a retired consumer file).
#
# Identity is accepted only from signals the candidate tree cannot mint:
# GitHub's immutable repository ID (both slugs resolved to 1116521501 on
# 2026-10-25; it survives transfer/rename), either exact platform slug, or
# the checkout origin with a real owner boundary. Files in the candidate —
# including a deed that recites the canon's identity — are never evidence:
# a consumer can copy them, and IS_STANDARDS disables consumer-only rules
# below, so file presence/content would be a self-granted exemption.
IS_STANDARDS=false
case "${GITHUB_SERVER_URL:-https://github.com}" in
  https://github.com)
    if [ "${GITHUB_REPOSITORY_ID:-}" = "1116521501" ]; then
      IS_STANDARDS=true
    fi
    ;;
esac
case "${GITHUB_REPOSITORY:-}" in
  hyperpolymath/standards|metadatastician/standards) IS_STANDARDS=true ;;
esac
if [ "$IS_STANDARDS" = "false" ]; then
  REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
  if [[ "$REMOTE_URL" =~ ^((git@github\.com:)|(ssh://git@github\.com/)|(https?://github\.com/))(hyperpolymath|metadatastician)/standards(\.git)?$ ]]; then
    IS_STANDARDS=true
  fi
fi
for standards_repo in hyperpolymath/standards metadatastician/standards; do
  if [ "${GITHUB_REPOSITORY:-}" = "$standards_repo" ]; then
    IS_STANDARDS=true
    break
  fi
  # Local runs have no Actions context. Match complete HTTPS/SSH origins so a
  # consumer named standards-something cannot inherit the canonical exemption.
  case "$REMOTE_URL" in
    "https://github.com/$standards_repo" | "https://github.com/$standards_repo.git" | \
    "git@github.com:$standards_repo" | "git@github.com:$standards_repo.git" | \
    "ssh://git@github.com/$standards_repo" | "ssh://git@github.com/$standards_repo.git")
      IS_STANDARDS=true
      break
      ;;
  esac
done

# ── Locate a git checkout that carries standards history ────────────────────
# We need the commit graph (not just HEAD) to answer "is this pin an ancestor
# of HEAD, and how far behind / how old is it".
STANDARDS_DIR="${STALENESS_STANDARDS_DIR:-}"
if [ -z "$STANDARDS_DIR" ]; then
  if git -C "$SCRIPT_DIR/.." rev-parse --git-dir >/dev/null 2>&1; then
    STANDARDS_DIR="$SCRIPT_DIR/.."
  elif git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    STANDARDS_DIR="$SCRIPT_DIR"
  fi
fi

HAVE_HISTORY=false
if [ -n "$STANDARDS_DIR" ] && git -C "$STANDARDS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  HAVE_HISTORY=true
fi

# ── Determine current approved standards SHA ────────────────────────────────
CURRENT_SHA="${STALENESS_EXPECTED_SHA:-}"
if [ -z "$CURRENT_SHA" ] && [ "$HAVE_HISTORY" = true ]; then
  CURRENT_SHA=$(git -C "$STANDARDS_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

if [ -z "$CURRENT_SHA" ]; then
  echo "::error::Could not determine current standards SHA. Set STALENESS_EXPECTED_SHA."
  exit 1
fi

echo "Staleness Check against Standards SHA: $CURRENT_SHA"
echo "Recency window: <= ${WINDOW_COMMITS} commits behind HEAD OR <= ${WINDOW_DAYS} days old."

# If no root .github/workflows exists, pass.
if [ ! -d "$REPO_ROOT/.github/workflows" ]; then
  echo "No .github/workflows directory found. Passing."
  exit 0
fi

FAILED=0

# ── Helpers for the recency-window check ────────────────────────────────────

# Ensure the standards checkout contains a given commit; best-effort fetch if
# not (handles partial clones). Returns 0 if the commit is present afterwards.
ensure_commit() {
  local sha="$1"
  git -C "$STANDARDS_DIR" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  git -C "$STANDARDS_DIR" fetch -q origin "$sha" 2>/dev/null || true
  git -C "$STANDARDS_DIR" cat-file -e "${sha}^{commit}" 2>/dev/null
}

# ── Verify a pin against the server, not the runner's clone ─────────────────
# MEASURED (2026-07-21): the local `merge-base --is-ancestor` path deterministic-
# ally mis-classified legitimate pins as forged in CI. hyperpolymath/awesome-
# haskell pins governance-reusable@5a93d9d57cc0 and was told "not a recognised
# ancestor ... may be forged" on four consecutive runs over 17 days, while that
# same commit verifies as a true ancestor of main both locally (treeless AND
# --depth 200 clones) and via the API (behind=0, ahead=90). The mechanism was
# never reproduced off-runner.
#
# Rather than depend on the clone being intact for a *security* verdict, ask
# GitHub. The compare endpoint is authoritative and immune to whatever degrades
# the runner's clone (partial-clone promisor failure, the --depth 200 fallback,
# runner git version).
#
# Cost: zero calls on the happy path. This is consulted only when we are about
# to accuse a pin of being forged — so the unauthenticated 60/hr limit is not a
# concern. (The staleness job is given no token, so auth is best-effort.)
# Is the local standards checkout complete enough for its *negative* answers to
# be trusted? A shallow or partial clone can fail to resolve or relate a commit
# for reasons that have nothing to do with that commit's legitimacy, and a
# hard failure must never rest on that. A complete clone's "no" is final.
clone_is_complete() {
  [ "$HAVE_HISTORY" = true ] || return 1
  local gd
  # --absolute-git-dir, not --git-dir: the latter returns a path relative to the
  # CWD, which here is the *consumer's* checkout. actions/checkout is shallow by
  # default, so a relative ".git/shallow" test would see the consumer's marker
  # and call every standards clone incomplete.
  gd=$(git -C "$STANDARDS_DIR" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -e "$gd/shallow" ] && return 1
  [ -n "$(git -C "$STANDARDS_DIR" config --get remote.origin.partialclonefilter 2>/dev/null)" ] && return 1
  [ "$(git -C "$STANDARDS_DIR" config --get remote.origin.promisor 2>/dev/null)" = "true" ] && return 1
  return 0
}

# Decide a pin the local clone could not vouch for. Trust a complete clone's
# negative; otherwise get a second opinion from the server before accusing.
resolve_negative() {
  local pin="$1"
  if clone_is_complete; then
    echo "FORGED"
  else
    classify_via_api "$pin"
  fi
}

# api_compare <base> [head]   (head defaults to the standards default branch)
api_compare() {
  local pin="$1" head="${2:-$STANDARDS_BRANCH}" url body code st ahead behind
  command -v curl >/dev/null 2>&1 || return 1
  url="${STANDARDS_API}/repos/${STANDARDS_NWO}/compare/${pin}...${head}"
  local -a auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  body=$(curl -sS --max-time 20 -w '\n%{http_code}' \
           -H 'Accept: application/vnd.github+json' \
           "${auth[@]}" "$url" 2>/dev/null) || return 1
  code=$(printf '%s\n' "$body" | tail -n1)
  body=$(printf '%s\n' "$body" | sed '$d')
  case "$code" in
    200) ;;
    404|422) echo "NOTFOUND 0 0"; return 0 ;;   # SHA not in this repository
    *)   return 1 ;;                            # rate limited / offline / 5xx
  esac
  # `status` describes head (main) relative to base (the pin):
  #   identical | ahead (main ahead => pin IS an ancestor) | behind | diverged
  st=$(printf '%s' "$body" | grep -o '"status"[[:space:]]*:[[:space:]]*"[a-z]*"' | head -n1 | sed 's/.*"\([a-z]*\)"$/\1/')
  ahead=$(printf '%s' "$body" | grep -o '"ahead_by"[[:space:]]*:[[:space:]]*[0-9]*'  | head -n1 | grep -o '[0-9]*$')
  behind=$(printf '%s' "$body" | grep -o '"behind_by"[[:space:]]*:[[:space:]]*[0-9]*' | head -n1 | grep -o '[0-9]*$')
  [ -n "$st" ] || return 1
  echo "$st ${ahead:-0} ${behind:-0}"
}

# Second opinion for a pin the local clone could not vouch for. Echoes the same
# verdict vocabulary as classify_pin. FORGED is the only hard-fail outcome;
# "we could not check" is deliberately NOT an accusation.
classify_via_api() {
  local pin="$1" out st ahead
  out=$(api_compare "$pin") || { echo "UNVERIFIABLE"; return; }
  # shellcheck disable=SC2086
  set -- $out; st="$1"; ahead="$2"
  case "$st" in
    NOTFOUND|diverged) echo "FORGED" ;;
    identical)         echo "FRESH" ;;
    behind)            echo "AHEAD" ;;
    ahead)
      # main is $ahead commits ahead of the pin => the pin is a real ancestor.
      # Age is unavailable by this route; the window is advisory now, so '?'
      # is honest rather than a fabricated number.
      if [ "$ahead" -le "$WINDOW_COMMITS" ]; then echo "IN_WINDOW $ahead ?"
      else echo "OUT_OF_WINDOW $ahead ?"; fi ;;
    *) echo "UNVERIFIABLE" ;;
  esac
}

# Does this pin predate the fix for a known false-green defect in this
# reusable? Returns 0 (yes, reject) only when we can prove it; an unresolvable
# pin is never accused here.
pin_is_known_bad() {
  local reusable="$1" pin="$2" entry fixsha pin_full fix_full out st
  KNOWN_BAD_UNCHECKED=""
  for entry in "${KNOWN_BAD_BEFORE[@]}"; do
    [ "${entry%%:*}" = "$reusable" ] || continue
    fixsha="${entry#*:}"

    # Preferred: decide locally, no network.
    if [ "$HAVE_HISTORY" = true ] && ensure_commit "$pin" && ensure_commit "$fixsha"; then
      pin_full=$(git -C "$STANDARDS_DIR" rev-parse "${pin}^{commit}" 2>/dev/null) || continue
      fix_full=$(git -C "$STANDARDS_DIR" rev-parse "${fixsha}^{commit}" 2>/dev/null) || continue
      [ "$pin_full" = "$fix_full" ] && continue        # the fix itself is fine
      if git -C "$STANDARDS_DIR" merge-base --is-ancestor "$pin_full" "$fix_full" 2>/dev/null; then
        KNOWN_BAD_FIX="$fix_full"
        return 0
      fi
      # Local says "not affected". A local POSITIVE is trustworthy (no false
      # positives observed), but a local NEGATIVE here is a FALSE GREEN — the
      # exact failure this list exists to prevent — and the same
      # `merge-base --is-ancestor` call is measured unreliable on the partial
      # clone CI actually uses. Trust the negative only from a complete clone;
      # otherwise fall through and confirm with the server.
      clone_is_complete && continue
    fi

    # Degraded clone: ask the server rather than skip. A check that quietly
    # stops checking when the runner is unhealthy is a fake gate — the very
    # class of defect this deny-list exists to catch.
    if out=$(api_compare "$pin" "$fixsha"); then
      # shellcheck disable=SC2086
      set -- $out; st="$1"
      if [ "$st" = "ahead" ]; then                     # fix is ahead of pin
        KNOWN_BAD_FIX="$fixsha"
        return 0
      fi
      continue
    fi

    # Neither route available: say so out loud (handled by the caller).
    KNOWN_BAD_UNCHECKED="$fixsha"
  done
  return 1
}

# Classify a pin relative to CURRENT_SHA. Echoes one of:
#   FRESH | AHEAD | IN_WINDOW <behind> <age_days> | OUT_OF_WINDOW <behind> <age_days> | UNKNOWN
classify_pin() {
  local pin="$1"

  # Degraded mode: no standards history available. Previously this meant
  # "exact match or you are forged", which turned a broken clone into a
  # supply-chain accusation. Ask the server instead.
  if [ "$HAVE_HISTORY" != true ]; then
    [ "$pin" = "$CURRENT_SHA" ] && echo "FRESH" || classify_via_api "$pin"
    return
  fi

  if ! ensure_commit "$pin"; then
    resolve_negative "$pin"
    return
  fi

  # Normalise to full SHAs for equality / date lookups.
  local pin_full head_full
  pin_full=$(git -C "$STANDARDS_DIR" rev-parse "${pin}^{commit}" 2>/dev/null || echo "$pin")
  head_full=$(git -C "$STANDARDS_DIR" rev-parse "${CURRENT_SHA}^{commit}" 2>/dev/null || echo "$CURRENT_SHA")

  if [ "$pin_full" = "$head_full" ]; then
    echo "FRESH"
    return
  fi

  # Consumer pinned a commit that HEAD is an ancestor of => consumer is ahead
  # of the gate's view of standards (e.g. a race during a HEAD move). Not stale.
  if git -C "$STANDARDS_DIR" merge-base --is-ancestor "$head_full" "$pin_full" 2>/dev/null; then
    echo "AHEAD"
    return
  fi

  # Pin behind HEAD: must be a genuine ancestor on standards' mainline.
  if git -C "$STANDARDS_DIR" merge-base --is-ancestor "$pin_full" "$head_full" 2>/dev/null; then
    local behind pin_ts now_ts age_days
    behind=$(git -C "$STANDARDS_DIR" rev-list --count "${pin_full}..${head_full}" 2>/dev/null || echo 999999)
    pin_ts=$(git -C "$STANDARDS_DIR" log -1 --format=%ct "$pin_full" 2>/dev/null || echo 0)
    now_ts=$(date -u +%s)
    if [ "$pin_ts" -gt 0 ]; then
      age_days=$(( (now_ts - pin_ts) / 86400 ))
    else
      age_days=999999
    fi
    if [ "$behind" -le "$WINDOW_COMMITS" ] || [ "$age_days" -le "$WINDOW_DAYS" ]; then
      echo "IN_WINDOW $behind $age_days"
    else
      echo "OUT_OF_WINDOW $behind $age_days"
    fi
    return
  fi

  # The local clone says this pin is neither ancestor nor descendant of HEAD.
  # That is the forgery signal — and precisely the verdict measured to fire on
  # legitimate pins. Never accuse on a degraded clone's word alone.
  resolve_negative "$pin"
}

# Apply the freshness verdict for one reusable pin found in one workflow file.
check_reusable_pin() {
  local wf="$1" reusable="$2" pin="$3"
  local verdict behind age

  # A named defect outranks the calendar: check it first and independently of
  # how fresh the pin looks. This is the only age-related hard failure.
  KNOWN_BAD_FIX=""; KNOWN_BAD_UNCHECKED=""
  if pin_is_known_bad "$reusable" "$pin"; then
    echo "::error file=$wf::${reusable} pin ${pin:0:12} predates ${KNOWN_BAD_FIX:0:12} and carries the frozen-Hypatia-scanner-cache defect (#441): the first scanner build ever cached is restored forever, so scanner fixes never take effect and the scan reports a FALSE GREEN. Refresh this pin — waiting will not fix it (scripts/propagate-workflow-pins.sh)."
    FAILED=1
    return
  fi
  if [ -n "$KNOWN_BAD_UNCHECKED" ]; then
    echo "::warning file=$wf::${reusable} pin ${pin:0:12} could not be checked against the known-bad list (local standards history unavailable and the compare API unreachable). This check was SKIPPED, not passed."
  fi

  read -r verdict behind age < <(classify_pin "$pin")

  case "$verdict" in
    FRESH|AHEAD)
      ;; # current (or ahead) — nothing to do
    IN_WINDOW)
      # Non-failing nudge: within the grace window, but a deliberate bump is
      # available via the propagation path.
      echo "::notice file=$wf::${reusable} pin ${pin:0:12} is ${behind} commit(s) / ${age}d behind standards HEAD — within the recency window (<=${WINDOW_COMMITS} commits or <=${WINDOW_DAYS}d). Bump deliberately with scripts/propagate-workflow-pins.sh when convenient."
      ;;
    OUT_OF_WINDOW)
      # Advisory, NOT a failure. Age alone is not a defect, and making it one
      # made the gate a clock: standards moves ~2.6 commits/day, so every
      # consumer went red ~14 days after each propagation whether or not
      # anything was wrong with it (measured 2026-07-21: 294 of 350 consumers
      # red on one pin, all of them green a fortnight earlier). A gate that
      # fails the whole fleet on a timer teaches everyone to ignore it. Real
      # defects are named in KNOWN_BAD_BEFORE above and still hard-fail.
      echo "::notice file=$wf::${reusable} pin ${pin:0:12} is ${behind} commit(s) / ${age}d behind standards HEAD — outside the recency window (>${WINDOW_COMMITS} commits AND >${WINDOW_DAYS}d). Advisory only: no known defect is attached to this pin. Refresh toward ${CURRENT_SHA:0:12} with scripts/propagate-workflow-pins.sh."
      ;;
    FORGED)
      echo "::error file=$wf::${reusable} pin ${pin:0:12} is not a commit of ${STANDARDS_NWO} reachable from ${STANDARDS_BRANCH} (confirmed against the GitHub compare API, not just this runner's clone). It may be forged, from a fork, or from rewritten history. Pin a published standards commit."
      FAILED=1
      ;;
    UNVERIFIABLE|*)
      # Could not reach a verdict: the clone is degraded AND the API was
      # unreachable or rate-limited. "Cannot verify" is not "compromised" —
      # warn loudly, do not fail. Failing here is what produced four
      # consecutive false forgery accusations against awesome-haskell.
      echo "::warning file=$wf::${reusable} pin ${pin:0:12} could not be verified against ${STANDARDS_NWO} (local clone degraded and the compare API was unreachable). Not treated as a failure; re-run to re-check."
      ;;
  esac
}

# Rule: no_retired_scorecard_enforcer
if [ "$IS_STANDARDS" = "false" ] && [ -f "$REPO_ROOT/.github/workflows/scorecard-enforcer.yml" ]; then
  echo "::error::scorecard-enforcer.yml is retired. Use scorecard.yml -> standards scorecard-reusable.yml instead."
  FAILED=1
fi

for wf in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
  [ -f "$wf" ] || continue

  # Rule: no direct consumer-owned Scorecard SARIF publisher. The canonical
  # reusable in standards owns publication so alert delivery and policy can be
  # repaired once rather than drifting across the estate.
  if [ "$IS_STANDARDS" = "false" ] && \
     grep -q "ossf/scorecard-action@" "$wf" && \
     grep -q "github/codeql-action/upload-sarif@" "$wf"; then
    echo "::error file=$wf::Direct Scorecard SARIF publication is retired. Call standards/scorecard-reusable.yml so publication policy remains centrally controlled."
    FAILED=1
  fi

  # Rule: recency-window freshness for each standards reusable pin.
  for reusable in "${STANDARDS_REUSABLES[@]}"; do
    # Active (non-comment) `uses:` lines that pin this reusable by SHA.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pin=$(printf '%s\n' "$line" | sed -E "s#.*${reusable}@([0-9a-fA-F]{7,40}).*#\1#")
      [ -n "$pin" ] || continue
      check_reusable_pin "$wf" "$reusable" "$pin"
    done < <(grep -E "${reusable}@[0-9a-fA-F]{7,40}" "$wf" 2>/dev/null | grep -v '^[[:space:]]*#')
  done
done

if [ $FAILED -ne 0 ]; then
  echo "::error::Staleness gate failed. Each error above names a specific defect: a pin predating a known false-green fix (refresh it — waiting will not help), a pin that is not a published standards commit, a retired scorecard-enforcer.yml, or a consumer-owned direct Scorecard SARIF publisher. Pins that are merely old are reported as notices and do not fail."
  exit 1
fi

echo "All workflow staleness checks passed."
exit 0
