#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# test_workflow_unique_keys.sh: no mapping in any workflow under
# .github/workflows/ repeats a key.
#
# Why: GitHub refuses a workflow whose mapping repeats a key ("'only' is
# already defined"), and the refusal surfaces only when the workflow is
# triggered: a dispatch answers HTTP 422 and nothing runs. On 2026-11-14 a
# squash merge (#1574 over #1572) left apply-workflow-pins.yml with two `only`
# dispatch inputs; every other check stayed green, because a YAML parser that
# keeps the last value reads such a file without complaint. mikefarah yq lists
# every key, duplicates included, so the check compares each mapping's keys
# with their unique set. It runs on the real tree, then on planted copies that
# must fail (a duplicate dispatch input, a duplicate step key), so it cannot
# pass by reading nothing.
#
# Exit: 0 every workflow is clean; 1 a duplicate key (or a control failed);
# 2 NOT RUN (mikefarah yq missing, or no workflows found).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v yq >/dev/null && yq --version 2>/dev/null | grep -q mikefarah ||
  { echo "test_workflow_unique_keys: mikefarah yq missing; NOT RUN" >&2; exit 2; }

# dups FILE: one line per mapping that repeats a key: "<path>: <key> ...".
dups() {
  yq -r '.. | select(tag == "!!map") | . as $m
         | ($m | keys) as $k
         | select(($k | length) != ($k | unique | length))
         | (path | join(".")) + ": " + ($k | group_by(.) | map(select(length > 1) | .[0]) | join(" "))' "$1"
}

shopt -s nullglob
files=("$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml)
[[ ${#files[@]} -gt 0 ]] || { echo "test_workflow_unique_keys: no workflows under .github/workflows; NOT RUN" >&2; exit 2; }
fail=0
for f in "${files[@]}"; do
  out=$(dups "$f") || { echo "FAIL ${f#"$root/"}: yq could not parse it"; fail=1; continue; }
  [[ -z $out ]] || { echo "FAIL ${f#"$root/"} repeats a key: $out"; fail=1; }
done
[[ $fail == 0 ]] && echo "ok: ${#files[@]} workflows, no mapping repeats a key"

# Controls: each planted duplicate must be found.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/dup-input.yml" <<'YML'
on:
  workflow_dispatch:
    inputs:
      only:
        default: ''
      mode:
        default: audit
      only:
        default: ''
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
cat > "$tmp/dup-step.yml" <<'YML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: one
        run: true
        name: two
YML
cat > "$tmp/clean.yml" <<'YML'
on:
  workflow_dispatch:
    inputs:
      only:
        default: ''
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
for c in dup-input dup-step; do
  if [[ $(dups "$tmp/$c.yml") == *only* || $(dups "$tmp/$c.yml") == *name* ]]; then echo "ok: control $c is found"
  else echo "FAIL control $c: a planted duplicate key was not found"; fail=1; fi
done
[[ -z $(dups "$tmp/clean.yml") ]] && echo "ok: control clean.yml has no duplicate" || { echo "FAIL control clean.yml reported a duplicate"; fail=1; }
exit "$fail"
