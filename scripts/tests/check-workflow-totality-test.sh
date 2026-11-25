#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail
#
# Regression cover for scripts/check-workflow-totality.sh (A3 law G7).
#
# A gate that has no planted failure it rejects is not known to be a gate, so
# this suite plants each failure class and requires a non-zero verdict, then
# requires the clean cases to pass. The negative test the owner asked for is
# the duplicate-key group: a workflow with a duplicate key MUST fail, because
# an ordinary YAML parser keeps the last one and reports success.
#
# Needs mikefarah yq v4 and jq. The lint cases need actionlint (ACTIONLINT or
# PATH, version 1.7.12 only); without it they are skipped, and the not_run case still runs.
# There are no exemptions (owner ruling 2026-11-25), so no exemption tests.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check-workflow-totality.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AL="${ACTIONLINT:-$(command -v actionlint || true)}"

pass=0 fail=0 skip=0
ok()   { echo "  ✅ $1"; pass=$((pass + 1)); }
bad()  { echo "  ❌ $1"; fail=$((fail + 1)); }
skp()  { echo "  ⏭  $1 (actionlint not available)"; skip=$((skip + 1)); }

GOOD='name: good
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
'

# repo <name> -> prints dir; callers then write files into $d/.github/workflows
repo() { local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/.github/workflows"; printf '%s' "$d"; }

# run_case <name> <want-rc> <want-substring> <dir> [extra args...]
run_case() {
  local name=$1 want=$2 sub=$3 dir=$4; shift 4
  local out rc
  out="$(ACTIONLINT="${AL:-}" bash "$CHK" "$@" "$dir" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$name (rc=$rc, wanted $want)"; printf '%s\n' "$out" | sed 's/^/       | /'; return; fi
  if [ -n "$sub" ] && ! grep -qF -- "$sub" <<<"$out"; then
    bad "$name (rc ok, missing \"$sub\")"; printf '%s\n' "$out" | sed 's/^/       | /'; return; fi
  ok "$name"
}

echo "== clean repositories pass =="
d=$(repo clean); printf '%s' "$GOOD" > "$d/.github/workflows/ci.yml"; printf '%s' "$GOOD" > "$d/.github/workflows/other.yaml"
if [ -n "$AL" ]; then run_case "two clean workflows pass" 0 "failed=0" "$d"; else skp "two clean workflows pass"; fi

d=$(repo inert); printf '%s' "$GOOD" > "$d/.github/workflows/ci.yml"; echo notes > "$d/.github/workflows/README.adoc"; echo x > "$d/.github/workflows/old.yml.disabled"
if [ -n "$AL" ]; then run_case "non-workflow files are reported inert and do not fail" 0 "inert" "$d"; else skp "inert files"; fi

echo "== duplicate keys fail (the owner's negative test) =="
d=$(repo dup-top); cat > "$d/.github/workflows/ci.yml" <<'YAML'
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
name: demo again
YAML
run_case "duplicate top-level key fails closed" 1 "dupkey" "$d"

d=$(repo dup-perm); cat > "$d/.github/workflows/release.yml" <<'YAML'
name: release
on: [push]
permissions:
  contents: read
  contents: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
run_case "duplicate key in permissions (the vcl-ut release.yml shape) fails" 1 "dupkey" "$d"

d=$(repo dup-among-good); printf '%s' "$GOOD" > "$d/.github/workflows/a.yml"; printf '%s' "$GOOD" > "$d/.github/workflows/c.yml"
cat > "$d/.github/workflows/b.yml" <<'YAML'
name: b
on: [push]
on: [pull_request]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
run_case "one dead file among clean ones fails the whole repo and names it" 1 "b.yml" "$d"

echo "== other parse-dead shapes fail =="
d=$(repo malformed); printf 'name: x\non: [push\njobs: {\n' > "$d/.github/workflows/ci.yml"
run_case "malformed YAML fails (parse)" 1 "parse" "$d"

d=$(repo empty-file); : > "$d/.github/workflows/ci.yml"
run_case "an empty workflow file fails" 1 "parse: empty file" "$d"

d=$(repo no-on); printf 'name: x\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo\n' > "$d/.github/workflows/ci.yml"
run_case "no 'on' trigger fails (shape)" 1 "no 'on' trigger" "$d"

d=$(repo no-jobs); printf 'name: x\non: [push]\n' > "$d/.github/workflows/ci.yml"
run_case "no jobs fails (shape)" 1 "no non-empty 'jobs'" "$d"

d=$(repo subdir); printf '%s' "$GOOD" > "$d/.github/workflows/ci.yml"; mkdir "$d/.github/workflows/nested"; printf '%s' "$GOOD" > "$d/.github/workflows/nested/lost.yml"
run_case "a workflow in a subdirectory (never run by GitHub) fails" 1 "unreachable" "$d"

echo "== lint (actionlint) =="
d=$(repo hashfiles); cat > "$d/.github/workflows/ci.yml" <<'YAML'
name: x
on: [push]
jobs:
  a:
    if: ${{ hashFiles('Cargo.toml') != '' }}
    runs-on: ubuntu-latest
    steps:
      - run: echo
YAML
if [ -n "$AL" ]; then run_case "job-level hashFiles() (a never-parsed class in the estate) fails" 1 "hashFiles" "$d"; else skp "hashFiles"; fi

echo "== absence itself fails =="
d="$TMP/no-dir"; mkdir -p "$d"
run_case "no .github/workflows directory fails" 1 "absence" "$d"
d=$(repo empty-dir)
run_case "an empty workflows directory fails" 1 "no workflow files" "$d"
run_case "--allow-empty lets an empty directory pass" 0 "failed=0" "$d" --allow-empty

echo "== missing tooling is not_run (exit 2), never a pass =="
d=$(repo no-tool); printf '%s' "$GOOD" > "$d/.github/workflows/ci.yml"
out="$(PATH="$(dirname "$(command -v yq)"):$(dirname "$(command -v jq)"):/usr/bin:/bin" ACTIONLINT=/nonexistent bash "$CHK" "$d" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '^not_run' <<<"$out"; then ok "no actionlint gives not_run and exit 2"
elif [ -n "$(PATH=/usr/bin:/bin command -v actionlint)" ]; then skp "no-actionlint case (actionlint is on the base PATH)"
else bad "no actionlint (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
d=$(repo no-tool-and-dead); printf 'name: x\non: [push\n' > "$d/.github/workflows/bad.yml"
out="$(ACTIONLINT=/nonexistent bash "$CHK" "$d" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "a failed file wins over not_run (exit 1)" || { bad "failed+not_run rc=$rc"; }

echo
echo "check-workflow-totality regression: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
