#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# estate-trusted-base-survey.sh — measure a marker set across every repository
# that calls the governance bundle, BEFORE any marker is enforced.
#
# WHY THIS EXISTS
# ---------------
# scripts/check-trusted-base.sh gained a widened marker set (2026-10-30) that
# can be enforced in three modes: report, budget, strict. Deciding which mode a
# repository should carry — and what number its budget should start at — is a
# measurement question, not an opinion. This script performs the measurement.
#
# The order is deliberate and is the order docs/CICD-SIGNAL-DISCIPLINE.adoc
# prescribes for any estate-wide change:
#
#   1. census          — who calls governance?
#   2. difference      — which callers carry which markers, and how many?
#   3. publish         — the hit list, as a reviewable artefact
#   4. only then       — enforcement, per repository, at a measured number.
#
# Skipping step 3 is how a gate gets red-boarded: a marker that is a soundness
# hole in one proof development is a documented, defended choice in another,
# and the cheapest way to survive a red board is to add an ignore path — which
# destroys the signal the gate existed to create.
#
# TOKEN SCOPE — READ THIS BEFORE BLAMING THE SCRIPT
# -------------------------------------------------
# GitHub's code-search API is scoped to what the TOKEN can read. A fine-grained
# app token granted one repository can survey exactly one repository, and its
# zero results are indistinguishable from a real zero. This script therefore
# probes scope first and refuses to publish a hit list it cannot stand behind:
#
#   * it lists the repositories visible to the token;
#   * it counts the governance callers it can see;
#   * if either count is 1 while `--owner` names an owner with more than one
#     repository, it prints NEEDS-SCOPE and exits 2 rather than producing a
#     hit list that looks like a clean bill of health.
#
# Use a user token with `repo` scope (classic) or a fine-grained token with
# read access to the whole estate. Nothing here writes to GitHub: one-shot
# GETs and local files only.
#
# USAGE
#   bash scripts/estate-trusted-base-survey.sh --owner <login> [options]
#
#   --owner <login>       owner to survey (repeatable). Default: hyperpolymath
#   --out <dir>           output directory. Default: out/trusted-base-survey
#   --markers <set>       core | extended | all (default: all)
#   --max-pages <n>       page cap per code-search query (default: 10 = 1000
#                         results). A query that hits the cap is recorded as
#                         TRUNCATED, never as complete.
#   --sleep <seconds>     pause between code-search calls (default: 7; the
#                         code-search limit is 10 requests/minute)
#   --pins                additionally census caller pins of the standards
#                         reusable workflows. SLOW: one API call to list a
#                         caller's workflows plus one per workflow, so ~15
#                         minutes per hundred callers. Measured 2026-10-30:
#                         56 of 306 callers took ~7 minutes. Interrupting is
#                         fine — pins.tsv is appended as it goes — but say so
#                         in the report, because a partial census and a complete
#                         one look identical once the file exists.
#   --no-cache            ignore previously cached query responses
#
# OUTPUT (all under --out, newline-delimited, diffable, no Python)
#   repos.tsv        every repository visible to the token
#   callers.tsv      repositories whose workflows reference governance-reusable.yml
#   cache/<slug>.json  raw API response per query (resume without re-querying)
#   hits.tsv         marker<TAB>repo<TAB>path  (callers only)
#   hits-all.tsv     marker<TAB>repo<TAB>path  (every visible repo)
#   counts.tsv       marker<TAB>tier<TAB>result-count<TAB>repos<TAB>truncated
#   pins.tsv         repo<TAB>workflow<TAB>pinned-sha   (only with --pins)
#   HIT-LIST.md      the publishable hit list
#
# EXIT
#   0  survey completed and the hit list is publishable
#   2  environment/scope error — no hit list was produced (or it is marked
#      INCOMPLETE)
#
# Shell + jq + gh only. No Python.

set -uo pipefail

OWNERS=()
OUT="out/trusted-base-survey"
MARKERS="all"
MAX_PAGES=10
NAP=7
DO_PINS=false
CALLERS_FILE=""
USE_CACHE=true

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)      OWNERS+=("${2:?--owner needs a value}"); shift 2 ;;
    --owner=*)    OWNERS+=("${1#*=}"); shift ;;
    --out)        OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)      OUT="${1#*=}"; shift ;;
    --markers)    MARKERS="${2:?--markers needs a value}"; shift 2 ;;
    --markers=*)  MARKERS="${1#*=}"; shift ;;
    --max-pages)  MAX_PAGES="${2:?--max-pages needs a value}"; shift 2 ;;
    --max-pages=*) MAX_PAGES="${1#*=}"; shift ;;
    --sleep)      NAP="${2:?--sleep needs a value}"; shift 2 ;;
    --sleep=*)    NAP="${1#*=}"; shift ;;
    --pins)       DO_PINS=true; shift ;;
    --no-cache)   USE_CACHE=false; shift ;;
    --callers-file) CALLERS_FILE="${2:?--callers-file needs a value}"; shift 2 ;;
    --callers-file=*) CALLERS_FILE="${1#*=}"; shift ;;
    -h|--help)    sed -n '2,80p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ ${#OWNERS[@]} -eq 0 ] && OWNERS=(hyperpolymath)

case "$MARKERS" in core|extended|all) ;; *) echo "ERROR: --markers must be core|extended|all" >&2; exit 2 ;; esac

# Exit with status 2 if the named command is unavailable.
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required" >&2; exit 2; }; }
need gh
need jq
need sort

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPTS_DIR/check-trusted-base.sh"
[ -x "$CHECKER" ] || [ -f "$CHECKER" ] || { echo "ERROR: cannot find $CHECKER" >&2; exit 2; }

mkdir -p "$OUT/cache"
LAST_CODE_SEARCH_FILE="$OUT/cache/.last-search"
echo "[survey] owners: ${OWNERS[*]}"
echo "[survey] output: $OUT"
echo "[survey] markers: $MARKERS"

# ─────────────────────────────────────────────────────────────────────────────
# Marker → code-search query table.
#
# `-` in the query column means "this marker is NOT expressible as a GitHub
# code search". Those rows are still published, because a hit list that omits
# the markers it could not see is a lie by omission. The local checker detects
# them; the survey says so explicitly.
#
# Every query carries `extension:` so that prose about a marker (a proof-debt
# entry, an essay, a scanner's own regex) is not counted as a use of it. The
# first survey attempt without `extension:` returned 3,496 hits for
# `believe_me`, of which the majority were documentation *about* believe_me.
# ─────────────────────────────────────────────────────────────────────────────
MARKER_TABLE=$(cat <<'TABLE'
# id<TAB>tier<TAB>query<TAB>extension
# An id may appear on several rows: a marker with more than one spelling needs
# more than one query (GitHub code search has no OR), and the counts step below
# groups the rows back together. This table is keyed to the catalogue ids that
# `check-trusted-base.sh --list-markers` prints — not to a private naming
# scheme — and step 0 refuses to survey if an id is missing from it.
coq-axiom-or-admit	core	Axiom	extension:v
coq-axiom-or-admit	core	Admitted	extension:v
coq-axiom-or-admit	core	admit.	extension:v
coq-parameter-or-conjecture	extended	Parameter	extension:v
coq-parameter-or-conjecture	extended	Conjecture	extension:v
coq-admit-tactic	extended	admit	extension:v
coq-admit-tactic	extended	give_up	extension:v
lean-sorry-or-axiom	core	sorry	extension:lean
lean-sorry-or-axiom	core	axiom	extension:lean
lean-implemented-by	extended	implemented_by	extension:lean
lean-extern	extended	@[extern	extension:lean
lean-native-decide	extended	native_decide	extension:lean
lean-native-decide	extended	trustCompiler	extension:lean
lean-admit-tactic	extended	admit	extension:lean
lean-unsafe-or-partial-def	extended	unsafe def	extension:lean
lean-unsafe-or-partial-def	extended	partial def	extension:lean
agda-postulate	core	postulate	extension:agda
agda-terminating-pragma	extended	TERMINATING	extension:agda
agda-terminating-pragma	extended	NON_TERMINATING	extension:agda
agda-non-covering-pragma	extended	NON_COVERING	extension:agda
agda-unsound-flag	extended	--type-in-type	extension:agda
agda-unsound-flag	extended	--allow-unsolved-metas	extension:agda
agda-unsound-flag	extended	--no-termination-check	extension:agda
agda-unsound-flag	extended	--no-positivity-check	extension:agda
agda-unsound-flag	extended	--no-coverage-check	extension:agda
agda-unsound-flag	extended	--no-projection-likeness-check	extension:agda
agda-unsound-flag	extended	--no-universe-check	extension:agda
agda-primtrustme	extended	primTrustMe	extension:agda
agda-hole	extended	-	-
idris-believe-or-assert	core	believe_me	extension:idr
idris-believe-or-assert	core	really_believe_me	extension:idr
idris-believe-or-assert	core	assert_total	extension:idr
idris-partial	core	%default partial	extension:idr
idris-hole	extended	-	-
fstar-assume-or-admit	core	assume val	extension:fst
fstar-assume-or-admit	core	admit_p	extension:fst
fstar-assume-or-admit-bare	extended	admit()	extension:fst
dafny-axiom	extended	{:axiom}	extension:dfy
rust-or-hs-unsafe	core	unsafePerformIO	extension:hs
rust-or-hs-unsafe	core	unsafeCoerce	extension:hs
TABLE
)

# ─────────────────────────────────────────────────────────────────────────────
# Step 0: the survey must not silently under-report.
#
# A marker table maintained separately from the checker drifts. It did: the
# first version searched only `type-in-type` for Agda's unsound-flag family and
# omitted Rust/Haskell escapes, F* `admit()`, `unsafe def`/`partial def` and the
# `--no-*-check` flags entirely, so a marker the checker enforces had no survey
# row and no count — an absence indistinguishable from a zero. Any catalogue id
# without a row is a hole in the measurement, so this exits before querying.
# ─────────────────────────────────────────────────────────────────────────────
catalogue_ids=$(bash "$CHECKER" --list-markers 2>/dev/null | cut -f3 | LC_ALL=C sort -u)
if [ -z "$catalogue_ids" ]; then
  echo "ERROR: could not read the marker catalogue from $CHECKER --list-markers" >&2
  exit 2
fi
table_ids=$(printf '%s\n' "$MARKER_TABLE" | grep -v '^#' | grep -v '^$' | cut -f1 | LC_ALL=C sort -u)
uncovered=$(LC_ALL=C comm -23 <(printf '%s\n' "$catalogue_ids") <(printf '%s\n' "$table_ids"))
if [ -n "$uncovered" ]; then
  echo "ERROR: the checker enforces marker(s) this survey never searches:" >&2
  printf '  %s\n' $uncovered >&2
  echo "Add a row per spelling to MARKER_TABLE (id, tier, query, extension)." >&2
  echo "A marker with no survey row counts as zero, which is a claim, not a gap." >&2
  exit 2
fi
stale=$(LC_ALL=C comm -13 <(printf '%s\n' "$catalogue_ids") <(printf '%s\n' "$table_ids"))
if [ -n "$stale" ]; then
  echo "ERROR: MARKER_TABLE names marker(s) the checker does not have:" >&2
  printf '  %s\n' $stale >&2
  echo "Rename or remove them: a survey row that matches nothing reads as zero." >&2
  exit 2
fi

# Return success when the given tier is selected by MARKERS.
want_tier() {
  case "$MARKERS" in
    all) return 0 ;;
    core) [ "$1" = core ] ;;
    extended) [ "$1" = extended ] ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Code-search with cache, pagination, and rate-limit backoff.
# ─────────────────────────────────────────────────────────────────────────────
# The timer lives in a FILE, not a shell variable. `code_search` is always
# called inside `$(...)`, which is a subshell: a variable set in there is lost
# the moment it returns, so `LAST_CODE_SEARCH` reset to 0 for every query and the
# spacing only ever applied BETWEEN PAGES of one query. The marker loop then
# fired one code search after another with no pause, which is how to collect
# secondary-rate-limit errors (they are retried, at 60 s each).
LAST_CODE_SEARCH_FILE=""

# Wait until NAP seconds have elapsed since the recorded search time, when
# LAST_CODE_SEARCH_FILE is set, then update that file.
throttle() {
  local now last elapsed
  now=$(date +%s)
  last=0
  if [ -n "$LAST_CODE_SEARCH_FILE" ] && [ -f "$LAST_CODE_SEARCH_FILE" ]; then
    last=$(cat "$LAST_CODE_SEARCH_FILE" 2>/dev/null || echo 0)
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ]; then
    elapsed=$(( now - last ))
    if [ "$elapsed" -lt "$NAP" ]; then sleep $(( NAP - elapsed )); fi
  fi
  [ -n "$LAST_CODE_SEARCH_FILE" ] && date +%s > "$LAST_CODE_SEARCH_FILE"
}

# Search GitHub for query, using slug for cache filenames. Write repository and
# path pairs as TSV to $OUT/cache/<slug>.items.jsonl. Print a TSV metadata
# record with status, total, fetched count, and query checksum on success or a
# cached failure. Reuse a matching successful cache. Return 3 for a cached
# failure or a failed API request after any rate-limit retry; a new API failure
# is recorded in the cache without printing its metadata record.
code_search() {
  local slug="$1" query="$2"
  local items="$OUT/cache/${slug}.items.jsonl"
  local meta="$OUT/cache/${slug}.meta"

  # The cache key is derived from the query, and the query is recorded in the
  # meta line. A cache keyed on the marker id alone returned the first owner's
  # answer to a later `--owner` run (and a stale definition's answer to a changed
  # query), which is a stale result wearing a fresh timestamp.
  local qhash
  qhash="$(printf '%s' "$query" | cksum | cut -d' ' -f1)"
  if $USE_CACHE && [ -f "$meta" ] && [ -f "$items" ]; then
    local cached_q
    cached_q="$(sed -n 's/.*query=\([0-9]*\).*/\1/p' "$meta" 2>/dev/null | head -1)"
    if [ "$cached_q" = "$qhash" ]; then
      # A recorded FAILURE is not a cache hit. Returning 0 here meant a
      # transient error (rate limit, 5xx, dropped connection) was replayed as a
      # successful answer on every later run until someone removed the file:
      # the cache made an outage permanent.
      if [ "$(sed -n '1s/\t.*//p' "$meta" 2>/dev/null)" = "error" ]; then
        cat "$meta"
        echo "[survey]   cached FAILURE for '$slug'; retrying rather than replaying it" >&2
        return 3
      fi
      cat "$meta"
      return 0
    fi
    echo "[survey]   cache miss (query changed) for '$slug'; re-querying" >&2
  fi

  : > "$items"
  local page=1 total=0 fetched=0
  while [ "$page" -le "$MAX_PAGES" ]; do
    throttle
    local resp rc
    resp=$(gh api -X GET search/code \
              -f q="$query" \
              -f per_page=100 \
              -f page="$page" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # Secondary rate limit / abuse detection: back off once, then fail loudly.
      if printf '%s' "$resp" | grep -qi 'rate limit\|secondary'; then
        echo "[survey]   rate limited on '$slug'; backing off 60s" >&2
        sleep 60
        resp=$(gh api -X GET search/code -f q="$query" -f per_page=100 -f page="$page" 2>&1)
        rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        printf '%s' "$resp" >> "$OUT/cache/${slug}.errors"
        echo "[survey]   QUERY FAILED: $slug ($query)" >&2
        # Return non-zero. A failed query is UNKNOWN, not zero: the caller used
        # to record total=0, publish it, and exit 0, which turns an API failure
        # into the claim "this marker does not occur in the estate". The meta
        # file is still written so the failure is visible on a re-run and is
        # never mistaken for a cached success.
        printf 'error\ttotal=NA\tfetched=0\tquery=%s\n' "$qhash" > "$meta"
        return 3
      fi
    fi
    total=$(printf '%s' "$resp" | jq -r '.total_count // 0')
    local n
    n=$(printf '%s' "$resp" | jq -r '.items | length' 2>/dev/null || echo 0)
    printf '%s' "$resp" | jq -r '.items[]? | [.repository.full_name, .path] | @tsv' >> "$items"
    fetched=$(( fetched + n ))
    [ "$n" -lt 100 ] && break
    [ "$fetched" -ge "$total" ] && break
    [ "$fetched" -ge 1000 ] && break
    page=$(( page + 1 ))
  done

  local status="complete"
  if [ "$fetched" -lt "$total" ] && [ "$fetched" -ge 1000 ]; then
    status="truncated"
  elif [ "$fetched" -lt "$total" ]; then
    status="truncated"
  fi
  printf '%s\ttotal=%s\tfetched=%s\tquery=%s\n' "$status" "$total" "$fetched" "$qhash" > "$meta"
  cat "$meta"
}

echo "[survey] step 1/4 — enumerating repositories for the requested owner(s)"
: > "$OUT/repos.tsv"
# `users/<login>/repos` lists PUBLIC repositories only. For the account the
# token belongs to, `user/repos?affiliation=owner` is the listing that includes
# private ones. Using the public endpoint for your own account makes a
# correct-scope run and a crippled token indistinguishable, and this file is
# described as the repositories the token can see.
me=$(gh api user --jq .login 2>/dev/null || true)
repo_enum_failed=0
for owner in "${OWNERS[@]}"; do
  page=1
  while :; do
    if [ -n "$me" ] && [ "$owner" = "$me" ]; then
      endpoint="user/repos?affiliation=owner&per_page=100&page=$page"
    else
      endpoint="users/$owner/repos?per_page=100&page=$page"
    fi
    if ! resp=$(gh api "$endpoint" 2>&1); then
      echo "[survey] REPO ENUMERATION FAILED for $owner ($endpoint): $(printf '%s' "$resp" | head -c 200)" >&2
      repo_enum_failed=$((repo_enum_failed + 1))
      break
    fi
    n=$(printf '%s' "$resp" | jq -r 'length' 2>/dev/null || echo 0)
    [ "$n" -eq 0 ] && break
    printf '%s' "$resp" | jq -r '.[] | [.full_name, (.archived|tostring), (.fork|tostring)] | @tsv' >> "$OUT/repos.tsv"
    [ "$n" -lt 100 ] && break
    page=$(( page + 1 ))
  done
done
# A user account's repositories may also live under an org listing; dedupe.
LC_ALL=C sort -u -o "$OUT/repos.tsv" "$OUT/repos.tsv" 2>/dev/null || true
repo_total=$(wc -l < "$OUT/repos.tsv" | tr -d ' ')
echo "[survey]   $repo_total repository/ies enumerated"

echo "[survey] step 2/4 — resolving governance callers"
CALLER_STATUS="complete"
caller_fail=0
if [ -n "$CALLERS_FILE" ]; then
  # Ground truth supplied by the caller, e.g. an estate board export or the
  # output of scripts/cicd-census.sh. Preferred over a code search whenever it
  # exists: see the caller-truncation note below.
  cut -f1 "$CALLERS_FILE" | LC_ALL=C sort -u > "$OUT/callers.tsv"
  echo "[survey]   using --callers-file $CALLERS_FILE (ground truth, no code search)"
else
  # Scoped per owner. `governance-reusable.yml` on its own returns every visible
  # repository that mentions the filename — including repositories outside the
  # owner set this run claims to cover. With a token that can read more than one
  # account, callers.tsv (and every count derived from it) silently widened past
  # the report's stated scope.
  : > "$OUT/callers.tsv"
  for owner in "${OWNERS[@]}"; do
    cq="governance-reusable.yml user:$owner"
    slug="governance-callers__$(printf '%s' "$cq" | cksum | cut -d' ' -f1)"
    if caller_meta=$(code_search "$slug" "$cq"); then
      echo "[survey]   $owner: $caller_meta"
      if [ "${caller_meta%%$'\t'*}" = "truncated" ]; then CALLER_STATUS="truncated"; fi
      cut -f1 "$OUT/cache/${slug}.items.jsonl" 2>/dev/null >> "$OUT/callers.tsv"
    else
      echo "[survey]   QUERY FAILED: caller census for $owner ($cq)" >&2
      caller_fail=$((caller_fail + 1))
    fi
  done
  LC_ALL=C sort -u -o "$OUT/callers.tsv" "$OUT/callers.tsv"
  if [ "$caller_fail" -gt 0 ]; then
    echo "[survey] caller enumeration failed for $caller_fail owner(s); the caller set is incomplete." >&2
    CALLER_STATUS="error"
  fi
fi
caller_total=$(wc -l < "$OUT/callers.tsv" | tr -d ' ')
echo "[survey]   $caller_total caller repo(s) (enumeration: ${CALLER_STATUS:-unknown})"

# ─────────────────────────────────────────────────────────────────────────────
# Scope guard: a token scoped to one repository produces exactly one repo and
# one caller, and a hit list built from that is worse than no hit list.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$repo_total" -le 1 ] || [ "$caller_total" -le 1 ]; then
  cat > "$OUT/HIT-LIST.md" <<EOF
# Trusted-base marker survey — INCOMPLETE

**This run did not survey an estate.** The token in use can see
$repo_total repository/ies and $caller_total governance caller(s).

GitHub's code-search API is scoped to the token. A fine-grained token granted
one repository returns one repository — and a zero result from such a token is
indistinguishable from a genuine zero. Publishing a hit list from this run
would be a confident, wrong answer about 400+ repositories.

Re-run with a user token carrying \`repo\` scope:

    bash scripts/estate-trusted-base-survey.sh --owner hyperpolymath

See docs/audits/2026-10-30-trusted-base-marker-widening.adoc § "Survey".
EOF
  echo "[survey] NEEDS-SCOPE: visible repos=$repo_total callers=$caller_total" >&2
  echo "[survey] wrote $OUT/HIT-LIST.md (INCOMPLETE) — refusing to publish a hit list" >&2
  exit 2
fi

echo "[survey] step 3/4 — querying each marker"
: > "$OUT/counts.tsv"
: > "$OUT/hits-all.tsv"
: > "$OUT/cache/.queries"
query_failures=0

# One loop over (row × owner). The row id may repeat (one row per spelling), and
# the counts step groups rows back by id, so neither the table nor the owner set
# is allowed to produce a partial answer.
while IFS=$'\t' read -r mid mtier query ext; do
  [ -z "$mid" ] && continue
  case "$mid" in '#'*) continue ;; esac
  want_tier "$mtier" || continue
  if [ -z "$ext" ] || [ "$ext" = "-" ]; then
    printf '%s\t%s\t-\n' "$mid" "$mtier" >> "$OUT/cache/.queries"
    echo "[survey]   $mid: not expressible as a code search (local checker only)"
    continue
  fi
  for owner in "${OWNERS[@]}"; do
    q="$query user:$owner"
    slug="${mid}__$(printf '%s' "$q" | cksum | cut -d' ' -f1)"
    if meta=$(code_search "$slug" "$q"); then
      printf '%s\t%s\t%s\n' "$mid" "$mtier" "$meta" >> "$OUT/cache/.queries"
      [ -f "$OUT/cache/${slug}.items.jsonl" ] && \
        awk -v m="$mid" '{print m"\t"$0}' "$OUT/cache/${slug}.items.jsonl" >> "$OUT/hits-all.tsv"
    else
      query_failures=$((query_failures + 1))
      printf '%s\t%s\terror\n' "$mid" "$mtier" >> "$OUT/cache/.queries"
      echo "[survey]   $mid: QUERY FAILED for owner $owner — counted as UNKNOWN, not zero" >&2
    fi
  done
done <<< "$MARKER_TABLE"

# Aggregate `.queries` into counts.tsv, grouped by marker id across every row and
# every owner. Two earlier defects lived here: the counts row was written right
# after the FIRST owner's query and never revisited (so a multi-owner run
# published a first-owner-only table), and a failed query scored 0 instead of
# UNKNOWN. Status precedence is error > truncated > complete.
: > "$OUT/counts.tsv"
awk -F'\t' '
  NR == FNR {
    mid = $1
    if (!(mid in seen)) { seen[mid] = 1; order[++oc] = mid; tier[mid] = $2; status[mid] = "complete" }
    st = $3
    if (st == "error")            { status[mid] = "error" }
    else if (st == "-")           { if (status[mid] != "error") status[mid] = "not-expressed" }
    else if (st == "truncated")   { if (status[mid] == "complete") status[mid] = "truncated" }
    if (st != "error" && st != "-") {
      t = $4; sub(/^total=/, "", t)
      if (t ~ /^[0-9]+$/) total[mid] += t
    }
    next
  }
  { repos[$1 SUBSEP $2] = 1 }
  END {
    for (i = 1; i <= oc; i++) {
      m = order[i]; n = 0
      for (k in repos) { split(k, a, SUBSEP); if (a[1] == m) n++ }
      if (status[m] == "not-expressed") printf "%s\t%s\tNA\t0\t%s\n", m, tier[m], status[m]
      else if (status[m] == "error")    printf "%s\t%s\tNA\t%d\t%s\n", m, tier[m], n, status[m]
      else                              printf "%s\t%s\t%d\t%d\t%s\n", m, tier[m], total[m], n, status[m]
    }
  }
' "$OUT/cache/.queries" "$OUT/hits-all.tsv" > "$OUT/counts.tsv"

while IFS=$'\t' read -r mid mtier total repos status; do
  [ -z "$mid" ] && continue
  echo "[survey]   $mid: ${total} result(s), ${repos} repo(s), $status"
done < "$OUT/counts.tsv"

echo "[survey] step 4/4 — joining hits against the caller set"
LC_ALL=C sort -u -o "$OUT/hits-all.tsv" "$OUT/hits-all.tsv"
awk -F'\t' 'NR==FNR{callers[$1]=1; next} ($2 in callers)' \
  "$OUT/callers.tsv" "$OUT/hits-all.tsv" > "$OUT/hits.tsv"

hit_total=$(wc -l < "$OUT/hits.tsv" | tr -d ' ')
affected_repos=$(cut -f2 "$OUT/hits.tsv" | LC_ALL=C sort -u | wc -l | tr -d ' ')
echo "[survey]   $hit_total hit(s) across $affected_repos caller repo(s)"

# ─────────────────────────────────────────────────────────────────────────────
# Optional: pin census. Behaviour changes land in a caller only when the caller
# bumps its pin of the reusable workflow, so the bump list is part of the
# change, not an afterthought.
# ─────────────────────────────────────────────────────────────────────────────
if $DO_PINS; then
  echo "[survey] pin census (one API call per caller)"
  : > "$OUT/pins.tsv"
  # The estate references this repository under BOTH owners — the canonical
  # `metadatastician/standards` remote and the historical `hyperpolymath/standards`
  # name (which GitHub redirects) — and sometimes both in one caller. The first
  # run matched one owner and produced 306 callers with ZERO pins, which reads
  # exactly like a census of repositories that pin nothing. A census that finds
  # nothing because the pattern was wrong is the same defect class as
  # docs/CICD-SIGNAL-DISCIPLINE.adoc § "Distinguish absent from unreadable".
  # Print unique TSV rows of repository, reusable workflow, and pinned SHA
  # found in the named repository's workflow file. Pipeline failures propagate.
  pin_scan() { # pin_scan <repo> <workflow-file>
    local repo="$1" wf="$2"
    gh api "repos/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null \
      | tr -d '\n' | base64 -d 2>/dev/null \
      | grep -oE '(metadatastician|hyperpolymath)/standards/\.github/workflows/[a-z0-9-]+\.ya?ml@[0-9a-f]{40}' \
      | sed -E "s#^.*/workflows/(.*)@([0-9a-f]{40})\$#${repo}\t\1\t\2#" \
      | LC_ALL=C sort -u
  }
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    for wf in $(gh api "repos/$repo/contents/.github/workflows" \
                   --jq '.[]? | select(.name|test("\\.ya?ml$")) | .name' 2>/dev/null); do
      [ -z "$wf" ] && continue
      pin_scan "$repo" "$wf" >> "$OUT/pins.tsv"
    done
  done < "$OUT/callers.tsv"
  LC_ALL=C sort -u -o "$OUT/pins.tsv" "$OUT/pins.tsv"
  echo "[survey]   $(wc -l < "$OUT/pins.tsv" | tr -d ' ') pinned reusable-workflow reference(s)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Publish.
# ─────────────────────────────────────────────────────────────────────────────
generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

incomplete_banner=""
survey_exit=0
if [ "$query_failures" -gt 0 ] || [ "${caller_fail:-0}" -gt 0 ] || [ "${repo_enum_failed:-0}" -gt 0 ]; then
  # A hit list built on failed queries is not a measurement: the rows for those
  # markers are UNKNOWN, and UNKNOWN rendered as a clean table is the failure
  # mode this file exists to prevent. Publish, but say INCOMPLETE and exit 2.
  incomplete_banner="**INCOMPLETE — do not act on this table.** This run had ${query_failures} failed marker quer(y|ies) (status \`error\` below), ${caller_fail:-0} failed caller-census quer(y|ies) and ${repo_enum_failed:-0} failed repository enumeration(s). A failed query is UNKNOWN, not zero: re-run before drawing any conclusion."
  survey_exit=2
fi

{
  cat <<EOF
# Trusted-base marker survey — hit list

Generated: $generated (UTC) · owners: ${OWNERS[*]} · marker set: $MARKERS

$incomplete_banner

This is the *measurement* that must precede enforcement. Nothing in this report
is a failure: a marker listed here is a marker that needs a disposition
(discharged, budgeted, axiom, or dated debt), and the disposition is a
per-repository judgement, not an estate-wide verdict.

Scope: $repo_total repository/ies visible to the token; $caller_total
governance caller(s); $hit_total marker instance(s) across $affected_repos
caller repo(s).

EOF

  echo "## Per-marker counts (callers only is NOT applied here — this is raw)"
  echo
  echo "| Marker | Tier | Code-search results | Repos | Status |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r mid mtier total repos status; do
    [ -z "$mid" ] && continue
    printf '| `%s` | %s | %s | %s | %s |\n' "$mid" "$mtier" "$total" "$repos" "$status"
  done < "$OUT/counts.tsv"
  echo
  cat <<'EOF'
`not-expressed` means the marker cannot be found by GitHub code search and is
only detected by `scripts/check-trusted-base.sh` running against a checkout.
`truncated` means the query hit GitHub's 1,000-result ceiling: the true count is
HIGHER than shown. Both are stated rather than hidden — see
`docs/CICD-SIGNAL-DISCIPLINE.adoc` § "Never report a proxy as a finding".

## Per-repository hit list

Every visible repository is listed, with a column saying whether it is known to
call governance. The caller column exists because caller enumeration is itself
a code search, and a code search is a proxy: two runs of this script on the same
estate returned 914 and 1,184 results for the caller query, and the API caps any
single query at 1,000. Rather than quietly dropping the repositories that fell
outside the proxy, the marker table below is built from ALL visible repositories
and the join is a column.

EOF
  echo
  if [ "$(wc -l < "$OUT/hits-all.tsv" | tr -d ' ')" -eq 0 ]; then
    echo "_No hits._"
  else
    echo "| Repository | Marker | Files | Calls governance |"
    echo "|---|---|---|---|"
    awk -F'\t' '
      NR==FNR { caller[$1]=1; next }
      { n[$2 "\t" $1]++ }
      END {
        for (k in n) {
          split(k, a, "\t")
          printf "%s\t%s\t%d\t%s\n", a[1], a[2], n[k], ((a[1] in caller) ? "yes" : "no")
        }
      }
    ' "$OUT/callers.tsv" "$OUT/hits-all.tsv" \
      | LC_ALL=C sort \
      | awk -F'\t' '{ printf "| `%s` | `%s` | %s | %s |\n", $1, $2, $3, $4 }'
  fi
  echo
  cat <<'EOF'
## Files

| File | Contents |
|---|---|
| `repos.tsv` | every repository listed for the requested owner(s) (`user/repos` for the token's own account, `users/<login>/repos` otherwise) |
| `callers.tsv` | repositories whose workflows reference `governance-reusable.yml` |
| `hits.tsv` | `marker<TAB>repo<TAB>path`, callers only |
| `hits-all.tsv` | same, every visible repository (non-callers included) |
| `counts.tsv` | `marker<TAB>tier<TAB>results<TAB>repos<TAB>status` |
EOF
  if $DO_PINS; then
    cat <<'EOF'
| `pins.tsv` | `repo<TAB>workflow<TAB>pinned-sha` — the bump list |
EOF
  fi
  cat <<'EOF'

## What this does NOT tell you

* **How many markers are defensible.** A `{-# TERMINATING #-}` with a written
  termination argument is the pragma working as designed. The count is the
  size of the conversation, not the size of the problem.
* **Whether a repository is unsound.** A `postulate` in a teaching example, a
  `{!!}` in a work-in-progress module and a `sorry` in a Mathlib-shaped
  development are three different things with one spelling.
* **What a budget should be.** The budget is the number the repository's
  maintainer accepts *after* triage (§(b) budgeted / §(c) axiom / §(d) dated
  debt), not the number this script measured.
EOF
} > "$OUT/HIT-LIST.md"

echo "[survey] wrote $OUT/HIT-LIST.md"
echo "[survey] done: $hit_total hit(s) in $affected_repos caller repo(s)"
if [ "$survey_exit" -ne 0 ]; then
  echo "[survey] INCOMPLETE: $query_failures failed marker quer(y|ies); ${caller_fail:-0} failed caller census quer(y|ies)." >&2
  echo "[survey] Re-run (cached successes are reused; failures are retried)." >&2
  exit 2
fi
exit 0
