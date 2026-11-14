#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# conformance-k9.sh — the caller-relevant part of the K9 conformance lane, as ONE
# implementation. .github/workflows/k9-conformance.yml (the reusable) and the
# template's inline governance both call it, so the two cannot drift. Owner
# ruling Q6 (2026-11-14): the checks live in the deprecated reusable AND in the
# template's inline jobs. Policy and anatomy: docs/VERDICT-GRID-SPEC.adoc; the
# validator is 1-formats/k9/tools/k9-validate.sh and the renderer scripts/k9-grid.sh.
#
# Usage: conformance-k9.sh SUBCOMMAND, one per workflow step, in this order:
#   selftest    validator --self-test (SELFTEST_CODE to $GITHUB_ENV)
#   typecheck   nickel typecheck of the contract (TYPECHECK_CODE to $GITHUB_ENV)
#   enumerate   committed K9 files, changed files, shrink-only ledger growth
#   validate    every committed K9 file, L0-L2 strict (CORPUS_CODE to $GITHUB_ENV)
#   coord       coordination.k9 files against the v1.2 ABNF (their own grid category)
#   previous    the previous grid comment, for the delta column (pull requests)
#   render      the verdict grid (state to $GITHUB_OUTPUT)
#   gate        turn the grid state into the step's exit status
#
# The caller supplies the environment each body reads (CANON, RUNNER_TEMP,
# BASE_SHA, HEAD_SHA, ADVISORY, REQUIRE_FILES, STATE, ...), exactly as the
# workflow's steps do; the canon checkouts (.k9-canon, .standards-checkout) are
# never read as the caller's own K9 files. GitHub runs a step with
# `bash -e -o pipefail` and without -u, so this script does the same: the bodies
# were written for that, and every no-match grep in them is guarded.
set -eo pipefail
: "${RUNNER_TEMP:=$(mktemp -d)}"

cmd_selftest() {
  set +e
  bash "$CANON/1-formats/k9/tools/k9-validate.sh" --self-test > "$RUNNER_TEMP/selftest.log" 2>&1
  echo "SELFTEST_CODE=$?" >> "$GITHUB_ENV"
  tail -n 5 "$RUNNER_TEMP/selftest.log"
}

cmd_typecheck() {
  set +e
  nickel typecheck "$CANON/1-formats/k9/spec/contract/k9_contract.ncl" > "$RUNNER_TEMP/typecheck.log" 2>&1
  echo "TYPECHECK_CODE=$?" >> "$GITHUB_ENV"
  cat "$RUNNER_TEMP/typecheck.log"
}

cmd_enumerate() {
  set -euo pipefail
  # Tracked files only: an untracked file is not a committed contract.
  # The two extensions K9-CONTRACT-SPEC.adoc reserves, nothing else.
  # A caller with no K9 file at all is a legitimate (grey) corpus, so
  # grep's no-match exit is not an error here.
  git ls-files -z -- '*.k9.ncl' '*.k9' \
    | tr '\0' '\n' \
    | { grep -v -E '^(\.k9-canon/|\.standards-checkout/|9-archive/|1-formats/k9/tools/fixtures/|2-protocols/k9-coordination/tools/validate/fixtures/)' || [ $? -eq 1 ]; } \
    | sort > "$RUNNER_TEMP/expected"
  echo "$(wc -l < "$RUNNER_TEMP/expected") committed K9 file(s)"
  : > "$RUNNER_TEMP/changed"
  : > "$RUNNER_TEMP/ledger-growth"
  echo "BASE_UNRESOLVED=" >> "$GITHUB_ENV"
  case "$BASE_SHA" in *[!0]*) ;; *) BASE_SHA="" ;; esac
  [ -n "$BASE_SHA" ] || exit 0

  # The PR's own changes are those since its merge base, not since the
  # base branch tip: a file the base branch changed after the PR
  # branched is not this PR's edit. A push compares with `before`
  # itself, never a merge base: after a force push the fork point is
  # not the state the push replaced, and a ledger entry the old tip
  # had removed would come back unseen. The full checkout already
  # holds the base commit; the fetch
  # is a fallback only, and runs without credentials
  # (persist-credentials is off), so it serves public repositories.
  if { git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || git fetch --quiet origin "$BASE_SHA" 2>/dev/null; } \
     && merge_base=$(if [ "$GITHUB_EVENT_NAME" = pull_request ]; then git merge-base "$BASE_SHA" "$HEAD_SHA"; else git rev-parse --verify "$BASE_SHA^{commit}"; fi 2>/dev/null) \
     && git diff --name-only "$merge_base" "$HEAD_SHA" > "$RUNNER_TEMP/changed" 2>/dev/null; then
    echo "$(wc -l < "$RUNNER_TEMP/changed") file(s) changed since the merge base $merge_base"
  else
    echo "::warning::could not resolve the PR base/head range; debt exemptions are reported as indeterminate"
    echo "BASE_UNRESOLVED=--base-unresolved" >> "$GITHUB_ENV"
    exit 0
  fi

  # The ledger is shrink-only. Entries present at HEAD and absent at
  # the merge base are growth; growth exempts nothing unless a commit
  # message in the PR or the PR body declares it in the exemption
  # ratchet's form, naming this ledger:
  #     Ratchet-exception: .machine_readable/k9-contract-debt.txt — <why>
  #     Ratchet-exception(.machine_readable/k9-contract-debt.txt): <why>
  # Read ledger paths from stdin and emit sorted unique entries,
  # excluding comments and blank lines; an empty ledger succeeds.
  entries() { { grep -vE '^[[:space:]]*(#|$)' || [ $? -eq 1 ]; } | sort -u; }
  head_entries=$RUNNER_TEMP/ledger-head
  base_entries=$RUNNER_TEMP/ledger-base
  if [ -f "$LEDGER" ]; then entries < "$LEDGER" > "$head_entries"; else : > "$head_entries"; fi
  { git show "$merge_base:$LEDGER" 2>/dev/null || true; } | entries > "$base_entries"
  comm -13 "$base_entries" "$head_entries" > "$RUNNER_TEMP/ledger-growth"
  [ -s "$RUNNER_TEMP/ledger-growth" ] || exit 0
  declared=no
  if git log --format=%B "$merge_base..$HEAD_SHA" | grep -iE '^Ratchet-exception' | grep -qF "$LEDGER"; then
    declared=yes
  elif [ -f "${GITHUB_EVENT_PATH:-}" ] \
       && jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" | grep -iE '^Ratchet-exception' | grep -qF "$LEDGER"; then
    declared=yes
  fi
  n=$(wc -l < "$RUNNER_TEMP/ledger-growth")
  if [ "$declared" = yes ]; then
    echo "::notice::$LEDGER grew by $n entr(y/ies) under a declared Ratchet-exception"
    : > "$RUNNER_TEMP/ledger-growth"
  else
    # Advisory mode must not attach error-severity annotations.
    sev=error; [ "$ADVISORY" = "true" ] && sev=warning
    echo "::${sev}::$LEDGER grew by $n entr(y/ies) with no Ratchet-exception naming it; the new entries exempt nothing"
    sed 's/^/  + /' "$RUNNER_TEMP/ledger-growth"
  fi
}

cmd_validate() {
  set +e
  : > "$RUNNER_TEMP/results.jsonl"
  worst=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # `--` ends the options: a tracked file whose name starts with `-`
    # is a path, not a flag.
    bash "$CANON/1-formats/k9/tools/k9-validate.sh" --strict --layer L2 --json --quiet -- "$f" >> "$RUNNER_TEMP/results.jsonl" 2>> "$RUNNER_TEMP/corpus.log"
    rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
  done < "$RUNNER_TEMP/expected"
  echo "CORPUS_CODE=$worst" >> "$GITHUB_ENV"
  echo "validator worst exit status: $worst"
}

cmd_coord() {
  set +e
  : > "$RUNNER_TEMP/coord-results.jsonl"
  jq -r 'select(.verdict == "routed") | .file' "$RUNNER_TEMP/results.jsonl" > "$RUNNER_TEMP/routed" 2>/dev/null
  if [ -s "$RUNNER_TEMP/routed" ]; then
    V="$PWD/$CANON/2-protocols/k9-coordination/tools/validate"
    if (cd "$V" && bun install --frozen-lockfile >"$RUNNER_TEMP/coord-install.log" 2>&1); then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        # validate.js reads a leading `-` as an option; `./` keeps a
        # tracked file named `-x.k9` a path.
        out=$(bun "$V/validate.js" "./$f" 2>&1); rc=$?
        # Exit 1 is both the validator's "finding" status and what Bun
        # uses for a crash (module resolution, an uncaught exception), so
        # a failure needs the validator's own `FAIL <file>:` line.
        # Anything else leaves no record, and the file stays indeterminate.
        if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^PASS '; then
          jq -nc --arg f "$f" '{file: $f, verdict: "pass", message: ""}' >> "$RUNNER_TEMP/coord-results.jsonl"
        elif [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^FAIL '; then
          jq -nc --arg f "$f" --arg m "$out" '{file: $f, verdict: "fail", message: $m}' >> "$RUNNER_TEMP/coord-results.jsonl"
        else
          echo "::warning::coordination validator gave no verdict on $f (exit $rc); the file stays indeterminate"
        fi
      done < "$RUNNER_TEMP/routed"
    else
      echo "::warning::coordination validator dependencies did not install; routed files are indeterminate"
      cat "$RUNNER_TEMP/coord-install.log"
    fi
  fi
  echo "coordination.k9 files checked: $(wc -l < "$RUNNER_TEMP/coord-results.jsonl")"
}

cmd_previous() {
  set -euo pipefail
  # Best effort: the caller's posting account writes the grid under
  # this marker and regenerates it in place, so its last comment
  # carrying the marker is the previous revision's grid and baseline.
  # Only that account's comments count: anyone who can comment could
  # otherwise plant a marker and a forged baseline. Any failure here
  # only costs the "since previous revision" column.
  : > "$RUNNER_TEMP/previous.md"
  page=1
  while [ "$page" -le 10 ]; do
    if ! curl -sSf --retry 2 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
         "$COMMENTS_URL?per_page=100&page=$page" > "$RUNNER_TEMP/comments.json"; then
      echo "::notice::could not read the pull request comments; the delta column reports no comparable baseline"
      break
    fi
    jq -r --arg m "$MARKER" --arg a "$GRID_AUTHOR" \
      '[.[] | select((.user.login // "") == $a and ((.body // "") | contains($m)))] | last | .body // empty' \
      "$RUNNER_TEMP/comments.json" > "$RUNNER_TEMP/previous-page.md"
    [ -s "$RUNNER_TEMP/previous-page.md" ] && mv "$RUNNER_TEMP/previous-page.md" "$RUNNER_TEMP/previous.md"
    [ "$(jq length "$RUNNER_TEMP/comments.json")" -eq 100 ] || break
    page=$((page + 1))
  done
  [ -s "$RUNNER_TEMP/previous.md" ] && echo "previous grid found" || echo "no previous grid"
}

cmd_render() {
  set -euo pipefail
  ledger=.machine_readable/k9-contract-debt.txt
  args=(--out "$RUNNER_TEMP/k9-grid" --results "$RUNNER_TEMP/results.jsonl" --expected "$RUNNER_TEMP/expected"
        --changed "$RUNNER_TEMP/changed" --selftest "$RUNNER_TEMP/selftest.log" --selftest-code "$SELFTEST_CODE"
        --typecheck "$RUNNER_TEMP/typecheck.log" --typecheck-code "$TYPECHECK_CODE" --corpus-code "$CORPUS_CODE"
        --sha "$HEAD_SHA" --run "$GITHUB_RUN_ID" --url "$RUN_URL" --pr "$PR_NUMBER" --repo "$GITHUB_REPOSITORY"
        --canon-ref "$CANON_REF")
  [ -f "$ledger" ] && args+=(--ledger "$ledger")
  [ -s "$RUNNER_TEMP/ledger-growth" ] && args+=(--ledger-growth "$RUNNER_TEMP/ledger-growth")
  [ -s "$RUNNER_TEMP/previous.md" ] && args+=(--previous "$RUNNER_TEMP/previous.md")
  [ -n "${BASE_UNRESOLVED:-}" ] && args+=("$BASE_UNRESOLVED")
  [ -f "$RUNNER_TEMP/coord-results.jsonl" ] && args+=(--coord-results "$RUNNER_TEMP/coord-results.jsonl")
  # With require-files the empty corpus is a failing row in the grid
  # itself, so report.md and badge.json carry the red the job reports.
  [ "$REQUIRE_FILES" = "true" ] && args+=(--require-files)
  bash "$CANON/scripts/k9-grid.sh" render "${args[@]}"
  cp "$RUNNER_TEMP/selftest.log" "$RUNNER_TEMP/typecheck.log" "$RUNNER_TEMP/results.jsonl" "$RUNNER_TEMP/k9-grid/"
  [ -f "$RUNNER_TEMP/coord-results.jsonl" ] && cp "$RUNNER_TEMP/coord-results.jsonl" "$RUNNER_TEMP/k9-grid/"
  [ -f "$RUNNER_TEMP/corpus.log" ] && cp "$RUNNER_TEMP/corpus.log" "$RUNNER_TEMP/k9-grid/"
}

cmd_gate() {
  set -euo pipefail
  echo "K9 verdict grid: $STATE"
  if [ "$ADVISORY" = "true" ]; then
    # A failed checkout leaves an empty workspace that grades grey; say so.
    if [ "${CHECKOUT_OUTCOME:-}" = failure ] || [ "${CANON_OUTCOME:-}" = failure ]; then
      echo "::warning::K9 conformance (advisory): a checkout step failed, so conformance did not run; not enforced."
      exit 0
    fi
    # Advisory: say what would have failed, never fail.
    case "$STATE" in
      red) echo "::warning::K9 conformance (advisory): the grid is red; not enforced. See the k9-grid artifact and the step summary." ;;
      orange) echo "::warning::K9 conformance (advisory): indeterminate, evidence is missing; not enforced." ;;
      yellow) echo "::notice::K9 conformance passes with ledgered debt or warnings" ;;
      green|grey) ;;
      *) echo "::warning::K9 conformance (advisory): no verdict was produced (an earlier step did not complete); not enforced." ;;
    esac
    exit 0
  fi
  case "$STATE" in
    red) echo "::error::K9 conformance failed; see the k9-grid artifact and the step summary"; exit 1 ;;
    orange)
      if [ "$FAIL_ON_INDETERMINATE" = "true" ]; then
        echo "::error::K9 conformance is indeterminate and fail-on-indeterminate is set"; exit 1
      fi
      echo "::warning::K9 conformance is indeterminate: evidence is missing, not clean" ;;
    yellow) echo "::notice::K9 conformance passes with ledgered debt or warnings" ;;
    green|grey) ;;
    *) echo "::error::no verdict was produced"; exit 1 ;;
  esac
}

case "${1:-}" in
  selftest|typecheck|enumerate|validate|coord|previous|render|gate) "cmd_$1" ;;
  *) sed -n '5,24p' "$0" >&2; exit 2 ;;
esac
