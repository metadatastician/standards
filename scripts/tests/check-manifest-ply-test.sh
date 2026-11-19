#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail

# check-manifest-ply-test.sh — assertions for scripts/check-manifest-ply.sh.
#
# The gate reads FILENAMES and DIRECTORY DEPTH only: no network, no git
# plumbing, no manifest parsing. So every case here is a real tree on disk with
# a real `.git` marker, and the classification is whatever the gate makes of it.
#
# Each fixture carries its OWN `.git`, because the gate resolves a manifest's
# frame by walking to the nearest ancestor containing `.git`. Without one the
# walk would escape the fixture and reparent the file onto whatever repo the
# temp dir happens to sit under — the test would then be measuring this
# machine's disk layout rather than the gate.

repo_root=$(git rev-parse --show-toplevel)
SCRIPT="$repo_root/scripts/check-manifest-ply.sh"
[[ -f $SCRIPT ]] || { echo "FATAL: $SCRIPT not found"; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
ok() {
  local msg=$1
  printf '  ✅ %s\n' "$msg"; pass=$((pass+1)); return 0
}
bad() {
  local msg=$1
  printf '  ❌ %s\n' "$msg"; fail=$((fail+1)); return 0
}

# A fixture is a directory with a .git marker. `kind=file` exercises the linked
# worktree case, where .git is a FILE — treating it as dir-only silently
# reparents every worktree onto the wrong root.
mk() {
  local name=$1
  local kind=${2:-dir}
  local d="$tmp/$name"
  mkdir -p "$d"
  if [[ $kind == file ]]; then
    printf 'gitdir: /nowhere\n' > "$d/.git"
  else
    mkdir -p "$d/.git"
  fi
  printf '%s' "$d"
  return 0
}

OUT=""; RC=0
run() {
  local d=$1
  shift
  OUT=$(bash "$SCRIPT" "$@" "$d" 2>&1); RC=$?
  return 0
}

# First numeric field on the summary line whose label is $1.
count_of() {
  local label=$1
  grep -E "^  $label" <<<"$OUT" |
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}'
  return 0
}

rc_is() {
  local want=$1
  local msg=$2
  if [[ $RC -eq $want ]]; then ok "$msg"; else bad "$msg (rc=$RC, wanted $want)"; fi
  return 0
}

count_is() {
  local label=$1
  local want=$2
  local msg=$3
  local got
  got=$(count_of "$label")
  if [[ $got == "$want" ]]; then ok "$msg"; else bad "$msg ($label=$got, wanted $want)"; fi
  return 0
}

says() {
  local pat=$1
  local msg=$2
  if grep -q "$pat" <<<"$OUT"; then ok "$msg"; else bad "$msg"; fi
  return 0
}

lacks() {
  local pat=$1
  local msg=$2
  if grep -q "$pat" <<<"$OUT"; then bad "$msg"; else ok "$msg"; fi
  return 0
}

echo "check-manifest-ply.sh"

# ── CLI contract: exit 2 is usage, distinct from exit 1 (a real finding) ─────
OUT=$(bash "$SCRIPT" --help 2>&1); RC=$?
rc_is 0 '--help exits 0'
OUT=$(bash "$SCRIPT" --wibble 2>&1); RC=$?
rc_is 2 'an unknown option exits 2, not 1'
OUT=$(bash "$SCRIPT" "$tmp/does-not-exist" 2>&1); RC=$?
rc_is 2 'a nonexistent PATH exits 2, not a silent pass'

# ── the loud-empty rule ─────────────────────────────────────────────────────
# A scan that finds nothing and a scan that is broken print the same thing
# unless the empty case says so out loud. This asserts it does.
d=$(mk empty); run "$d"
rc_is 0 'an empty tree exits 0'
says 'WARN: no AI-MANIFEST files found' 'an empty tree SAYS it found nothing'

# ── EQUAL: declared ply matches depth below the git root ────────────────────
d=$(mk equal); : > "$d/0-ply0-AI-MANIFEST.a2ml"
mkdir -p "$d/sub"; : > "$d/sub/0-ply1-AI-MANIFEST.a2ml"
run "$d"
rc_is 0 'manifests at their declared depth pass'
count_is 'EQUAL' 2 'both are classified EQUAL'

# ── DRIFT-DEEP: declared deeper than it sits — always wrong, always fails ────
d=$(mk deep); : > "$d/0-ply2-AI-MANIFEST.a2ml"
run "$d"
rc_is 1 'DRIFT-DEEP fails'
count_is 'DRIFT-DEEP' 1 'DRIFT-DEEP is counted'

# ── DRIFT-SHALLOW: the migration debt — warns by default, fails under strict ─
# ply1 sitting at depth 2 with no self-rooting ancestor: too shallow under the
# git frame, and the unit frame does not rescue it.
d=$(mk shallow); mkdir -p "$d/a/b"; : > "$d/a/b/0-ply1-AI-MANIFEST.a2ml"
run "$d"
rc_is 0 'DRIFT-SHALLOW only warns by default'
count_is 'DRIFT-SHALLOW' 1 'DRIFT-SHALLOW is counted while passing'
run "$d" --strict
rc_is 1 '--strict turns DRIFT-SHALLOW into a failure'

# ── UNIT-RELATIVE: a self-rooting sub-project numbers its children from itself ─
# sub/ declares ply0, so sub/x's ply1 is correct in the unit frame even though
# it sits at git depth 2. Reported, never failed — the frame is not yet ruled on.
# Note sub/0-ply0 is ITSELF unit-relative (ply0 at git depth 1), so the count is
# 2, not 1 — the self-rooting declaration is as much a unit-frame claim as its
# children's are.
d=$(mk unitrel); : > "$d/0-ply0-AI-MANIFEST.a2ml"
mkdir -p "$d/sub/x"; : > "$d/sub/0-ply0-AI-MANIFEST.a2ml"; : > "$d/sub/x/0-ply1-AI-MANIFEST.a2ml"
run "$d"
rc_is 0 'UNIT-RELATIVE does not fail the gate'
count_is 'UNIT-RELATIVE' 2 'BOTH the self-rooting manifest and its child are UNIT-RELATIVE'
count_is 'EQUAL' 1 'only the true repo-root manifest is EQUAL'
count_is 'DRIFT-SHALLOW' 0 'a unit-relative file is NOT miscounted as drift'

# ── UNPARSEABLE: an unrecognised manifest is an unknown, not a pass ─────────
d=$(mk unparse); : > "$d/wibble-AI-MANIFEST.a2ml"
run "$d"
rc_is 1 'an unparseable manifest name fails'
count_is 'UNPARSEABLE' 1 'UNPARSEABLE is counted'

# ── LEGACY-NAME: no ply claim to check, but never silently invisible ────────
d=$(mk legacy); : > "$d/0-ply0-AI-MANIFEST.a2ml"; : > "$d/AI.a2ml"; : > "$d/!AI.a2ml"
run "$d"
rc_is 0 'legacy AI.* names do not fail'
count_is 'LEGACY-NAME' 2 'legacy names are counted, not ignored'

# ── extension-agnostic by construction: the .a2ml -> .deed rename must not
#    break this gate, so it must classify .deed identically.
d=$(mk deed); : > "$d/0-ply0-AI-MANIFEST.deed"
run "$d"
count_is 'EQUAL' 1 '.deed is classified the same as .a2ml'

# ── the deployed dotted form (0.N-) parses too, or every old repo is UNPARSEABLE
d=$(mk dotted); mkdir -p "$d/sub"; : > "$d/sub/0.1-AI-MANIFEST.a2ml"
run "$d"
count_is 'EQUAL' 1 'the deployed dotted 0.N- form parses as ply N'
count_is 'UNPARSEABLE' 0 'the dotted form is not reported UNPARSEABLE'

# ── linked worktree: .git is a FILE, not a directory ────────────────────────
d=$(mk worktree file); : > "$d/0-ply0-AI-MANIFEST.a2ml"
run "$d"
count_is 'EQUAL' 1 'a .git FILE (linked worktree) still resolves as the root'
lacks 'NO-GIT-ROOT' 'a linked worktree is not reported NO-GIT-ROOT'

# ── --quiet drops the per-file listing but keeps the summary ────────────────
d=$(mk quiet); : > "$d/0-ply2-AI-MANIFEST.a2ml"
run "$d" --quiet
rc_is 1 '--quiet does not change the exit code'
lacks 'declared=2 actual=0' '--quiet suppresses the per-file listing'
says 'DRIFT-DEEP' '--quiet keeps the summary'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
