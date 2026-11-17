#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-lint-format-test.sh — fixture suite for the Rust arm of
# .githooks/validate-lint-format.sh (standards#932).
#
# The arm used to ask "does this repo track a Cargo.toml anywhere?" and then
# run `cargo fmt --all --check` from the repo ROOT. cargo asks a different
# question — "is there a Cargo.toml here or in a parent?" — so in a repo whose
# crates live in subdirectories (standards itself: 14 manifests, none at the
# root) every commit staging a .rs failed with "sources are not formatted",
# whatever the code looked like. Each case builds a throwaway git repo, stages
# files and runs the hook against it via INPUT_PATH.
#
# Run: bash scripts/tests/validate-lint-format-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$SCRIPT_DIR/../../.githooks/validate-lint-format.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0

if ! command -v cargo >/dev/null 2>&1 || ! cargo fmt --version >/dev/null 2>&1; then
  echo "SKIP: cargo/rustfmt not installed — the Rust arm cannot be exercised (a skip, not a pass)."
  echo "passed=0 failed=0 skipped=all"
  exit 0
fi

# new_repo — an empty git repo at $WORK/repo.
new_repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
  git -C "$WORK/repo" init -q
}

# crate <dir> <lib.rs body> — a dependency-free crate at $WORK/repo/<dir>.
crate() {
  local d="$WORK/repo/$1"
  mkdir -p "$d/src"
  printf '[package]\nname = "c%s"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' \
    "$(printf '%s' "$1" | tr -c 'a-z0-9' '_')" > "$d/Cargo.toml"
  printf '%s' "$2" > "$d/src/lib.rs"
}

FORMATTED=$'pub fn one() -> u32 {\n    1\n}\n'
UNFORMATTED=$'pub fn one()->u32{1}\n'

# expect <label> <want-rc> <needle|-> [<absent-needle>] — stages everything in
# $WORK/repo, runs the hook, checks the exit code, that the output contains
# <needle> (unless "-"), and that it does NOT contain <absent-needle> if given.
expect() {
  local label=$1 want=$2 needle=$3 absent=${4:-} out rc
  git -C "$WORK/repo" add -A
  out="$(cd "$WORK/repo" && INPUT_PATH="$WORK/repo" ESTATE_HOOK_SKIP_SLOW=1 bash "$HOOK" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — exit $rc correct, but output lacked '$needle'"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ -n "$absent" ] && printf '%s' "$out" | grep -qF -- "$absent"; then
    echo "FAIL: $label — output must not contain '$absent'"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

echo "=== Rust arm: cargo runs per crate, not from the repo root (#932) ==="

# The #932 shape: no root Cargo.toml, a clean crate in a subdirectory.
new_repo
crate tools/a "$FORMATTED"
expect "clean crate in a subdirectory, no root manifest → pass" 0 \
  "Rust: tools/a: formatted" "not formatted"

# Positive control for the gate itself: the same shape, unformatted, still fails.
new_repo
crate tools/a "$UNFORMATTED"
expect "unformatted crate in a subdirectory → fail, naming the crate" 1 \
  "Rust: tools/a: sources are not formatted"

# Two crates staged: each is checked on its own; the dirty one is named.
new_repo
crate tools/a "$FORMATTED"
crate tools/b "$UNFORMATTED"
expect "two crates, one dirty → fail names only the dirty crate" 1 \
  "Rust: tools/b: sources are not formatted" "Rust: tools/a: sources are not formatted"

# Only files that are STAGED select crates: a dirty crate with nothing staged
# is not this commit's business.
new_repo
crate tools/a "$FORMATTED"
crate tools/b "$UNFORMATTED"
git -C "$WORK/repo" add -A && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -qm base
printf '// touch\n' >> "$WORK/repo/tools/a/src/lib.rs"
expect "staged clean crate beside an unstaged dirty one → pass" 0 \
  "Rust: tools/a: formatted" "tools/b"

# A root-level crate still works (the shape the old code handled).
new_repo
crate . "$FORMATTED"
expect "root crate, clean → pass" 0 "Rust: .: formatted"

# A .rs outside every crate is not a formatting failure: it is reported as an
# unchecked file, by name, in the ledger of gates that did not run.
new_repo
crate tools/a "$FORMATTED"
mkdir -p "$WORK/repo/docs"; printf 'fn main(){}\n' > "$WORK/repo/docs/snippet.rs"
git -C "$WORK/repo" add -A && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -qm base
printf '// touch\n' >> "$WORK/repo/docs/snippet.rs"
expect "staged .rs with no enclosing Cargo.toml → not checked, named, not a fmt failure" 0 \
  "docs/snippet.rs" "not formatted"

# A crate cargo cannot even load is a tooling/scope error, never "not formatted".
new_repo
crate tools/a "$FORMATTED"
printf 'this is not toml [[[\n' > "$WORK/repo/tools/a/Cargo.toml"
expect "unloadable manifest → fail as a tooling error, not as formatting" 1 \
  "Rust: tools/a: cargo could not run" "sources are not formatted"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
