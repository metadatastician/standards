#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# test_mirror_ssh_agent.sh: every native ssh-agent the mirror reusable starts
# is stopped by an always-run step in the same job, and every key load handles
# a secret holding several PEM blocks (standards#1700, Codex P1 and P2).
#
# Exit: 0 clean; 1 a job leaks its agent or loads only one key; 2 NOT RUN.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
f="$root/.github/workflows/mirror-reusable.yml"
[[ -f $f ]] || { echo "test_mirror_ssh_agent: $f missing; NOT RUN" >&2; exit 2; }

# check FILE: print one failure line per problem, nothing when clean.
check() {
  awk '
    /^  [a-z0-9-]+:$/ { job=$1; start[job]=0; stop[job]=0; multi[job]=0 }
    /ssh-agent -s/ { start[job]++; jobs[job]=1 }
    /read -r -d .. block/ { multi[job]++ }
    /name: Stop SSH agent/ { want=1; next }
    want && /always\(\)/ { stop[job]++ ; want=0 }
    END {
      n=0
      for (j in jobs) {
        n++
        if (stop[j] < start[j]) print "FAIL " j ": ssh-agent started but no always() Stop SSH agent step"
        if (multi[j] < start[j]) print "FAIL " j ": key load does not iterate over every PEM block"
      }
      if (n == 0) print "FAIL no ssh-agent job found (test reads nothing)"
    }' "$1"
}

out=$(check "$f")
[[ -z $out ]] || { echo "$out"; exit 1; }

# Controls: planted copies must fail, so the check cannot pass by reading nothing.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sed '/name: Stop SSH agent/,+4d' "$f" > "$tmp/no-stop.yml"
[[ -n $(check "$tmp/no-stop.yml") ]] || { echo "FAIL control: missing teardown not detected"; exit 1; }
sed 's/read -r -d .. block/read -r block/' "$f" > "$tmp/one-key.yml"
[[ -n $(check "$tmp/one-key.yml") ]] || { echo "FAIL control: single-key load not detected"; exit 1; }
echo "ok: every mirror ssh-agent is stopped always() and loads every PEM block"
