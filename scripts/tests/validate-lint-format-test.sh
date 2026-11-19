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
  # Exit 2 is this repository's "could not run": a caller that counts exit 0
  # as a pass (CI, or a script check in the issue-evidence ledger) must not
  # read a run that exercised nothing as one.
  echo "COULD NOT RUN: cargo/rustfmt not installed, so the Rust arm cannot be exercised." >&2
  echo "passed=0 failed=0 skipped=all"
  exit 2
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
# $WORK/repo (unless NO_ADD is set, see expect_as_staged), runs the hook, checks the exit code, that the output contains
# <needle> (unless "-"), and that it does NOT contain <absent-needle> if given.
expect() {
  local label=$1 want=$2 needle=$3 absent=${4:-} out rc
  [ -n "${NO_ADD:-}" ] || git -C "$WORK/repo" add -A
  out="$(cd "$WORK/repo" && INPUT_PATH="$WORK/repo" ESTATE_HOOK_SKIP_SLOW=1 bash "$HOOK" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $label — exit $rc correct, but output lacked '$needle'"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  if [ -n "$absent" ] && grep -qF -- "$absent" <<<"$out"; then
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
echo "=== Rust arm: a workspace root checks its own package only (B3) ==="

# commit_all — commit everything in $WORK/repo as the base state.
commit_all() {
  git -C "$WORK/repo" add -A && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -qm base
}

# A workspace root that is also a package, with an unformatted member that the
# commit does not touch. Running cargo fmt from the root directory checks every
# member, so the untouched member used to block this commit.
new_repo
mkdir -p "$WORK/repo/src" "$WORK/repo/member/src"
printf '[package]\nname = "rootpkg"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\nmembers = ["member"]\n' > "$WORK/repo/Cargo.toml"
printf '%s' "$FORMATTED" > "$WORK/repo/src/lib.rs"
printf '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2021"\n' > "$WORK/repo/member/Cargo.toml"
printf '%s' "$UNFORMATTED" > "$WORK/repo/member/src/lib.rs"
commit_all
printf '// touch\n' >> "$WORK/repo/src/lib.rs"
expect "workspace-root package staged, unformatted member untouched → pass" 0 \
  "Rust: .: formatted" "member"

# Positive control: the root package itself unformatted still fails.
printf '%s' "$UNFORMATTED" > "$WORK/repo/src/lib.rs"
expect "workspace-root package staged and unformatted → fail" 1 \
  "Rust: .: sources are not formatted"

# A staged file in the member is checked against the member's manifest.
new_repo
mkdir -p "$WORK/repo/src" "$WORK/repo/member/src"
printf '[package]\nname = "rootpkg"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\nmembers = ["member"]\n' > "$WORK/repo/Cargo.toml"
printf '%s' "$UNFORMATTED" > "$WORK/repo/src/lib.rs"
printf '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2021"\n' > "$WORK/repo/member/Cargo.toml"
printf '%s' "$FORMATTED" > "$WORK/repo/member/src/lib.rs"
commit_all
printf '// touch\n' >> "$WORK/repo/member/src/lib.rs"
expect "member staged beside an unformatted root package → pass, names the member" 0 \
  "Rust: member: formatted" "not formatted"

# A virtual workspace (no [package]): a staged member file resolves to the
# member, which inherits its edition from the workspace.
new_repo
mkdir -p "$WORK/repo/m1/src" "$WORK/repo/m2/src"
printf '[workspace]\nmembers = ["m1", "m2"]\nresolver = "2"\n\n[workspace.package]\nedition = "2021"\n' > "$WORK/repo/Cargo.toml"
printf '[package]\nname = "m1"\nversion = "0.1.0"\nedition.workspace = true\n' > "$WORK/repo/m1/Cargo.toml"
printf '[package]\nname = "m2"\nversion = "0.1.0"\nedition.workspace = true\n' > "$WORK/repo/m2/Cargo.toml"
printf '%s' "$FORMATTED" > "$WORK/repo/m1/src/lib.rs"
printf '%s' "$UNFORMATTED" > "$WORK/repo/m2/src/lib.rs"
commit_all
printf '// touch\n' >> "$WORK/repo/m1/src/lib.rs"
expect "virtual workspace, member staged, unformatted sibling untouched → pass" 0 \
  "Rust: m1: formatted" "m2"

# The virtual manifest itself staged: it belongs to no package, so no package
# is formatted for it. It is named in the ledger, and the untouched unformatted
# member does not block.
git -C "$WORK/repo" reset -q --hard
printf '\n' >> "$WORK/repo/Cargo.toml"
expect "virtual workspace manifest staged alone → not checked, named, not a failure" 0 \
  "virtual workspace manifest" "m2"

echo
echo "=== Rust arm: manifests come from the index, not the working tree (B4) ==="

# expect_as_staged — like expect, but runs the hook on the index as it stands
# (no `git add -A`), so untracked and unstaged files stay out of the commit.
expect_as_staged() {
  NO_ADD=1 expect "$@"
}

# An untracked Cargo.toml is not part of the commit, so it does not make the
# staged .rs beside it a crate.
new_repo
mkdir -p "$WORK/repo/tools/a/src"
printf '%s' "$FORMATTED" > "$WORK/repo/tools/a/src/lib.rs"
git -C "$WORK/repo" add tools/a/src/lib.rs
printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' > "$WORK/repo/tools/a/Cargo.toml"
expect_as_staged "untracked nearer Cargo.toml is not selected → staged .rs named as not checked" 0 \
  "rust: NOT checked, no enclosing Cargo.toml: tools/a/src/lib.rs" "Rust: tools/a:"

# With a tracked root crate, an untracked nested manifest is skipped and the
# nearest INDEXED manifest (the root) is the one checked.
new_repo
crate . "$FORMATTED"
mkdir -p "$WORK/repo/sub"
printf '%s' "$FORMATTED" > "$WORK/repo/sub/extra.rs"
git -C "$WORK/repo" add Cargo.toml src/lib.rs sub/extra.rs
printf '[package]\nname = "sub"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' > "$WORK/repo/sub/Cargo.toml"
expect_as_staged "untracked nested Cargo.toml skipped → nearest indexed manifest (root) checked" 0 \
  "Rust: .: formatted" "Rust: sub:"


echo
echo "=== ReScript arm: the format -check probe survives a long help text ==="

# The arm probed for `format -check` with `bunx rescript format --help 2>&1 |
# grep -q -- '-check'` under pipefail. grep -q exits at the match; a CLI still
# writing its help dies of SIGPIPE, the pipeline reports 141, and the format
# gate was skipped with a warning. A stub bunx prints `-check` first and then
# more than a pipe buffer of help; its `format -all -check` reports the
# sources unformatted, so a gate that runs fails the hook. The real CLI's help
# is small, so in practice the race needs a help text written in several
# writes and a slow reader; the stub makes it deterministic.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/bunx" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  "rescript format --help")
    [ -n "${STUB_NO_CHECK:-}" ] || printf '  -check  Check formatting only\n'
    for i in $(seq 1 3000); do printf '  -option-%d  a help line long enough to fill the pipe buffer\n' "$i"; done ;;
  "rescript format -all -check") echo "stub: sources are not formatted"; exit 1 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/bunx"
new_repo
printf '{"name":"r"}\n' > "$WORK/repo/rescript.json"
printf 'let x = 1\n' > "$WORK/repo/A.res"
commit_all
printf 'let x = 2\n' > "$WORK/repo/A.res"
for run in 1 2 3 4 5; do
  PATH="$STUB:$PATH" expect "modified .res, -check listed before ~180 KB of help → format gate runs and fails (run $run)" 1 \
    "ReScript: sources are not formatted" "format gate did NOT run"
done
PATH="$STUB:$PATH" STUB_NO_CHECK=1 expect "control: a help text without -check → skip warned, not failed" 0 \
  "format gate did NOT run"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
