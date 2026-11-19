#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail
#
# Regression cover for scripts/check-workflow-duplicate-keys.sh.
#
# The scanner exists because a duplicate YAML key makes GitHub Actions reject a
# workflow before any job is created — failure, zero jobs, no log, no check run.
# Ordinary YAML parsers cannot stand in for it: they silently keep the LAST
# duplicate and report success.
#
# So this suite has to prove two things, and the second matters as much as the
# first: the scanner CATCHES real duplicates, and it does NOT cry wolf on the
# four constructs that legitimately repeat a key. A duplicate-key checker that
# produces false positives gets switched off, at which point it protects nothing.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check-workflow-duplicate-keys.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

# run_case <name> <expected-rc> <expected-substring> <<< workflow body on stdin
run_case() {
  local name=$1 want_rc=$2 want_sub=$3
  local f="$TMP/wf.yml" out rc
  cat > "$f"
  out="$(bash "$CHK" "$f" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "$name (rc=$rc, wanted $want_rc)"; printf '%s\n' "$out" | sed 's/^/       | /'
    return
  fi
  if [ -n "$want_sub" ] && ! grep -qF -- "$want_sub" <<<"$out"; then
    bad "$name (rc ok but missing \"$want_sub\")"; printf '%s\n' "$out" | sed 's/^/       | /'
    return
  fi
  ok "$name"
}

echo "== it catches real duplicates =="

run_case "duplicate top-level key is rejected" 1 "duplicate key(s)" <<'YAML'
name: demo
on:
  push:
jobs:
  build:
    runs-on: ubuntu-latest
name: demo again
YAML

run_case "duplicate nested key inside a job is rejected" 1 "duplicate key(s)" <<'YAML'
name: demo
jobs:
  build:
    runs-on: ubuntu-latest
    runs-on: ubuntu-24.04
YAML

run_case "the report names the offending key" 1 "'runs-on'" <<'YAML'
jobs:
  build:
    runs-on: ubuntu-latest
    runs-on: ubuntu-24.04
YAML

run_case "quoted and bare spellings are the same key" 1 "duplicate key(s)" <<'YAML'
name: demo
"on":
  push:
on:
  pull_request:
YAML

echo
echo "== it does not cry wolf on constructs that legitimately repeat =="

run_case "a run: | block scalar is body text, not keys" 0 "clean" <<'YAML'
name: demo
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "key: value"
          echo "key: value"
          foo: not-a-yaml-key
          foo: still-not-a-yaml-key
YAML

run_case "each list item opens a fresh mapping scope" 0 "clean" <<'YAML'
name: demo
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: first
        run: true
      - name: second
        run: true
      - name: third
        run: true
YAML

run_case "a --- separator starts a fresh sibling scope" 0 "clean" <<'YAML'
name: demo
---
name: demo
YAML

run_case "sibling jobs may repeat the same child keys" 0 "clean" <<'YAML'
name: demo
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: true
  b:
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML

run_case "comments are not keys" 0 "clean" <<'YAML'
name: demo
# name: demo
jobs:
  build:
    runs-on: ubuntu-latest
YAML

echo
echo "== KYAML / flow-style workflows (YAML-POLICY Y-3) =="

# A KYAML file nests every key inside `{ … }`, so the indentation scanner sees
# one scope. These cases prove the flow path normalises it first: it must not
# go blind (miss a real duplicate) and must not cry wolf on sibling scopes.

run_case "a clean KYAML workflow is clean" 0 "clean" <<'YAML'
# SPDX-License-Identifier: MPL-2.0
{
  name: "demo",
  jobs: {
    a: { runs-on: "ubuntu-latest", steps: [{ run: "true" }] },
    b: { runs-on: "ubuntu-latest", steps: [{ run: "true" }] },
  },
}
YAML

run_case "a nested duplicate in a KYAML workflow is rejected" 1 "'runs-on'" <<'YAML'
{
  name: "demo",
  jobs: {
    build: {
      runs-on: "ubuntu-latest",
      runs-on: "ubuntu-24.04",
    },
  },
}
YAML

run_case "a duplicate inside a one-line flow mapping is rejected" 1 "'runs-on'" <<'YAML'
{
  name: "demo",
  jobs: { build: { runs-on: "ubuntu-latest", runs-on: "ubuntu-24.04" } },
}
YAML

run_case "a top-level duplicate in a KYAML workflow is rejected" 1 "duplicate key(s)" <<'YAML'
{
  name: "demo",
  jobs: {},
  name: "demo again",
}
YAML

run_case "an unparseable flow workflow fails closed" 1 "" <<'YAML'
{
  name: "demo",
  jobs: {
YAML

echo
echo "== directory scanning =="

wfdir="$TMP/wfdir"
mkdir -p "$wfdir"
cat > "$wfdir/clean-a.yml" <<'YAML'
name: a
jobs:
  build:
    runs-on: ubuntu-latest
YAML
cat > "$wfdir/clean-b.yml" <<'YAML'
name: b
jobs:
  build:
    runs-on: ubuntu-latest
YAML
out="$(bash "$CHK" "$wfdir" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF "2 workflow file(s) clean" <<<"$out"; then
  ok "a directory target scans every .yml in it"
else
  bad "directory scan (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       | /'
fi

cat > "$wfdir/dirty.yml" <<'YAML'
name: c
name: c
YAML
out="$(bash "$CHK" "$wfdir" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF "1 of 3 workflow file(s) contain duplicate keys" <<<"$out"; then
  ok "one dirty file among clean ones fails the whole scan"
else
  bad "mixed directory scan (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       | /'
fi

if grep -qF "::error file=" <<<"$out"; then
  ok "it emits a GitHub workflow-command annotation"
else
  bad "no ::error annotation emitted"
fi

echo
echo "check-workflow-duplicate-keys regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
