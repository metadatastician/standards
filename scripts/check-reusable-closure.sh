#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-reusable-closure.sh — closure ACROSS remote reusable workflows, checked
# against a REVIEWED baseline rather than against the lockfile alone.
#
# WHY THIS EXISTS
# ---------------
# Three controls already exist and none of them can see the failure this script
# is for:
#
#   * `gh actions-lock --verify-local` sees step-level `uses:` only. It cannot
#     derive an edge reached through a remote reusable workflow, and it says so.
#   * `check-lock-sync.sh` compares a workflow's `uses:` to its lockfile entry.
#     Useful, and blind in the same way: the ref used *inside* a remote reusable
#     at the pinned commit is not in the calling workflow's text.
#   * `close-lock.sh --check` proves every ref NAMED in the lockfile has a
#     record. Necessary, and self-referential: delete an edge from
#     `workflows:` AND its `dependencies:` record and the lockfile is still
#     perfectly closed. **An edge and its target dropped together leave a closed
#     lock, a green sync gate, and a caller whose dependency silently vanished.**
#
# That last case is the reason for the baseline. Closure is a property of the
# lockfile; *completeness* is a property of the lockfile measured against the
# callee graph at the pinned commits. Only an artefact independent of the current
# lock can hold the second.
#
# MEASURED, 2026-10-31, hyperpolymath/unified-dataset-vocab PR #81 (merged
# 2026-10-31T12:06Z, `4921ac0d`): its `.github/workflows/secret-scanner.yml`
# calls `hyperpolymath/cicd-suite/.github/workflows/secret-scanner-reusable.yml@4404c3c0…`,
# which itself runs `actions/checkout@3d3c42e5…`. The lockfile records that
# checkout under the CALLING workflow's entry and records NO
# `hyperpolymath/cicd-suite@4404c3c0…` record at all. The workflow ran 3 jobs
# with 10/3/3 steps (`scan / gitleaks`, `scan / rust-secrets`,
# `scan / shell-secrets`) — so this representation starts. Both shapes are
# therefore accepted here:
#
#   (a) the through-ref is listed in the calling workflow's `workflows:` entry;
#   (b) it is listed in the reusable record's nested `uses:`.
#
# and a job-level reusable ref that is absent from the lockfile entirely is
# permitted (NOTE, not FAIL) — measured in hyperpolymath/standards#968 against
# 159 repositories, 12 of 12 sampled runs creating jobs.
#
# WHAT IT CHECKS
# --------------
#   1. every remote job-level `uses:` is SHA-pinned (a branch or tag there is a
#      float, and a float cannot be verified at all);
#   2. the workflow file it names is READ AT THAT SHA (cache first, then the API)
#      and its own `uses:` — step-level and job-level, transitively to a bounded
#      depth — are collected;
#   3. every step-level ref reached that way is recorded in the calling
#      workflow's lockfile entry, or in the reusable record's nested `uses:`;
#   4. every such ref is compared against the REVIEWED BASELINE; a row that has
#      disappeared is a DROPPED CLOSURE failure even when the lock is closed;
#   5. reviewed tag refs are preserved: for every reusable record read, `ref:`
#      must be exactly the ref the caller named, and its `commit:` must be
#      `sha1-<that ref>` when the ref is a full SHA. Nothing here rewrites a
#      `ref:` to a SHA, and a leaf record whose `ref:` repeats its own SHA is
#      reported (standards#1271/#1290; Hypatia PI006).
#
# WHAT IT DOES NOT PROVE (so a green is not misread)
# -------------------------------------------------
#   * that the workflow RUNS. Only a hosted run does that. This is why the
#     baseline records what was reviewed and why `--write-baseline` is a
#     reviewed artefact, not a generated convenience.
#   * that a pinned tag still points at the pinned commit (close-lock.sh
#     documents the measured tolerance; remote reachability belongs to
#     check-action-pins-resolve.sh / lock-selfcheck.sh).
#   * that the callee's own dependency set is *sufficient* — only that the parts
#     recorded here still exist and reproduce the reviewed baseline.
#   * a `git clone …standards.git` inside a `run:` body, a dynamic `uses:`
#     expression, or a reusable called with a ref that is not a literal.
#
# EXIT
#   0 = every edge resolved, every through-ref recorded, baseline reproduced
#   1 = a violation (each named, with the fix)
#   2 = NOT INSPECTED: no yq/jq, no baseline, an unresolvable callee ref, an
#       unparsable workflow. A gate that cannot inspect must never be green.
#
# USAGE
#   check-reusable-closure.sh [WF_DIR] [options]
#     --baseline FILE      reviewed closure to reproduce (default:
#                          $WF_DIR/actions-lock.closure.tsv)
#     --write-baseline     write/refresh the baseline from what was resolved,
#                          then report. The file MUST be reviewed in the PR.
#     --cache DIR          read callee workflows from DIR (never the network)
#     --offline            never call the API; a cache miss is NOT INSPECTED
#     --depth N            transitive limit (default 6)
#     --repo OWNER/REPO    repository whose workflows these are (for the API)
#
# TESTS: scripts/tests/check-reusable-closure-test.sh
set -uo pipefail

WF_DIR=".github/workflows"
BASELINE=""
WRITE_BASELINE=0
CACHE=""
OFFLINE=0
DEPTH=6
REPO="${GITHUB_REPOSITORY:-}"
# need_value OPTION REMAINING_ARGC VALUE: require a nonempty option value.
# Exit 2 with an error if fewer than two arguments remain or VALUE is empty.
need_value() {  # $1 option, $2 remaining argc
  [ "$2" -ge 2 ] && [ -n "${3:-}" ] ||
    { echo "::error::$1 needs a value — NOT INSPECTED, which is not a pass." >&2; exit 2; }
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline) need_value "$1" "$#" "${2:-}"; BASELINE="$2"; shift 2 ;;
    --write-baseline) WRITE_BASELINE=1; shift ;;
    --cache) need_value "$1" "$#" "${2:-}"; CACHE="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --depth) need_value "$1" "$#" "${2:-}"; DEPTH="$2"; shift 2 ;;
    --repo) need_value "$1" "$#" "${2:-}"; REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,90p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) WF_DIR="$1"; shift ;;
  esac
done
case "$DEPTH" in ''|*[!0-9]*) echo "::error::--depth must be a non-negative integer (got '$DEPTH') — NOT INSPECTED." >&2; exit 2 ;; esac

not_inspected() { echo "::error::$* — NOT INSPECTED, which is not a pass." >&2; exit 2; }

command -v yq >/dev/null 2>&1 || not_inspected "yq not found (mikefarah yq v4 required; YAML-POLICY Y-1)"
yq --version 2>/dev/null | grep -q mikefarah || not_inspected "yq on PATH is not mikefarah yq v4"
command -v jq >/dev/null 2>&1 || not_inspected "jq not found"
[ -d "$WF_DIR" ] || not_inspected "workflow directory not found: $WF_DIR"

BASELINE="${BASELINE:-$WF_DIR/actions-lock.closure.tsv}"
if [ "$WRITE_BASELINE" -eq 0 ] && [ ! -f "$BASELINE" ]; then
  not_inspected "no reviewed closure baseline at $BASELINE. Closure alone cannot detect an edge and its target being dropped together; create the baseline with --write-baseline, review the added rows in the pull request, and commit it"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# owner/repo[/subpath…]@ref -> "owner/repo@ref" (lowercased owner/repo; ref
# case-preserved, because git refs are case-sensitive). Empty for local refs.
norm() {
  printf '%s' "$1" | awk '{
    r = $0
    at = 0
    for (n = length(r); n > 0; n--) if (substr(r, n, 1) == "@") { at = n; break }
    if (at == 0) { print ""; exit }
    path = substr(r, 1, at - 1); ref = substr(r, at + 1)
    if (path == "" || ref == "") { print ""; exit }
    if (substr(path, 1, 2) == "./" || substr(path, 1, 2) == "$/") { print ""; exit }
    n = split(path, p, "/")
    if (n < 2) { print ""; exit }
    print tolower(p[1] "/" p[2]) "@" ref
  }'
}

# A job-level REMOTE reusable call: owner/repo/.github/workflows/<file>@<ref>.
# A local call (./.github/workflows/<file>.yml) is a workflow of this same
# repository at this same commit: it is its own lockfile entry, it cannot float,
# and the closure of what it uses is checked when its own file is examined.
is_job_level() {
  printf '%s' "$1" | grep -Eq '/\.github/workflows/[^@]+@' || return 1
  case "$1" in ./*|../*) return 1 ;; esac
  return 0
}

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# resolve_callee OWNER REPO REF PATH: print the cached or fetched workflow
# file path. Return 1 on a cache miss in offline mode or an unsuccessful fetch
# or decode. If CACHE is configured, copying a fetched file there is attempted;
# a copy failure does not prevent returning the fetched file.
resolve_callee() {
  local owner=$1 repo=$2 ref=$3 path=$4 cached
  cached="$CACHE/$owner/$repo/$ref/$(printf '%s' "$path" | tr '/' '_')"
  if [ -n "$CACHE" ] && [ -f "$cached" ]; then printf '%s\n' "$cached"; return 0; fi
  [ "$OFFLINE" -eq 1 ] && return 1
  local out="$TMP/fetched.$$.${RANDOM}"
  if gh api "repos/$owner/$repo/contents/$path?ref=$ref" --jq .content >"$out.b64" 2>/dev/null; then
    if base64 -d <"$out.b64" >"$out" 2>/dev/null && [ -s "$out" ]; then
      if [ -n "$CACHE" ]; then
        mkdir -p "$(dirname "$cached")" && cp "$out" "$cached"
      fi
      printf '%s\n' "$out"; return 0
    fi
  fi
  return 1
}

fail=0
inspected_sites=0
resolved_sites=0
unresolved=0
notes=""
declare -A REACHED=()   # "workflow|jobref|actionref" -> 1 (what we actually saw)
declare -A LOCKSET=()   # "workflow|actionref" -> locked under that workflow entry
declare -A RECSET=()    # "jobref|actionref" -> in that reusable record's uses:
declare -A RECREF=()    # "jobref" -> the record's ref: value
declare -A HAVEKEY=()   # workflow -> 1 when the lock has an entry for it
declare -A JOBREF=()    # job-level ref actually named by a workflow in this repo
declare -A PARENT=()    # callee key -> the callee that reached it (chain for (b))
CHAINKEYS=""           # every callee key reached by the CURRENT workflow

LOCK="$WF_DIR/actions.lock"
[ -f "$LOCK" ] || not_inspected "no lockfile at $LOCK"

# Parse the lockfile with yq+jq, so quoting/spacing cannot defeat it.
if ! yq -o json -I 0 '.' "$LOCK" >"$TMP/lock.json" 2>"$TMP/lock.err"; then
  not_inspected "lockfile does not parse: $(head -1 "$TMP/lock.err")"
fi
jq -r '(.workflows // {}) | to_entries[] | .key as $w | (.value // [])[] | "W\t\($w)\t\(.)"' \
  "$TMP/lock.json" >"$TMP/lock.wf" || not_inspected "lockfile workflows: is not a list-per-path map"
jq -r '(.dependencies // {}) | to_entries[] | .key as $k | .value as $v
       | "R\t\($k)\t\(($v.ref // "") | tostring)",
         ((($v.uses // [])[]) | "U\t\($k)\t\(.)")' "$TMP/lock.json" >"$TMP/lock.deps" ||
  not_inspected "lockfile dependencies: is not a map of records"

while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    W) HAVEKEY["$a"]=1; LOCKSET["$a|$(norm "$b")"]=1 ;;
    R) RECREF["$a"]="$b" ;;
    U) RECSET["$a|$(norm "$b")"]=1 ;;
  esac
done < <(cat "$TMP/lock.wf" "$TMP/lock.deps")

# uses_of FILE: print string uses: values at job and step level, one per line.
# Return a nonzero status if the YAML or JSON processing fails.
uses_of() {
  yq -o json -I 0 '.' "$1" 2>/dev/null |
    jq -r '[(.jobs // {}) | to_entries[] | .value | objects | .uses // empty],
           [(.jobs // {}) | to_entries[] | .value | objects | (.steps // [])[] | objects | .uses // empty]
           | .[] | select(type == "string")' 2>/dev/null
}

# walk_callee RAW DEPTH [TOP]: collect refs reached from a reusable call in
# REACHED, attributed to CURWF and TOP (defaulting to RAW's normalized key).
# RAW is the full uses: value, including the workflow path. DEPTH starts at 1;
# calls beyond the configured limit fail, while a file already visited for the
# same TOP is skipped. Local nested calls are resolved at the callee's ref.
# Return 1 for depth, read or parse failures, ../ references, unpinned nested
# calls, or nested record/ref mismatches. Depth and read failures increment
# unresolved.
WALKED=""
walk_callee() {
  local raw=$1 depth=$2 top=${3:-}
  local key; key="$(norm "$raw")"
  [ -n "$top" ] || top="$key"
  [ -n "$key" ] || return 0
  if [ "$depth" -gt "$DEPTH" ]; then
    echo "::error::$key: reusable chain is deeper than --depth $DEPTH, so its closure was never inspected. Raise --depth." >&2
    unresolved=$((unresolved + 1))
    return 1
  fi
  # Cycle detection keys on the FILE, not on owner/repo@ref: two different
  # workflow files called at the same ref are two different `uses:` sets, and
  # collapsing them silently under-collects the closure. It is also SCOPED TO
  # THE TOP-LEVEL CALL: two top-level reusables in one workflow that both reach
  # the same nested file are two different edges, and remembering the file
  # globally made the second traversal return here without attributing its
  # dependencies to the second edge.
  case " $WALKED " in *" $top|$raw "*) return 0 ;; esac
  WALKED="$WALKED $top|$raw"
  CHAINKEYS="$CHAINKEYS $key"

  local path=${raw%@*} ref=${raw##*@}
  local owner repo wfpath
  owner=${path%%/*}; path=${path#*/}
  repo=${path%%/*}; wfpath=${path#*/}

  local file
  if ! file="$(resolve_callee "$owner" "$repo" "$ref" "$wfpath")"; then
    echo "::error::$key: the called workflow $wfpath could not be read at $ref (offline with no cache entry, or the API refused). An unread callee is NOT a closed closure; pass --cache with a fetched copy, or drop --offline." >&2
    unresolved=$((unresolved + 1))
    return 1
  fi
  resolved_sites=$((resolved_sites + 1))

  local uses n nn child
  uses="$(uses_of "$file")" || { echo "::error::$key: $wfpath at $ref does not parse as YAML" >&2; return 1; }
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      ./*)
        # A LOCAL call inside a REMOTE reusable workflow is not "this
        # repository at this commit": it is that repository at that ref (a
        # local call cannot name a ref of its own). Left to `norm` it returned
        # empty, and the nested file's own dependencies were dropped from the
        # closure entirely.
        child="$owner/$repo/${n#./}@$ref"
        ;;
      ../*)
        echo "::error::$key: nested call '$n' escapes the repository root; a ../-relative reusable cannot be resolved at a pinned ref." >&2
        return 1
        ;;
      *) child="$n" ;;
    esac
    if is_job_level "$child"; then
      local cref=${child##*@} ckey
      # Nested calls get the SAME immutability rule as top-level ones: a
      # branch or tag reached through a SHA-pinned callee is still a float,
      # and this recursion used to resolve and certify it.
      if ! is_sha "$cref"; then
        echo "::error::$key: nested job-level uses '$child' is not SHA-pinned. A SHA-pinned reusable that calls another at a branch makes the closure describe whatever that ref pointed at today." >&2
        return 1
      fi
      ckey="$(norm "$child")"
      [ -n "$ckey" ] || { echo "::error::$key: nested call '$n' does not name a readable owner/repo" >&2; return 1; }
      # ...and the same record/ref conjugation: a nested callee's lock record
      # must carry the ref the caller named, not a tag it was rewritten to.
      if [ -n "${RECREF[$ckey]:+x}" ] && [ "${RECREF[$ckey]}" != "$cref" ]; then
        echo "::error::$key: the record '$ckey' carries ref: '${RECREF[$ckey]}' but this reusable names '$cref'. A reusable record's ref must be the ref that was requested." >&2
        return 1
      fi
      PARENT["$ckey"]="$key"
      walk_callee "$child" $((depth + 1)) "$top" || return 1
    else
      nn="$(norm "$n")"
      [ -n "$nn" ] || continue
      REACHED["$CURWF|$top|$nn"]=1
    fi
  done <<<"$uses"
  return 0
}

shopt -s nullglob
for wf in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  base=${wf##*/}
  key=".github/workflows/$base"
  CURWF="$key"

  if ! wf_json="$(yq -o json -I 0 '.' "$wf" 2>"$TMP/wf.err")"; then
    echo "::error file=$wf::does not parse as YAML: $(head -1 "$TMP/wf.err")" >&2
    fail=$((fail + 1)); continue
  fi

  WALKED=""; CHAINKEYS=""
  job_refs="$(printf '%s' "$wf_json" | jq -r '(.jobs // {}) | to_entries[] | select(.value.uses != null) | .value.uses | select(type == "string")' 2>/dev/null)"
  step_refs="$(printf '%s' "$wf_json" | jq -r '[(.jobs // {}) | to_entries[] | (.value.steps // [])[] | select(.uses != null) | .uses | select(type == "string")] | .[]' 2>/dev/null)"

  # 1. every job-level call must be immutable before anything else is claimed.
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    is_job_level "$j" || continue          # local ./…: its own lock entry
    local_ref=${j##*@}
    if ! is_sha "$local_ref"; then
      echo "::error file=$wf::job-level uses '$j' is not SHA-pinned. A branch or tag there cannot be verified — the closure below would describe whatever that ref pointed at today, and a caller pinned to this repository would still follow it." >&2
      fail=$((fail + 1))
      continue
    fi
    jn="$(norm "$j")"
    [ -n "$jn" ] || continue
    inspected_sites=$((inspected_sites + 1))
    JOBREF["$jn"]=1
    walk_callee "$j" 1 || fail=$((fail + 1))
    if [ -z "${LOCKSET["$key|$jn"]:-}" ]; then
      if [ -n "${HAVEKEY[$key]:-}" ]; then
        notes="${notes}  $key: job-level ref $jn is not in this entry (allowed; measured harmless in standards#968, and it is what unified-dataset-vocab#81 runs with today)"$'\n'
      fi
    fi
    # 5. tag/commit preservation on the reusable record, when it is recorded.
    if [ -n "${RECREF[$jn]:+x}" ]; then
      rref="${RECREF[$jn]}"
      jref=${jn##*@}
      if [ "$rref" != "$jref" ]; then
        echo "::error file=$wf::the record '$jn' carries ref: '$rref' but the caller named '$jref'. A reusable record's ref must be the ref that was requested — rewriting it (to a tag, or to the SHA) is how a reviewed pin becomes a printed claim." >&2
        fail=$((fail + 1))
      fi
    fi
  done <<<"$job_refs"

  # 2. every step-level ref, local or through a reusable, must be recorded.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    sn="$(norm "$s")"
    [ -n "$sn" ] || continue
    if [ -z "${LOCKSET["$key|$sn"]:-}" ]; then
      echo "::error file=$wf::step-level ref '$s' is not in this workflow's lockfile entry. GitHub validates it against THIS entry at startup: the run dies at 'Set up job' with zero jobs." >&2
      fail=$((fail + 1))
    fi
  done <<<"$step_refs"

  # 3. refs reached through a remote reusable: accept either recorded shape.
  while IFS=$'\t' read -r wf2 jr ar; do
    [ "$wf2" = "$key" ] || continue
    if [ -n "${LOCKSET["$key|$ar"]:-}" ]; then continue; fi
    # (b) recorded under the `uses:` of a reusable record this workflow actually
    # reaches — the top-level call, or any nested one (depth >= 2).
    chain_hit=0
    for link in $CHAINKEYS; do
      if [ -n "${RECSET["$link|$ar"]:-}" ]; then chain_hit=1; break; fi
    done
    [ "$chain_hit" -eq 1 ] && continue
    echo "::error file=$wf::ref '$ar' is reached at startup through $jr but is recorded in neither place the runner accepts: this workflow's lockfile entry, nor that reusable's record under 'uses:'. Add it (close-lock.sh does this) — standards#1290." >&2
    fail=$((fail + 1))
  done < <(for k in "${!REACHED[@]}"; do IFS='|' read -r a b c <<<"$k"; printf '%s\t%s\t%s\n' "$a" "$b" "$c"; done)
done

# 4. the reviewed baseline: rows may be added by a review, never lost silently.
emit_rows() {
  for k in "${!REACHED[@]}"; do IFS='|' read -r a b c <<<"$k"; printf '%s\t%s\t%s\n' "$a" "$b" "$c"; done | LC_ALL=C sort
}

if [ "$WRITE_BASELINE" -eq 1 ] && [ "$unresolved" -gt 0 ]; then
  echo "::error::not writing $BASELINE: ${unresolved} callee workflow(s) could not be read, so the closure is partial." >&2
elif [ "$WRITE_BASELINE" -eq 1 ]; then
  {
    printf '%s\n' "# Reviewed closure of remote reusable workflows (standards#968, #1290)."
    printf '%s\n' "# Produced by scripts/check-reusable-closure.sh --write-baseline; a change"
    printf '%s\n' "# here is a change to what this repository trusts, so review the diff."
    printf '%s\n' "# workflow<TAB>reusable-call<TAB>ref reached at startup"
    emit_rows
  } >"$TMP/new-baseline.tsv"
  if [ -f "$BASELINE" ] && ! diff -q <(grep -v '^#' "$BASELINE" | LC_ALL=C sort) <(grep -v '^#' "$TMP/new-baseline.tsv") >/dev/null; then
    echo "::warning::the closure baseline changed; review this diff before committing:"
    diff -u <(grep -v '^#' "$BASELINE") <(grep -v '^#' "$TMP/new-baseline.tsv") >&2 || true
  fi
  mkdir -p "$(dirname "$BASELINE")" && cp "$TMP/new-baseline.tsv" "$BASELINE"
  echo "wrote $BASELINE — REVIEW IT; a row that disappears from this file without a review is the defect it exists to catch."
fi

if [ "$WRITE_BASELINE" -eq 0 ] && [ -f "$BASELINE" ]; then
  # The baseline is compared in BOTH directions. Comparing only "is every
  # reviewed row still reachable" let a NEW edge through: add a remote call and
  # its through-ref records to the lock and nothing on the reviewed artefact
  # changes, so the gate exited 0 on trust nobody reviewed.
  declare -A BASE=()
  while IFS=$'\t' read -r bwf bjr bar; do
    case "$bwf" in ''|'#'*) continue ;; esac
    BASE["$bwf|$bjr|$bar"]=1
    if [ -z "${REACHED["$bwf|$bjr|$bar"]:-}" ]; then
      echo "::error file=$bwf::DROPPED CLOSURE — the reviewed baseline ($BASELINE) has $bjr -> $bar, and this source no longer reaches it. The lockfile can still be closed in this state (an edge and its target removed together leave no dangling pointer), so no other gate sees this. Restore the call, or remove the row in a pull request that says why." >&2
      fail=$((fail + 1))
    fi
  done <"$BASELINE"

  for k in "${!REACHED[@]}"; do
    IFS='|' read -r rwf rjr rar <<<"$k"
    [ -n "${BASE["$k"]:-}" ] && continue
    echo "::error file=$rwf::UNREVIEWED CLOSURE — this source reaches $rjr -> $rar, and that row is not in the reviewed baseline ($BASELINE). A new remote edge (or a new dependency behind one) is a change to what this repository trusts: regenerate with --write-baseline and let it be reviewed in the pull request." >&2
    fail=$((fail + 1))
  done
  unset BASE
fi

# 5b. a LEAF record whose ref: repeats its own SHA is the record the runner
# refuses at Set up job (standards#1271/#1290, Hypatia PI006). A reusable
# record is exempt only where a caller in this repository actually names that
# key as a job-level call: that ref legitimately IS the commit.
for k in "${!RECREF[@]}"; do
  key_sha=${k##*@}
  is_sha "$key_sha" || continue
  [ "${RECREF[$k]}" = "$key_sha" ] || continue
  if [ -n "${JOBREF[$k]:-}" ] || [ -n "${PARENT[$k]:-}" ]; then
    # JOBREF: a workflow here calls it at top level. PARENT: a reusable this
    # workflow reaches calls it NESTED. Both mean the same thing — the ref
    # genuinely IS the commit that was requested — and only the top-level case
    # used to be exempt, which made a nested reusable record impossible to
    # state: the record/ref conjugation above requires `ref` == the named SHA,
    # and this check then rejected exactly that.
    notes="${notes}  $k: ref repeats the key's SHA, but this repository reaches it as a reusable at that commit — accepted (standards#1290)"$'\n'
  else
    echo "::error::$k: ref: '$key_sha' repeats the record's own SHA. GitHub rejects this record at 'Set up job' ('invalid lockfile pin') for every caller. Name the reviewed tag that resolves to it (gitbot-fleet fix-lock-self-sha-refs.sh, or 'gh actions-lock' for a step-level action)." >&2
    fail=$((fail + 1))
  fi
done

if [ -n "$notes" ]; then
  printf '%s' "$notes"
fi

if [ "$unresolved" -gt 0 ]; then
  echo "examined $WF_DIR: ${inspected_sites} remote reusable site(s), ${resolved_sites} resolved, ${unresolved} UNREADABLE; failures: ${fail}"
  echo "::error::${unresolved} callee workflow(s) could not be read, so the closure of those edges was never inspected — NOT INSPECTED, which is not a pass." >&2
  exit 2
fi

if [ "$inspected_sites" -eq 0 ]; then
  [ "$fail" -eq 0 ] || { echo "examined $WF_DIR: 0 remote reusable site(s); failures: ${fail}"; exit 1; }
  echo "examined $WF_DIR: no remote job-level reusable call (0 sites)."
  echo "PASS (vacuous population, stated)."
  exit 0
fi

echo "examined $WF_DIR: ${inspected_sites} remote reusable site(s), ${resolved_sites} resolved; failures: ${fail}"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: every remote reusable edge is immutable, recorded where the runner looks, and reproduces the reviewed closure."
echo "       (A hosted run of a caller, not this script, proves a run STARTS.)"
exit 0
