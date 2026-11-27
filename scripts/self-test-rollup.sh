#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# self-test-rollup.sh — the decision behind the "Repo self-tests" roll-up job.
#
# Passes only when both shards report `success`. The one softening: on a
# pull_request, a cancelled shard is not a test result when the run was
# SUPERSEDED, i.e. the PR's head SHA now differs from the SHA this run tested.
# `cancel-in-progress` makes that happen on every newer push.
#
# Soundness: a skipped required check counts as passing, so this never skips,
# and it exits 0 on cancellation ONLY after proving a newer head exists. A
# cancelled shard on the current head, any `failure`, an unknown result, a
# missing input or a failed head lookup all exit non-zero.
#
# Inputs (environment):
#   LIGHT HEAVY        shard results (needs.<job>.result)
#   EVENT_NAME         github.event_name
#   PR_NUMBER          github.event.pull_request.number
#   RUN_HEAD_SHA       github.event.pull_request.head.sha
#   REPO               github.repository
#   GH_TOKEN           github.token (pull-requests: read)
#   PR_HEAD_CMD        test seam: command that prints the PR's current head SHA;
#                      default is `gh api repos/$REPO/pulls/$PR_NUMBER --jq .head.sha`
set -uo pipefail

light=${LIGHT:-}
heavy=${HEAVY:-}
echo "tests-light: $light"
echo "tests-heavy: $heavy"

if [ "$light" = success ] && [ "$heavy" = success ]; then
  exit 0
fi

# Anything but a cancelled shard stays a plain failure.
for r in "$light" "$heavy"; do
  case "$r" in
    success|cancelled) ;;
    *) echo "FAIL: a shard reported '$r'" >&2; exit 1 ;;
  esac
done

# At least one shard is cancelled and none failed.
if [ "${EVENT_NAME:-}" != pull_request ]; then
  echo "FAIL: shard cancelled on a ${EVENT_NAME:-unknown} event; only a superseded pull_request run is excused" >&2
  exit 1
fi
if [ -z "${RUN_HEAD_SHA:-}" ] || [ -z "${PR_NUMBER:-}" ]; then
  echo "FAIL: shard cancelled and the run's PR head or number is unknown" >&2
  exit 1
fi

if [ -n "${PR_HEAD_CMD:-}" ]; then
  now=$(bash -c "$PR_HEAD_CMD") || now=""
else
  now=$(gh api "repos/${REPO:?REPO unset}/pulls/${PR_NUMBER}" --jq .head.sha) || now=""
fi
if ! [[ "$now" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FAIL: could not read the PR's current head SHA (got '${now}'); not excusing the cancellation" >&2
  exit 1
fi

if [ "$now" != "$RUN_HEAD_SHA" ]; then
  echo "superseded by $now; not a test result (this run tested $RUN_HEAD_SHA)"
  exit 0
fi

echo "FAIL: shard cancelled but $RUN_HEAD_SHA is still the PR head; the head is untested" >&2
exit 1
