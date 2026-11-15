#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Proves tools/js-runtimes CAN FAIL, for the right reason:
#   * check, under each of bun, deno and pnpm: a regenerated package passes; a
#     non-canonical package.json, a missing lock, a stale lock and a failing
#     test script each fail and say why;
#   * a zero-dependency package (owner ruling 2026-11-14) needs no lock:
#     regen writes none, says so, and removes leftovers; check passes it with
#     no lock and fails it with one; a package WITH a dependency and no lock,
#     and a workspace root, still fail (controls);
#   * pick / run follow the preference order Bun > Deno > pnpm > npm;
#   * provision accepts an environment that provisions Bun, refuses one that
#     settles for less where Bun is always possible, and reports a Guix
#     fallback;
#   * a missing tool, an unknown runtime and `check npm` are exit 2 ("cannot
#     run"), never a pass.
#
# Builds the tool with cargo unless $JS_RUNTIMES names a binary. Needs bun,
# deno and pnpm, and the npm registry: the fixture depends on two tiny
# zero-dependency packages, because deno.lock does not record file:
# dependencies, so an offline fixture could never show a stale deno.lock.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for t in bun pnpm deno cargo; do
  command -v "$t" >/dev/null 2>&1 || { echo "js-runtimes-test: $t is not on PATH (cannot run, not a pass)" >&2; exit 2; }
done
if [ -z "${JS_RUNTIMES:-}" ]; then
  unit_log="$(mktemp)"
  cargo test --quiet --locked --manifest-path "$ROOT/tools/js-runtimes/Cargo.toml" >"$unit_log" 2>&1 \
    || { cat "$unit_log"; rm -f "$unit_log"; echo "js-runtimes-test: the unit tests failed" >&2; exit 1; }
  rm -f "$unit_log"
  echo "  ok    unit tests (cargo test)"
fi
BIN="${JS_RUNTIMES:-}"
if [ -z "$BIN" ]; then
  cargo build --quiet --release --locked --manifest-path "$ROOT/tools/js-runtimes/Cargo.toml" \
    || { echo "js-runtimes-test: the tool did not build" >&2; exit 2; }
  BIN="$ROOT/tools/js-runtimes/target/release/js-runtimes"
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { # expect <wanted-exit> <label> <js-runtimes args...>
  local want="$1" label="$2" got=0; shift 2
  (cd "$WORK/p" && "$BIN" "$@") >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}
names() { # names <fixed-string> <label>
  if grep -qF -- "$1" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $2"
  else fail=$((fail+1)); echo "  FAIL  $2"; sed 's/^/        /' "$WORK/out"; fi
}
fixture() { rm -rf "$WORK/p"; mkdir -p "$WORK/p"; printf '%s\n' "$1" > "$WORK/p/package.json"; }

# Pretty-printed (not JCS) on purpose: regen must canonicalise it.
PKG='{
  "name": "fixture",
  "version": "0.0.0",
  "private": true,
  "scripts": { "test": "echo js-runtimes-test-ran" },
  "dependencies": { "is-number": "7.0.0" }
}'
STALE='{"dependencies":{"is-number":"7.0.0","isarray":"2.0.5"},"name":"fixture","private":true,"scripts":{"test":"echo js-runtimes-test-ran"},"version":"0.0.0"}'
FAILING='{"dependencies":{"is-number":"7.0.0"},"name":"fixture","private":true,"scripts":{"test":"exit 3"},"version":"0.0.0"}'

echo "regen"
fixture "$PKG"
expect 0 "regen canonicalises and writes all three locks" regen
for f in bun.lock deno.lock pnpm-lock.yaml; do
  if [ -f "$WORK/p/$f" ]; then pass=$((pass+1)); echo "  ok    regen wrote $f"
  else fail=$((fail+1)); echo "  FAIL  regen did not write $f"; fi
done
if [ ! -e "$WORK/p/package-lock.json" ]; then pass=$((pass+1)); echo "  ok    regen wrote no package-lock.json (npm keeps no tracked lock)"
else fail=$((fail+1)); echo "  FAIL  regen wrote a package-lock.json"; fi
cp -r "$WORK/p" "$WORK/fresh"
reset() { rm -rf "$WORK/p"; cp -r "$WORK/fresh" "$WORK/p"; rm -rf "$WORK/p/node_modules"; }

for rt in bun deno pnpm; do
  echo "check $rt"
  lock="$(case $rt in bun) echo bun.lock;; deno) echo deno.lock;; pnpm) echo pnpm-lock.yaml;; esac)"
  reset
  expect 0 "$rt: a regenerated package passes (so regen left package.json in JCS)" check "$rt"
  names "js-runtimes-test-ran" "$rt: the test script ran under $rt"

  reset; printf '%s\n' "$PKG" > "$WORK/p/package.json"
  expect 1 "$rt: a non-canonical package.json fails" check "$rt"
  names "not JCS-canonical" "$rt: and says why"

  reset; rm -f "$WORK/p/$lock"
  expect 1 "$rt: a missing lock fails" check "$rt"
  names "is missing" "$rt: and says why"

  reset; printf '%s\n' "$STALE" > "$WORK/p/package.json"
  expect 1 "$rt: a lock stale against package.json fails" check "$rt"
  names "is stale" "$rt: and says why"

  reset; printf '%s\n' "$FAILING" > "$WORK/p/package.json"
  expect 1 "$rt: a failing test script fails" check "$rt"
  names "the test script failed" "$rt: and says why"
done

echo "zero-dependency package (owner ruling 2026-11-14: no lock needed, none carried)"
# Pretty-printed on purpose: regen must still canonicalise it.
ZERO='{
  "name": "fixture",
  "version": "0.0.0",
  "private": true,
  "scripts": { "test": "echo js-runtimes-test-ran" },
  "dependencies": {},
  "devDependencies": {}
}'
nolocks() { # nolocks <label>
  local f left=""
  for f in bun.lock deno.lock pnpm-lock.yaml; do [ -e "$WORK/p/$f" ] && left="$left $f"; done
  if [ -z "$left" ]; then pass=$((pass+1)); echo "  ok    $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (present:$left)"; fi
}
fixture "$ZERO"
expect 0 "regen accepts a zero-dependency package" regen
names "declares no dependencies, so it needs no lock" "regen says it needs no lock"
if grep -qF "regenerated" "$WORK/out"; then fail=$((fail+1)); echo "  FAIL  regen claimed to regenerate a lock"; sed 's/^/        /' "$WORK/out"
else pass=$((pass+1)); echo "  ok    regen claims no lock it did not write"; fi
nolocks "regen wrote no lock"
cp "$WORK/p/package.json" "$WORK/zero.json"
fixture "$ZERO"; printf "lockfileVersion: '9.0'\n" > "$WORK/p/pnpm-lock.yaml"; : > "$WORK/p/deno.lock"
expect 0 "regen of a zero-dependency package with leftover locks passes" regen
names "removed deno.lock, pnpm-lock.yaml" "and names the locks it removed"
nolocks "and leaves none"
for rt in bun deno pnpm; do
  fixture "$(cat "$WORK/zero.json")"
  expect 0 "$rt: a zero-dependency package with no lock passes check" check "$rt"
  names "no lock needed" "$rt: and says why"
  names "js-runtimes-test-ran" "$rt: the test script still ran under $rt"
  fixture "$(cat "$WORK/zero.json")"; printf "lockfileVersion: '9.0'\n" > "$WORK/p/pnpm-lock.yaml"
  expect 1 "$rt: a zero-dependency package carrying a leftover lock fails" check "$rt"
  names "carries no lock" "$rt: and says why"
  # Control: the ruling is about zero dependencies only.
  fixture "$FAILING"; sed -i 's/exit 3/echo js-runtimes-test-ran/' "$WORK/p/package.json"
  expect 1 "$rt: control: a package WITH a dependency and no lock still fails" check "$rt"
  names "is missing" "$rt: and says why"
done
fixture '{"name":"fixture","private":true,"version":"0.0.0","workspaces":["packages/*"]}'
expect 1 "a workspace root with no dependencies of its own still needs bun.lock" check bun
names "bun.lock is missing" "and says why"
fixture '{"name":"fixture","private":true,"version":"0.0.0"}'; printf 'packages:\n  - "packages/*"\n' > "$WORK/p/pnpm-workspace.yaml"
expect 1 "a pnpm-workspace.yaml root still needs pnpm-lock.yaml" check pnpm
names "pnpm-lock.yaml is missing" "and says why"

echo "pick / run (stub runtimes on a private PATH)"
STUBS="$WORK/stubs"
mkstub() { mkdir -p "$STUBS/$1"; printf '#!/bin/sh\necho "%s $*"\n' "$1" > "$STUBS/$1/$1"; chmod +x "$STUBS/$1/$1"; }
for r in bun deno pnpm npm; do mkstub "$r"; done
pickwith() { # pickwith <wanted> <label> <runtime dirs...>
  local want="$1" label="$2" path="" got; shift 2
  for r in "$@"; do path="$path:$STUBS/$r"; done
  got="$(cd "$WORK/p" && PATH="${path#:}" "$BIN" pick 2>&1)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted $want, got $got)"; fi
}
reset
pickwith bun  "all four present: bun"                bun deno pnpm npm
pickwith deno "no bun: deno"                         deno pnpm npm
pickwith pnpm "no bun or deno: pnpm"                 pnpm npm
pickwith npm  "only npm: npm, the last resort"       npm
got=0; (cd "$WORK/p" && PATH="$STUBS/nothing" "$BIN" pick) >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "  ok    no runtime at all is exit 2"; else fail=$((fail+1)); echo "  FAIL  no runtime at all (got $got)"; fi
got="$(cd "$WORK/p" && PATH="$STUBS/deno:$STUBS/npm" "$BIN" run test 2>/dev/null)"
if [ "$got" = "deno task test" ]; then pass=$((pass+1)); echo "  ok    run uses the best runtime's script runner (deno task)"
else fail=$((fail+1)); echo "  FAIL  run (got: $got)"; fi

echo "provision"
envfix() { rm -rf "$WORK/p"; mkdir -p "$WORK/p"; printf '{"name":"x"}\n' > "$WORK/p/package.json"; }
envfix; printf '[tools]\nbun = "1.4.2"\n' > "$WORK/p/mise.toml"
expect 0 "mise.toml pinning bun passes" provision
envfix; printf '[tools]\nnode = "22"\n' > "$WORK/p/mise.toml"
expect 1 "mise.toml settling for node fails (bun is always possible there)" provision
names "bun can be provisioned here" "and says why"
envfix; printf '[tools]\nbun = "1.4.2"\n' > "$WORK/p/mise.toml"; printf 'FROM node:22\nRUN corepack enable pnpm\n' > "$WORK/p/Containerfile"
expect 1 "a Containerfile without bun fails even when mise has it" provision
envfix; printf '[tools]\nbun = "1.4.2"\n' > "$WORK/p/mise.toml"; printf 'FROM oven/bun:1.4.2\n' > "$WORK/p/Containerfile"
expect 0 "mise and Containerfile both provisioning bun pass" provision
envfix; printf '(specifications->manifest (list "node"))\n' > "$WORK/p/manifest.scm"
expect 0 "a Guix manifest falling back to node is accepted" provision
names "best is npm" "and is reported, not hidden"
envfix
expect 1 "package.json with no environment definition fails" provision
rm -rf "$WORK/p"; mkdir -p "$WORK/p"
expect 0 "no package.json: nothing to provision" provision
names "0 environment definitions examined" "and states its denominator"

echo "cannot run"
reset
got=0; (cd "$WORK/p" && PATH=/nonexistent "$BIN" check deno) >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "  ok    a missing runtime is exit 2, not a pass"; else fail=$((fail+1)); echo "  FAIL  missing runtime (got $got)"; fi
expect 2 "an unknown runtime is exit 2" check yarn
expect 2 "check npm is exit 2 (npm keeps no tracked lock)" check npm
reset; : > "$WORK/p/bun.lockb"
expect 1 "regen refuses a binary bun.lockb" regen

echo
echo "js-runtimes-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
