#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# READ ONLY. Rerunnable census of parse-dead workflows: files GitHub rejects
# before any job exists, so they show as absent rather than red.
#
#   census-parse-dead-workflows.sh commits OUT.tsv [--owners "a b"] [--pages N]
#   census-parse-dead-workflows.sh tree ROOT [ROOT ...]
#
# TWO DIFFERENT QUESTIONS, deliberately not merged:
#
#   commits  How many REPAIR COMMITS say they fixed a workflow that did not
#            parse or never started? This is the measure behind the figure
#            "521 repairs in 281 repos" (mathesis PR #126,
#            docs/proposals/types-tropes-estate-upkeep.adoc). It counts commit
#            messages, so it measures how often the fault was FOUND AND FIXED,
#            not how many files are dead now. Method: GitHub commit search
#            (default branch of each repo, forks excluded by GitHub), message
#            phrases below, deduplicated by commit SHA. Search is capped at
#            1000 results per query, so a query whose total_count is above that
#            is flagged TRUNCATED and the counts are then a floor.
#
#   tree     How many workflow files are dead NOW in the given checkouts? This
#            runs check-workflow-totality.sh over each ROOT and counts files
#            and repos by cause. It needs checkouts; this script does not clone
#            the estate. Point it at the repos you have, or at a directory
#            made by `gh repo clone` over a repo list.
#
# STRICT phrases name a parse/start fault. BROAD adds `startup_failure`, which
# also covers pin and permission breakage that is not a parse fault.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"; shift || true

STRICT_QUERIES=(
  '"duplicate key" workflow'
  '"never-parsed" workflow'
  '"never parsed" workflow'
  '"invalid workflow" '
  '"workflow file issue"'
  '"does not parse" workflow'
  '"not parse" workflow'
  'unparseable workflow'
  '"never ran at all" workflow'
)
BROAD_EXTRA=( 'startup_failure workflow' )

case "$cmd" in
commits)
  out="${1:?usage: commits OUT.tsv [--owners \"a b\"] [--pages N]}"; shift
  owners="hyperpolymath metadatastician" pages=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --owners) owners="$2"; shift 2 ;;
      --pages) pages="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
  done
  command -v gh >/dev/null && command -v jq >/dev/null || { echo "needs gh and jq" >&2; exit 2; }
  raw="$(mktemp)"; trap 'rm -f "$raw"' EXIT
  : > "$raw"
  summary="$(mktemp)"
  i=0
  for set in strict broad; do
    qs=("${STRICT_QUERIES[@]}"); [ "$set" = broad ] && qs=("${BROAD_EXTRA[@]}")
    for owner in $owners; do
      for q in "${qs[@]}"; do
        page=1 total=0 got=0
        while [ "$page" -le "$pages" ]; do
          # search allows 30 requests a minute: stay under it
          sleep 2.2
          resp="$(gh api -X GET search/commits -f q="org:$owner $q" -f per_page=100 -f page="$page" 2>&1)" || {
            if grep -q 'rate limit\|403\|429' <<<"$resp"; then sleep 30; resp="$(gh api -X GET search/commits -f q="org:$owner $q" -f per_page=100 -f page="$page" 2>&1)" || { echo "query failed: $q ($owner) page $page: $(head -c 160 <<<"$resp")" >&2; break; }
            else echo "query failed: $q ($owner) page $page: $(head -c 160 <<<"$resp")" >&2; break; fi
          }
          total="$(jq -r '.total_count' <<<"$resp")"
          n="$(jq -r '.items | length' <<<"$resp")"
          jq -r --arg set "$set" --arg q "$q" '.items[] | [.sha, .repository.full_name, (.commit.author.date[0:10]), $set, $q, (.commit.message|split("\n")[0]|gsub("\t";" ")|.[0:140])] | @tsv' <<<"$resp" >> "$raw"
          got=$((got + n)); [ "$n" -lt 100 ] && break
          page=$((page + 1))
        done
        trunc=complete; want=$total; [ "$want" -gt 1000 ] && want=1000
        [ "$got" -lt "$want" ] && trunc=INCOMPLETE   # a query failed part-way (secondary rate limit)
        [ "$total" -gt 1000 ] && trunc=TRUNCATED
        printf '%s\t%s\t%s\ttotal_count=%s\tfetched=%s\t%s\n' "$set" "$owner" "$q" "$total" "$got" "$trunc" >> "$summary"
        i=$((i+1))
      done
    done
  done
  # one row per commit; a commit found by a strict query stays strict even if a broad query also found it
  sort -t$'\t' -k1,1 -k4,4r "$raw" | awk -F'\t' '!seen[$1]++' > "$out"
  echo "== queries (set, owner, phrase, total_count, fetched, truncation) ==" >&2
  cat "$summary" >&2
  echo "== result: $out ==" >&2
  for set in strict broad; do
    if [ "$set" = strict ]; then sel='$4=="strict"'; else sel='1'; fi
    c=$(awk -F'\t' "$sel" "$out" | wc -l)
    r=$(awk -F'\t' "$sel {print \$2}" "$out" | sort -u | wc -l)
    printf '%s\tcommits=%s\trepos=%s\n' "$set" "$c" "$r"
  done
  rm -f "$summary"
  ;;
tree)
  [ $# -ge 1 ] || { echo "usage: tree ROOT [ROOT ...]" >&2; exit 64; }
  all="$(mktemp)"; trap 'rm -f "$all"' EXIT
  for r in "$@"; do
    # A checker that cannot run (for example no mikefarah yq) prints a TSV row, not JSON. Count that
    # repository as one not_run row instead of dropping it, so the census never reads as clean.
    out="$(bash "$HERE/check-workflow-totality.sh" --json "$r" 2>/dev/null)"
    if rows="$(jq -c '.[]' <<<"$out" 2>/dev/null)" && [ -n "$rows" ]; then
      printf '%s\n' "$rows" >> "$all"
    else
      jq -nc --arg r "$r" '{state:"not_run",root:$r,file:"-",detail:"checker could not run or produced no JSON"}' >> "$all"
    fi
  done
  jq -s -r '
    def cause: (.detail | capture("^(?<c>[a-z]+):") // {c:"other"} | .c);
    (map(select(.state=="failed"))) as $f
    | "repos_scanned\t" + ((map(.root) | unique | length) | tostring),
      "workflow_files\t" + ((map(select(.state != "inert")) | length) | tostring),
      "failed_files\t" + ($f | length | tostring),
      "failed_repos\t" + ($f | map(.root) | unique | length | tostring),
      "not_run_files\t" + ((map(select(.state == "not_run")) | length) | tostring),
      ($f | group_by(cause) | .[] | "cause:" + (.[0] | cause) + "\t" + (length | tostring))
  ' "$all"
  ;;
*)
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
