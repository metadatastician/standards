#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The doctor must end stdout with `name: N PASS, N WARN, N FAIL` even when
# `timeout` and `gtimeout` are both missing (the FAIL is recorded, not an early return).
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
engine="${1:-$root/templates/build/just/provision-lib.sh}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/repository with spaces"
# A PATH holding every command the host has except the two bounding ones.
for d in /usr/local/bin /usr/bin /bin; do
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b=${f##*/}
    case $b in timeout|gtimeout) continue ;; esac
    [ -e "$work/bin/$b" ] || ln -s "$f" "$work/bin/$b"
  done
done
cd "$work/repository with spaces"
rc=0
out=$(PATH="$work/bin" PROVISION_ROOT="$PWD" "$BASH" "$engine" doctor 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || { echo 'doctor passed without timeout/gtimeout' >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'PV-E42' || { echo 'PV-E42 not reported' >&2; exit 1; }
last=$(printf '%s\n' "$out" | tail -1)
case $last in
  *': '*' PASS, '*' WARN, '*' FAIL'*) ;;
  *) printf 'last stdout line is not the tally: <%s>\n' "$last" >&2; exit 1 ;;
esac
printf '%s\n' "$last" | grep -Eq ', [^0-9]*[1-9][0-9]* FAIL' || { echo 'tally does not count the FAIL' >&2; exit 1; }
printf 'passed 3 doctor-summary controls\n'
