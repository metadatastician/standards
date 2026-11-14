#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-new-a2ml-test.sh — fixture suite for scripts/check-no-new-a2ml.sh.
#
# Each case builds a two-commit repository (base, then the change) and checks
# the gate's verdict. Cases cover every git status the gate reads: A, R from
# a non-A2ML path, R between A2ML paths, C, M and D.
#
# Run: bash scripts/tests/check-no-new-a2ml-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-no-new-a2ml.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      $(printf '%s' "$out" | tail -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — exit ok, output lacked '$needle'"
    echo "      $(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

g() { git -C "$d" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# base <name>: a repository whose base commit holds one legacy A2ML file and
# one ordinary file. Leaves $d set; the change is made by the caller, then
# committed with `change`.
base() {
  d="$WORK/$1"; mkdir -p "$d/.machine_readable"
  git init -q "$d"
  printf 'legacy = "content"\nmore = "lines so rename detection has text"\n' > "$d/.machine_readable/LEGACY.a2ml"
  printf 'plain text file\nwith two lines\n' > "$d/notes.txt"
  g add -A && g commit -qm base
}
change() { g add -A && g commit -qm change; }

echo "=== nothing added ==="
base clean; printf 'x\n' > "$d/README.adoc"; change
assert "a change with no A2ML passes" 0 "no-new-a2ml: OK" bash "$GATE" HEAD~1 HEAD "$d"
base edit; printf 'legacy = "trimmed"\n' > "$d/.machine_readable/LEGACY.a2ml"; change
assert "editing an existing A2ML file passes" 0 "no-new-a2ml: OK" bash "$GATE" HEAD~1 HEAD "$d"
base delete; g rm -q .machine_readable/LEGACY.a2ml; change
assert "deleting an A2ML file passes" 0 "no-new-a2ml: OK" bash "$GATE" HEAD~1 HEAD "$d"
base archive; mkdir -p "$d/9-archive/a2ml"; g mv .machine_readable/LEGACY.a2ml 9-archive/a2ml/LEGACY.a2ml; change
assert "moving an A2ML file into 9-archive/ fails (owner ruling 2026-11-14)" 1 "file=9-archive/a2ml/LEGACY.a2ml::" bash "$GATE" HEAD~1 HEAD "$d"
base movesame; g mv .machine_readable/LEGACY.a2ml .machine_readable/RENAMED.a2ml; change
assert "renaming an A2ML file in place fails, and names the old path" 1 "from .machine_readable/LEGACY.a2ml" bash "$GATE" HEAD~1 HEAD "$d"
base deed; printf ';; SPDX-License-Identifier: MPL-2.0\n' > "$d/x_chora.deed"; printf 'x\n' > "$d/notes.a2ml.md"; change
assert "a .deed and a name that only contains .a2ml pass" 0 "no-new-a2ml: OK" bash "$GATE" HEAD~1 HEAD "$d"

echo "=== additions ==="
base add; printf 'x\n' > "$d/.machine_readable/CLADE.a2ml"; change
assert "a new .a2ml fails and is named" 1 "file=.machine_readable/CLADE.a2ml::" bash "$GATE" HEAD~1 HEAD "$d"
base tmpl; printf 'x\n' > "$d/META.a2ml.template"; printf 'x\n' > "$d/STATE.a2ml.v2.template"; printf 'x\n' > "$d/X.a2ml.in"; change
assert "template and .in spellings fail, all three counted" 1 "3 A2ML file(s) at a new path" bash "$GATE" HEAD~1 HEAD "$d"
base renin; g mv notes.txt notes.a2ml; change
assert "renaming a non-A2ML file to .a2ml fails" 1 "R100 from notes.txt" bash "$GATE" HEAD~1 HEAD "$d"
base copy; cp "$d/.machine_readable/LEGACY.a2ml" "$d/COPY.a2ml"; printf 'touched\n' >> "$d/.machine_readable/LEGACY.a2ml"; change
assert "copying an A2ML file to a new A2ML path fails" 1 "file=COPY.a2ml::" bash "$GATE" HEAD~1 HEAD "$d"
base spaced; printf 'x\n' > "$d/with space.a2ml"; change
assert "an unusual name is reported unquoted" 1 "file=with space.a2ml::" bash "$GATE" HEAD~1 HEAD "$d"
base twocommits; printf 'x\n' > "$d/A.a2ml"; change; g rm -q A.a2ml; change
assert "an A2ML file added then removed within the range passes" 0 "no-new-a2ml: OK" bash "$GATE" HEAD~2 HEAD "$d"

echo "=== measured from the merge base ==="
# The base branch deletes the legacy file after the PR branched. Diffed BASE
# to HEAD, the PR branch's untouched copy would read as an addition.
base basedel; g branch -q pr; g rm -q .machine_readable/LEGACY.a2ml; change
g checkout -q pr; printf 'x\n' > "$d/README.adoc"; change
assert "a file the base deleted after branching is not the PR's addition" 0 "no-new-a2ml: OK" bash "$GATE" "$(g rev-parse master 2>/dev/null || g rev-parse main)" HEAD "$d"
base basedel2; g branch -q pr; g rm -q .machine_readable/LEGACY.a2ml; change
g checkout -q pr; printf 'x\n' > "$d/NEW.a2ml"; change
assert "a real addition on a branch behind its base still fails" 1 "file=NEW.a2ml::" bash "$GATE" "$(g rev-parse master 2>/dev/null || g rev-parse main)" HEAD "$d"
base unrelated; g checkout -q --orphan other; g rm -rqf . ; printf 'x\n' > "$d/x.txt"; g add -A && g commit -qm orphan
assert "BASE and HEAD with no merge base is a setup error" 2 "no merge base" bash "$GATE" "$(g rev-parse master 2>/dev/null || g rev-parse main)" HEAD "$d"

echo "=== fails closed when git diff cannot run ==="
# Remove the HEAD tree object: the commits still resolve, but the diff cannot
# read the tree. The gate must not read that as an empty, passing change.
base broken; printf 'x\n' > "$d/README.adoc"; change
tree=$(g rev-parse HEAD^{tree}); rm -f "$d/.git/objects/${tree:0:2}/${tree:2}"
assert "an unreadable tree is a setup error, never OK" 2 "cannot be judged" bash "$GATE" HEAD~1 HEAD "$d"

echo "=== setup errors ==="
base noref
assert "an unresolvable BASE is a setup error" 2 "cannot resolve" bash "$GATE" deadbeef HEAD "$d"
assert "no BASE is a usage error" 2 "usage" bash "$GATE"
mkdir -p "$WORK/notgit"
assert "a non-git ROOT is a setup error" 2 "not a git work tree" bash "$GATE" HEAD HEAD "$WORK/notgit"

echo
echo "check-no-new-a2ml-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
