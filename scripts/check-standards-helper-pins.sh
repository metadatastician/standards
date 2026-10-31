#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-standards-helper-pins.sh — every checkout of THIS repository from a
# shared workflow must name the commit it came from.
#
# WHY THIS EXISTS
# ---------------
# A reusable workflow that runs a helper out of `metadatastician/standards`
# has to say WHICH standards. Three answers are possible, and only two of them
# are answers:
#
#   ref: ${{ job.workflow_sha }}          the reusable's OWN commit — the one
#                                         the caller's `uses:` resolved to.
#                                         Pinned by construction; cannot rot.
#   ref: <40 hex>                          an immutable literal. It cannot
#                                         move, but it CAN be left behind: a
#                                         helper changed on main never reaches
#                                         a caller, and a PR that fixes a
#                                         helper cannot test it (its own merge
#                                         commit does not exist yet).
#   ref: main / a branch / a tag /        a float. One push to standards
#   github.sha / github.workflow_sha /    silently changes the behaviour of
#   an empty ref (actions/checkout        every already-pinned caller, with
#   then loads the default branch)        no review in their repository.
#
# MEASURED (2026-10-31, main 1725bebd): `governance-reusable.yml` staged its
# policy helpers, its duplicate-key linter and its pin-existence gate from the
# literal `317101e03b8fe642589498f4bdb84541ab466062` (2026-09-14) — while main
# had moved 202 files (+29,544/-1,736 lines) under `scripts/`. Consumers were
# being judged by six-week-old gate code: `check-action-pins-resolve.sh` had
# since gained the orphan-pin/ancestry probe (+158/-13, issue #782) and
# `check-workflow-duplicate-keys.sh` the KYAML normalisation that stopped 14
# phantom duplicate reports (2026-10-01). Nothing noticed, because standards
# runs its OWN tree in those steps (`GITHUB_REPOSITORY` self-lint) and every
# consumer inherits the freeze. That is the third-pin class standards#946 and
# #1119 already cured once for the lock gate; this guard is the general form.
#
# `github.workflow_sha` / `github.workflow_ref` are REFUSED rather than
# accepted: inside a called reusable workflow the `github` context belongs to
# the CALLER, so those name the caller's commit, and the checkout fails with
# "No commit found for SHA". `github.job_workflow_sha` is refused because it
# does not exist (the workflow-identity properties live on the `job` context;
# they are documented as unavailable on GitHub Enterprise Server, which is why
# the consuming steps assert the resolved value is 40-hex before using it).
#
# WHAT THIS DOES NOT DO
#   * It does not prove a literal pin is safe to run, only that it contains
#     what `--compare` names over the paths the step stages.
#   * It does not check `git clone … standards.git` inside a `run:` body, an
#     actions/checkout without `with.repository`, or a job-level reusable
#     call. Those are different shapes and are called out in the migration
#     note rather than silently declared covered.
#   * It does not decide policy: a literal pin that is fresh today passes.
#
# EXIT
#   0 = every standards checkout is pinned (and, with --compare, fresh)
#   1 = at least one floating or stale standards checkout
#   2 = NOT INSPECTED (no yq/jq, no workflow directory, nothing examined)
#
# USAGE
#   check-standards-helper-pins.sh [WORKFLOWS_DIR] [--compare REF]
#   --compare REF   additionally require each literal pin to contain REF over
#                   the paths that step stages (default: off, so the guard is
#                   usable on a shallow clone)
#
# TESTS: scripts/tests/check-standards-helper-pins-test.sh
set -uo pipefail

WF_DIR=".github/workflows"
COMPARE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --compare) COMPARE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) WF_DIR="$1"; shift ;;
  esac
done

not_inspected() { echo "::error::$* — NOT INSPECTED, which is not a pass." >&2; exit 2; }

command -v yq >/dev/null 2>&1 || not_inspected "yq not found (mikefarah yq v4 required; YAML-POLICY Y-1)"
yq --version 2>/dev/null | grep -q mikefarah || not_inspected "yq on PATH is not mikefarah yq v4"
command -v jq >/dev/null 2>&1 || not_inspected "jq not found"
[ -d "$WF_DIR" ] || not_inspected "workflow directory not found: $WF_DIR"

if [ -n "$COMPARE" ]; then
  git rev-parse --verify --quiet "$COMPARE^{commit}" >/dev/null ||
    not_inspected "compare ref '$COMPARE' is not resolvable in this clone"
fi

fail=0
sites=0
files=0
unparsed=""

for wf in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  [ -f "$wf" ] || continue
  files=$((files + 1))
  json="$(yq -o json -I 0 '.' "$wf" 2>&1)" || {
    unparsed="$unparsed  $wf: $(printf '%s' "$json" | head -1)"$'\n'
    continue
  }
  # One node per standards checkout. `uses` is matched on the resolved action,
  # so a sub-path (actions/checkout/...) is covered too, and `repository` is
  # compared case-insensitively exactly as GitHub treats owner/repo.
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    sites=$((sites + 1))
    job="$(jq -r '.job' <<<"$node")"
    step="$(jq -r '.step' <<<"$node")"
    ref="$(jq -r '.ref' <<<"$node")"
    paths="$(jq -r '.paths' <<<"$node")"
    label="${wf#./} :: ${job} / ${step}"
    case "$ref" in
      '') echo "::error file=$wf::$label: standards checkout has no 'ref' — actions/checkout follows the DEFAULT BRANCH, so this is a float, not a pin." >&2
          fail=$((fail + 1)); continue ;;
      *'${{ job.workflow_sha }}'*) echo "  ok ${label}: job.workflow_sha (this reusable's own commit)"; continue ;;
      *'${{ inputs.'*'|| job.workflow_sha }}'*) echo "  ok ${label}: caller override with a pinned job.workflow_sha fallback"; continue ;;
      *'${{'*)
          echo "::error file=$wf::$label: ref '$ref' is an expression that does not resolve to THIS reusable's commit. github.sha/github.workflow_sha/github.workflow_ref name the CALLER's commit (checkout fails: 'No commit found for SHA'); github.job_workflow_sha does not exist; a bare input can be a branch. Use \${{ job.workflow_sha }} or a 40-hex commit." >&2
          fail=$((fail + 1)); continue ;;
    esac
    if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
      echo "::error file=$wf::$label: ref '$ref' is not an immutable 40-hex commit. A branch or tag here lets one push to standards change the behaviour of every already-pinned caller." >&2
      fail=$((fail + 1)); continue
    fi
    if [ -z "$COMPARE" ]; then
      echo "  ok ${label}: immutable literal ${ref:0:12} (freshness not requested; pass --compare to judge it)"
      continue
    fi
    if ! git cat-file -e "${ref}^{commit}" 2>/dev/null; then
      git fetch --quiet --depth=1 origin "$ref" 2>/dev/null || true
    fi
    if ! git cat-file -e "${ref}^{commit}" 2>/dev/null; then
      echo "::error file=$wf::$label: pinned commit $ref is not present and could not be fetched — an unverifiable pin is not a verified one." >&2
      fail=$((fail + 1)); continue
    fi
    # The staged scope is the guarded scope; a step that stages nothing is
    # judged over the whole tree, because that is what it runs.
    scope="${paths:-.}"
    # shellcheck disable=SC2086
    diverged="$(git diff --name-only "$ref" "$COMPARE" -- $scope 2>/dev/null)"
    if [ -n "$diverged" ]; then
      echo "::error file=$wf::$label: staged from $ref, which does NOT contain what is on $COMPARE over: $(printf '%s ' $scope)" >&2
      printf '%s\n' "$diverged" | sed 's/^/      stale: /' >&2
      echo "      Every caller is being judged by that older tooling. Set ref: \${{ job.workflow_sha }} (or a commit containing $COMPARE) in this PR." >&2
      fail=$((fail + 1))
    else
      echo "  ok ${label}: literal ${ref:0:12} contains $COMPARE over: $(printf '%s ' $scope)"
    fi
  done < <(printf '%s' "$json" | jq -c '
    .jobs // {} | to_entries[] | .key as $job | (.value | (.steps // [])) | to_entries[] |
    (.value | (.with // {})) as $w |
    select($w.repository != null) |
    select(($w.repository | ascii_downcase) | test("^(metadatastician|hyperpolymath)/standards$")) |
    select((.value.uses // "") | test("checkout")) |
    { job: $job,
      step: (.value.name // "(unnamed step)"),
      ref: (($w.ref // "") | tostring),
      paths: (($w["sparse-checkout"] // "") | tostring) }
  ')
done

if [ -n "$unparsed" ]; then
  echo "::error::these workflows could not be parsed, so their standards checkouts went UNEXAMINED:" >&2
  printf '%s' "$unparsed" >&2
  fail=$((fail + 1))
fi
[ "$files" -gt 0 ] || not_inspected "no workflow files in $WF_DIR"

# A parse failure is already a failure: never let the vacuous-population path
# below report a clean run over it.
if [ "$fail" -ne 0 ]; then
  echo "examined $files workflow file(s) in $WF_DIR: ${sites} standards helper checkout(s); failures: ${fail}"
  exit 1
fi

if [ "$sites" -eq 0 ]; then
  # Stated, not implied. Zero sites is a legitimate state for a directory of
  # workflows that call no standards helper, but a reader must be able to see
  # that the guard examined nothing rather than inferring a green.
  echo "examined $files workflow file(s) in $WF_DIR: no standards helper checkout found (0 sites)."
  echo "PASS (vacuous population, stated)."
  exit 0
fi

echo "examined $files workflow file(s) in $WF_DIR: ${sites} standards helper checkout(s); failures: ${fail}"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: every standards helper checkout names an immutable commit."
exit 0
