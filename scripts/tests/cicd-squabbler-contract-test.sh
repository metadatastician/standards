#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# cicd-squabbler-contract-test.sh — the CI wiring of cicd-squabbler must
# preserve the tool's one invariant (squabble != bypass) at the workflow
# layer, where a well-meaning edit could quietly break it:
#
#   * CI must never pass --apply (propose-only; enactment is a human commit);
#   * the binary must come from the pinned composite action (40-hex commit),
#     never a tag, a branch, or an ad-hoc download;
#   * chains exit 4 (cycle / dead upstream) must fail the job — demoting it
#     to a warning would make the gate advisory in exactly the case it
#     exists for;
#   * generic tool failures (exit 2) must fail too, or a broken advisor
#     reads as an all-clear; downgrade to NOT EVALUATED only when the
#     credential preflight cannot see the whole gate, or the pinned
#     upstream emits its exact hidden-classic-protection wording;
#   * no job may hold a write grant, no secrets may be inherited, and the
#     only declared secret is the optional Administration-read credential
#     that fight needs to see classic branch protection — absent it the
#     advisory says NOT RUN, and with insufficient visibility it says
#     NOT EVALUATED, rather than failing or passing blind;
#   * the caller must carry no paths: filter (a filtered gate never
#     reports on PRs that miss the filter);
#   * both workflows must be present in actions.lock, or GitHub refuses
#     the run at startup and the gate vanishes silently.
#
# Structural (grep) assertions, no network: this is a contract about the
# files, exercised wherever bash runs.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
reusable="$root/.github/workflows/cicd-squabbler-reusable.yml"
caller="$root/.github/workflows/cicd-squabbler.yml"
lock="$root/.github/workflows/actions.lock"
pass=0; fail=0

t() { # label condition...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS $label"
  else fail=$((fail+1)); echo "FAIL $label"; fi
}
# -e is load-bearing: patterns like `--apply` would otherwise be parsed as
# grep flags, making the `lacks` assertions pass without checking anything.
has()   { grep -qF -e "$2" "$1"; }
hasre() { grep -qE -e "$2" "$1"; }
lacks() { ! grep -qF -e "$2" "$1"; }

for f in "$reusable" "$caller" "$lock"; do
  t "exists: ${f##*/}" test -f "$f"
done

# Pinned install, and only pinned installs.
t "squabble action is commit-pinned" hasre "$reusable" \
  'uses: hyperpolymath/cicd-squabbler/\.github/actions/squabble@[0-9a-f]{40}'
t "no tag/branch squabble ref" lacks "$reusable" 'squabble@main'
t "no tag-pinned squabble ref" lacks "$reusable" 'squabble@v'
t "no ad-hoc binary download" lacks "$reusable" 'releases/download'

# Propose-only, forever, from CI. Comment lines are stripped first: the
# workflows explain the rule using the very flag they forbid, and the
# explanation must not read as the offence.
noflag() { local body; body=$(grep -v '^[[:space:]]*#' "$1"); ! grep -qF -e "$2" <<<"$body"; }
# Firing fixture first: the matcher must SEE a planted --apply, or the
# assertions below could pass blind (they once did — grep parsed the
# pattern as a flag). Silence fixture: a comment mentioning it is fine.
planted="$(mktemp)"; trap 'rm -f "$planted"' EXIT
printf '      - run: squabble fight o/r 1 --apply\n' > "$planted"
if noflag "$planted" '--apply'; then
  fail=$((fail+1)); echo "FAIL matcher is blind to a planted --apply"
else
  pass=$((pass+1)); echo "PASS matcher sees a planted --apply"
fi
printf '      # never passes --apply from CI\n' > "$planted"
t "matcher ignores --apply in comments" noflag "$planted" '--apply'
t "reusable never passes --apply" noflag "$reusable" '--apply'
t "caller never passes --apply" noflag "$caller" '--apply'
t "reusable never summons boj experts" noflag "$reusable" '--summon'

# The exit-code contract (squabble-cli: 2 tool failure, 3 no gate,
# 4 blocking chain finding) is honoured, not flattened.
t "chains exit 4 fails the job" has "$reusable" 'if [ "$rc" -eq 4 ]'
t "chains other non-zero fails the job" has "$reusable" 'squabble chains failed to run'
t "generic fight exit 2 still fails the job" has "$reusable" \
  'squabble fight failed to run'
t "preflight reads the pull request base" has "$reusable" \
  'gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName'
t "preflight reads the branch rules endpoint" has "$reusable" \
  'repos/$REPO/rules/branches/$encoded_base_ref'
t "preflight reads classic branch protection" has "$reusable" \
  'repos/$REPO/branches/$encoded_base_ref/protection'
t "classic 404 is visible evidence of no classic gate" has "$reusable" \
  'HTTP 404|Branch not protected'
t "pinned hidden-gate wording remains a fallback downgrade" has "$reusable" \
  'classic branch protection on this branch is not visible to this token'
t "hidden gate is an explicit NOT EVALUATED" has "$reusable" \
  'Squabble fight report — NOT EVALUATED'
t "hidden gate does not redden the advisory" has "$reusable" \
  'title=Squabble fight not evaluated'
t "fight exit 3 is a warning, not a failure" has "$reusable" 'if [ "$rc" -eq 3 ]'
t "fight refuses a non-numeric PR number" has "$reusable" '*[!0-9]*'

# Least privilege: no write scope anywhere, no secret inheritance, and at
# most one declared secret — fight's optional Administration-read
# credential. "No secrets at all" was the rule until fight was measured
# to need classic-branch-protection visibility that the built-in token
# cannot have; the narrow, declared exception is the contract now.
t "reusable holds no write grant" lacks "$reusable" ': write'
t "caller holds no write grant" lacks "$caller" ': write'
# Comment-aware (noflag): the workflows explain the inherit ban in prose
# using the very string they forbid, exactly like --apply above.
t "caller does not inherit secrets" noflag "$caller" 'secrets: inherit'
t "reusable does not inherit secrets" noflag "$reusable" 'secrets: inherit'
t "reusable references no GITHUB_TOKEN secret" lacks "$reusable" 'secrets.GITHUB_TOKEN'
t "reusable declares the optional Administration-read secret" has "$reusable" \
  'ADMINISTRATION_READ_TOKEN:'
t "fight credential is not required" bash -c \
  'b=$(grep -A3 "ADMINISTRATION_READ_TOKEN:" "$1"); grep -q "required: false" <<<"$b"' _ "$reusable"
t "caller maps only the estate Administration-read PAT" has "$caller" \
  'ADMINISTRATION_READ_TOKEN: ${{ secrets.HYPATIA_SCAN_PAT }}'
t "caller declares no secret beyond the Administration-read PAT" bash -c \
  'test "$(sed -n "/^    secrets:/,/^    [A-Za-z_]/p" "$1" | grep -cE "^      [A-Za-z_][A-Za-z0-9_]*:")" -eq 1' _ "$caller"
t "absent fight credential is an explicit NOT RUN" has "$reusable" \
  'Squabble fight report — NOT RUN'
t "credentialed fight steps are visibility-gated" has "$reusable" \
  "steps.fight-credential.outputs.available == 'true'"
t "fight no longer uses a presence-only credential output" lacks "$reusable" \
  'outputs.supplied'
t "fight talks to the API with the declared credential" has "$reusable" \
  'GH_TOKEN: ${{ secrets.ADMINISTRATION_READ_TOKEN }}'
t "secret-touching fight job installs pinned harden-runner" hasre "$reusable" \
  'uses: step-security/harden-runner@[0-9a-f]{40}'
t "harden-runner audits egress" has "$reusable" 'egress-policy: audit'
t "checkouts do not persist credentials" has "$reusable" 'persist-credentials: false'

# Gate shape: unfiltered, cancellable, time-boxed.
# Anchored to an indented YAML key: the prose "no `paths:` filter" in the
# header is the explanation of this rule, not a violation of it.
t "caller has no paths filter" bash -c '! grep -qE "^[[:space:]]+paths(-ignore)?:" "$1"' _ "$caller"
t "caller has concurrency" has "$caller" 'cancel-in-progress: true'
t "reusable jobs are time-boxed" has "$reusable" 'timeout-minutes: 10'
t "caller calls the local reusable" has "$caller" \
  'uses: ./.github/workflows/cicd-squabbler-reusable.yml'

# The lock knows both files, with the subpath normalised to repo@sha.
t "lock lists the reusable" has "$lock" "'.github/workflows/cicd-squabbler-reusable.yml':"
t "lock lists the caller as pin-free" has "$lock" "'.github/workflows/cicd-squabbler.yml': []"
t "lock records the squabbler pin" hasre "$lock" \
  "'hyperpolymath/cicd-squabbler@[0-9a-f]{40}'"
t "lock lists harden-runner for the squabbler reusable" bash -c \
  'b=$(grep -A4 "cicd-squabbler-reusable.yml" "$1"); grep -q "step-security/harden-runner@" <<<"$b"' _ "$lock"

# The pin in the workflow and the pin in the lock are the same commit, or
# one of them is stale and the run dies at startup.
wf_pin="$(grep -oE 'squabble@[0-9a-f]{40}' "$reusable" | head -1 | cut -d@ -f2)"
lock_pin="$(grep -oE "cicd-squabbler@[0-9a-f]{40}" "$lock" | head -1 | cut -d@ -f2)"
t "workflow pin equals lock pin" test "$wf_pin" = "$lock_pin"

# A full-SHA lock key must record a containing branch/tag in `ref:`; when
# `ref:` repeats the SHA, GitHub rejects the action at job setup as an
# "invalid lockfile pin" (standards#1271, measured on this workflow).
lock_ref="$(grep -A1 -F "'hyperpolymath/cicd-squabbler@$wf_pin':" "$lock" \
  | sed -n "s/.*ref: '\([^']*\)'.*/\1/p" | head -1)"
t "lock recorded ref is not the pin SHA" \
  bash -c '[ -n "$1" ] && [ "$1" != "$2" ] && ! grep -qE "^[0-9a-f]{40}$" <<<"$1"' \
  _ "$lock_ref" "$wf_pin"

printf '\ncicd-squabbler contract tests: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
