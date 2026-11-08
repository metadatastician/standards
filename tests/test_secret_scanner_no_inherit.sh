#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_secret_scanner_no_inherit.sh — the secret scanner's caller contract
# must not regress to `secrets: inherit`. (standards#1108 §6b)
#
# WHY THIS EXISTS
#
#   `secret-scanner-reusable.yml` long carried a header claiming callers
#   MUST pass `secrets: inherit` so `gitleaks/gitleaks-action` could see
#   `secrets.GITHUB_TOKEN`. The claim died with #500 (gitleaks became a
#   pinned local binary), but the header survived and was copied into
#   generated callers estate-wide — including this repo's own wrapper —
#   forwarding every repository and organisation secret to a scanner that
#   declares no `workflow_call.secrets` and references no `secrets.*`.
#   Nothing failed visibly: over-broad secret delegation is silent.
#   Production evidence: metadatastician/vordr#39 ran all three scanner
#   jobs green with no secrets passed at all.
#
# WHAT IT ASSERTS
#
#   1. The reusable's premise still holds: no `${{ secrets.* }}`
#      expression, no `secrets:` declaration or mapping anywhere in it.
#      (If a future job genuinely needs a secret, it must be declared
#      narrowly in `workflow_call.secrets` and this test updated in the
#      same commit — that deliberateness is the point.)
#   2. This repo's own caller (`secret-scanner.yml`) has no `secrets:`
#      line of any kind.
#   3. No live workflow in this repo (`.github/workflows/` plus the three
#      packaged template `.github/workflows/` dirs) carries a non-comment
#      `secrets: inherit` directive. The explicit SUPPORTED list below is
#      empty; a file that stops inheriting is reported as a STALE exemption
#      and fails, so the list can only shrink.
#   3b. Packaged caller examples (meta, gatekeeper, axel) pass only secrets
#      the callee declares AT THE PINNED REVISION, not merely in the
#      working tree — the pin is what runs, and an undeclared secret
#      startup-fails every run.
#   4. No WH008 (`secrets: inherit`) suppression for the scanner caller
#      remains in `.hypatia-baseline.json`: the finding was fixed, not
#      silenced, so the suppression must not outlive the fix.
#   5. The poisoned pin `@a3308ea8…` — whose callee lockfile failed every
#      scanner job at runner setup estate-wide — appears nowhere live.
#   6. Every workflow has a section in `actions.lock` (the missing-key
#      gap `validate-actions-lock.sh` states it cannot see), with an
#      EXPECTED_ABSENT list pending `gh actions-lock` regeneration;
#      stale entries fail. The lock is machine-generated: never "fix"
#      this by hand-editing it.
#   7. Positive control for 6: the `actions/checkout` pin the scanner
#      reusable actually uses is keyed in the lock — the scanner's own
#      transitive closure is present for callers to validate against.
#
# METHOD NOTE (YAML-POLICY Y-1 deviation, deliberate): these are ABSENCE
# assertions over raw text. Half the defect lives in comments and caller
# examples, which a YAML parser discards before any check could see
# them; parsing first would blind this test to exactly what it guards.
# Structural checks therefore run over non-comment lines, and every
# check states the population it examined so an empty read fails loudly
# instead of passing vacuously.
#
# Usage: tests/test_secret_scanner_no_inherit.sh [repo-root]
# Exit:  0 = contract holds, 1 = contract broken (or unreadable inputs).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-${SCRIPT_DIR}/..}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

WF_DIR="$REPO_ROOT/.github/workflows"
REUSABLE="$WF_DIR/secret-scanner-reusable.yml"
CALLER="$WF_DIR/secret-scanner.yml"
LOCKFILE="$WF_DIR/actions.lock"
BASELINE="$REPO_ROOT/.hypatia-baseline.json"
DEAD_PIN="a3308ea8d0cc513727c8ad149b1132317a886c98"

# No supported-inherit exemptions remain: the two packaged hypatia callers
# (1-formats/a2ml/meta, 2-protocols/0-ai-gatekeeper) were re-pinned to the
# commit that declares HYPATIA_SCAN_PAT and narrowed to named secrets
# (standards#1108 §6b). Keep this list EMPTY; a file that needs inherit is a
# signal the callee contract regressed, never a supported state.
SUPPORTED_INHERIT=()

# Regeneration is complete: every workflow now has a lockfile key. Keep this
# ratchet empty; a future unlisted workflow must fail rather than be exempted.
EXPECTED_ABSENT_FROM_LOCK=()

fails=0
fail() { echo "::error::no-inherit: $*"; fails=$((fails + 1)); }
note() { echo "no-inherit: $*"; }

# --- Inputs must exist and be the real files (positive controls) --------
for f in "$REUSABLE" "$CALLER" "$LOCKFILE" "$BASELINE"; do
  [ -r "$f" ] || { fail "required input unreadable: $f"; }
done
[ "$fails" -eq 0 ] || { echo "::error::no-inherit: aborting on unreadable inputs"; exit 1; }

grep -q '^name: Secret Scanner (reusable)$' "$REUSABLE" \
  || fail "$REUSABLE does not look like the scanner reusable (name line missing) — refusing to certify the wrong file"
grep -q 'workflow_call:' "$REUSABLE" \
  || fail "$REUSABLE has no workflow_call trigger — refusing to certify the wrong file"

# --- 1. The reusable needs and declares no secrets ----------------------
if grep -nE '\$\{\{[^}]*secrets\.' "$REUSABLE" >/dev/null; then
  fail "reusable references the secrets context — the no-inherit premise is gone; declare the secret narrowly and update this test deliberately:"
  grep -nE '\$\{\{[^}]*secrets\.' "$REUSABLE" | sed 's/^/    /'
fi
# Non-comment `secrets:` line anywhere in the reusable (declaration or
# mapping). Comment prose explaining the contract is not a declaration.
if grep -vE '^[[:space:]]*#' "$REUSABLE" | grep -nE '^[[:space:]]+secrets:' >/dev/null; then
  fail "reusable declares or maps \`secrets:\` — update the caller contract and this test deliberately:"
  grep -vE '^[[:space:]]*#' "$REUSABLE" | grep -nE '^[[:space:]]+secrets:' | sed 's/^/    /'
fi
# The rationale must stay documented, so the next editor is not tempted
# to "fix" a token problem by re-adding inherit.
grep -q 'declares no' "$REUSABLE" \
  || fail "reusable no longer documents that it declares no secrets — keep the rationale with the contract"

# --- 2. This repo's own caller passes nothing ---------------------------
if grep -vE '^[[:space:]]*#' "$CALLER" | grep -nE '^[[:space:]]+secrets:' >/dev/null; then
  fail "canonical caller secret-scanner.yml carries a \`secrets:\` line; the callee needs none:"
  grep -vE '^[[:space:]]*#' "$CALLER" | grep -nE '^[[:space:]]+secrets:' | sed 's/^/    /'
fi

# --- 2b. Documented caller EXAMPLES must not teach inherit -------------
# The directive scan below reads non-comment lines (a directive is live
# YAML), but the original §6b defect propagated precisely through the
# commented examples generators copy. So the example blocks in the two
# reusables that document a caller are asserted separately: extract from
# the "Caller example" marker to the first non-comment line and forbid
# the inherit string there (in any role — an example has no business
# containing it at all).
for ex_file in "$REUSABLE" "$WF_DIR/mirror-reusable.yml"; do
  [ -r "$ex_file" ] || { fail "example-bearing reusable unreadable: $ex_file"; continue; }
  example="$(awk '/Caller example/{f=1} f && /^[^#]/{exit} f{print}' "$ex_file")"
  [ -n "$example" ] || { fail "no caller example found in $ex_file — extraction is broken"; continue; }
  if printf '%s
' "$example" | grep -q 'secrets:[[:space:]]*inherit'; then
    fail "caller example in $(basename "$ex_file") still teaches \`secrets: inherit\` — examples are what generators copy"
  fi
done

# --- 2c. Narrowed callers may pass only secrets the callee declares ----
# Passing a secret the callee does not declare is a startup validation
# error (this is not theoretical: it startup-failed hypatia-scan on main
# when the caller was narrowed one commit before the declaration
# landed). For each standards wrapper that passes named secrets to a
# LOCAL reusable, every passed name must be declared in that reusable's
# workflow_call.secrets mapping. These workflows use two-space indentation;
# inspect only direct secret keys, not inputs or nested metadata.
# check_declared CALLER REUSABLE: report each named caller secret missing from
# the reusable's workflow_call.secrets via fail, incrementing the failure count.
# Skip the comparison if either file is unreadable.
check_declared() {
  local caller="$1" reusable="$2" name declared
  [ -r "$caller" ] && [ -r "$reusable" ] || return 0
  declared="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    /^  workflow_call:/ { call=1; next }
    call && /^[^ ]/ { exit }
    call && /^  [^ ]/ { exit }
    call && /^    secrets:[[:space:]]*(#.*)?$/ { secrets=1; next }
    secrets && /^    [^ ]/ { exit }
    secrets && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
      sub(/^      /, ""); sub(/:.*/, ""); print
    }
  ' "$reusable")"
  while IFS= read -r name; do
    if ! grep -qxF -- "$name" <<< "$declared"; then
      fail "$(basename "$caller") passes secret $name but $(basename "$reusable") does not declare it in workflow_call.secrets — every run startup-fails"
    fi
  done < <(awk '
    /^[[:space:]]*(#|$)/ { next }
    /^jobs:/ { jobs=1; next }
    jobs && /^[^ ]/ { exit }
    jobs && /^    secrets:[[:space:]]*(#.*)?$/ { secrets=1; next }
    secrets && /^    [^ ]/ { secrets=0 }
    secrets && /^[^ ]/ { jobs=0 }
    secrets && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
      sub(/^      /, ""); sub(/:.*/, ""); print
    }
  ' "$caller")
}
check_declared "$WF_DIR/hypatia-scan.yml" "$WF_DIR/hypatia-scan-reusable.yml"
check_declared "$WF_DIR/governance.yml"  "$WF_DIR/governance-reusable.yml"

# --- 2d. Packaged callers vs the callee AT THEIR PINNED REVISION --------
# check_declared validates local reusables at their working-tree content.
# The packaged caller examples instead pin the callee remotely
# (hyperpolymath/standards/.../<callee>.yml@<sha> — this repository at
# that SHA, which after every re-pin is in this repository's history).
# A named secret the pinned callee does not declare startup-fails exactly
# as hard as a local one, so verify against the callee AS IT IS AT THE PIN
# — not as it is in the working tree. A pin absent from local history
# fails rather than passes vacuously; run with full history (fetch-depth: 0).
# Secrets are matched JOB-SCOPED: each job's secret mapping is verified
# against the callee THAT JOB pins, so a valid multi-job caller cannot
# cross-check one job's secrets against another job's callee.

# job_triples CALLER: emit one line per (pin, rel, secret) triple, scoped to
# the job that maps the secret, for every job whose `uses:` pins a standards
# reusable (yml or yaml). Jobs pinning anything else, or nothing, emit no
# triple — finding 2's vacuous-pass guard lives in check_pinned.
job_triples() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^jobs:/ { jobs=1; next }
    jobs && /^[^ ]/ { exit }
    /^  [A-Za-z0-9_-]+:/ { job=1; pin=""; rel=""; secrets=0; next }
    job && /^    uses:[[:space:]]/ {
      # mawk has no interval expressions, so the 40-hex check is done with
      # length() + an anchored class test, never {40}.
      if (match($0, /(hyperpolymath|metadatastician)\/standards\/\.github\/workflows\/[A-Za-z0-9_.-]+\.ya?ml@/)) {
        tok = substr($0, RSTART, RLENGTH)
        rel = tok; sub(/.*standards\//, "", rel); sub(/@$/, "", rel)
        sha = substr($0, RSTART + RLENGTH, 40)
        if (length(sha) == 40 && sha ~ /^[0-9a-f]+$/) pin = sha
      }
      next
    }
    job && /^    secrets:[[:space:]]*(#.*)?$/ { secrets=1; next }
    secrets && /^    [^ ]/ { secrets=0 }
    secrets && /^[^ ]/ { jobs=0; job=0; secrets=0 }
    secrets && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
      k=$1; sub(/:.*/, "", k)
      if (pin != "") printf "%s\t%s\t%s\n", pin, rel, k
      next
    }
  ' "$1"
}

check_pinned() {
  local caller="$1" pin rel name triples declared passed
  [ -r "$caller" ] || { fail "packaged caller unreadable: $caller"; return; }
  triples="$(job_triples "$caller")"
  if [ -z "$triples" ]; then
    # A caller that maps secrets but pins no standards reusable gives the
    # contract test nothing to verify — refuse to pass vacuously. A caller
    # passing no secrets at all has nothing to check.
    passed="$(awk '
      /^[[:space:]]*(#|$)/ { next }
      /^jobs:/ { jobs=1; next }
      jobs && /^[^ ]/ { exit }
      jobs && /^    secrets:[[:space:]]*(#.*)?$/ { secrets=1; next }
      secrets && /^    [^ ]/ { secrets=0 }
      secrets && /^[^ ]/ { jobs=0 }
      secrets && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
        sub(/^      /, ""); sub(/:.*/, ""); print
      }
    ' "$caller")"
    if [ -n "$passed" ]; then
      fail "$(basename "$caller") passes secrets ($(printf '%s' "$passed" | tr '\n' ' ')) but pins no standards reusable this contract test understands (owner/.yaml/pin drift?) — refusing to verify vacuously"
    else
      note "$(basename "$caller") passes no secrets — nothing to verify"
    fi
    return
  fi
  while IFS=$'\t' read -r pin rel name; do
    [ -n "$name" ] || continue
    if ! git -C "$REPO_ROOT" cat-file -e "$pin^{commit}" 2>/dev/null; then
      fail "$(basename "$caller") pins $rel at $pin, absent from local history — full history required; refusing to verify vacuously"
      continue
    fi
    if ! declared="$(git -C "$REPO_ROOT" cat-file -p "$pin:$rel" 2>/dev/null)"; then
      fail "$(basename "$caller") pins $rel at $pin but that workflow is not readable at the pin (missing file or partial clone) — refusing to verify vacuously"
      continue
    fi
    declared="$(printf '%s\n' "$declared" | awk '
      /^[[:space:]]*(#|$)/ { next }
      /^  workflow_call:/ { call=1; next }
      call && /^[^ ]/ { exit }
    call && /^  [^ ]/ { exit }
      call && /^    secrets:[[:space:]]*(#.*)?$/ { secrets=1; next }
      secrets && /^    [^ ]/ { exit }
      secrets && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
        sub(/^      /, ""); sub(/:.*/, ""); print
      }
    ')"
    if [ -z "$declared" ]; then
      note "$(basename "$caller") pins $rel at $pin — callee declares no workflow_call.secrets"
    fi
    if ! grep -qxF -- "$name" <<< "$declared"; then
      fail "$(basename "$caller") passes secret $name but $rel at its pin ($pin) does not declare it — every run startup-fails"
    fi
  done <<< "$triples"
}
for packaged_dir in \
  "$REPO_ROOT/1-formats/a2ml/meta/.github/workflows" \
  "$REPO_ROOT/2-protocols/0-ai-gatekeeper/.github/workflows" \
  "$REPO_ROOT/2-protocols/axel/.github/workflows"; do
  [ -d "$packaged_dir" ] || { fail "expected packaged caller dir missing: $packaged_dir"; continue; }
  for f in "$packaged_dir"/*.yml "$packaged_dir"/*.yaml; do
    [ -f "$f" ] || continue
    check_pinned "$f"
  done
done

# --- 3. No live `secrets: inherit` directive outside the supported list -
supported_path() {
  local p="$1" entry
  for entry in "${SUPPORTED_INHERIT[@]}"; do
    [ "${entry%%	*}" = "$p" ] && return 0
  done
  return 1
}

scan_dirs=(
  "$WF_DIR"
  "$REPO_ROOT/1-formats/a2ml/meta/.github/workflows"
  "$REPO_ROOT/2-protocols/0-ai-gatekeeper/.github/workflows"
  "$REPO_ROOT/2-protocols/axel/.github/workflows"
)
scanned=0
declare -a seen_supported=()
for dir in "${scan_dirs[@]}"; do
  [ -d "$dir" ] || { fail "expected workflow dir missing: $dir"; continue; }
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    rel="${f#"$REPO_ROOT"/}"
    # A directive is a non-comment line `secrets: inherit` (a trailing
    # suppression comment such as `# NOSONAR` does not change that).
    if grep -vE '^[[:space:]]*#' "$f" | grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit([[:space:]]|$)'; then
      if supported_path "$rel"; then
        seen_supported+=("$rel")
      else
        fail "$rel uses \`secrets: inherit\` — narrow it to the callee's declared secrets (or drop it if the callee declares none)"
      fi
    fi
  done
done
[ "$scanned" -gt 0 ] || fail "scanned 0 workflow files — extraction is broken, not clean"
note "scanned $scanned workflow file(s) for inherit directives"
for entry in "${SUPPORTED_INHERIT[@]}"; do
  p="${entry%%	*}"
  found=0
  for s in "${seen_supported[@]:-}"; do [ "$s" = "$p" ] && found=1; done
  [ "$found" -eq 1 ] || fail "SUPPORTED_INHERIT entry is stale (no longer inheriting): $p — delete it"
done

# --- 4. No live WH008 suppression covering the scanner caller -----------
if command -v jq >/dev/null 2>&1; then
  if jq -e --arg f ".github/workflows/secret-scanner.yml" \
       '[.. | objects | select(.type? == "WH008" and .file? == $f)] | length > 0' \
       "$BASELINE" >/dev/null 2>&1; then
    fail ".hypatia-baseline.json still suppresses WH008 for secret-scanner.yml — the fix removed the directive, so remove the suppression too"
  fi
else
  fail "jq not found — cannot verify the hypatia baseline; failing closed"
fi

# --- 5. The poisoned pin appears nowhere live ---------------------------
dead_hits="$(grep -rln "$DEAD_PIN" \
  --exclude-dir=.git --exclude-dir=9-archive "$REPO_ROOT" 2>/dev/null \
  | grep -v "test_secret_scanner_no_inherit.sh" || true)"
if [ -n "$dead_hits" ]; then
  fail "poisoned pin @$DEAD_PIN still referenced:"
  printf '%s\n' "$dead_hits" | sed 's/^/    /'
fi

# --- 6+7. Lockfile sections + the scanner's own closure ------------------
wf_count=0
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  wf_count=$((wf_count + 1))
  rel=".github/workflows/$(basename "$f")"
  if grep -qF "'$rel':" "$LOCKFILE"; then
    for a in "${EXPECTED_ABSENT_FROM_LOCK[@]}"; do
      [ "$a" = "$rel" ] && fail "$rel now has a lock section — delete its EXPECTED_ABSENT_FROM_LOCK entry"
    done
  else
    ok=0
    for a in "${EXPECTED_ABSENT_FROM_LOCK[@]}"; do [ "$a" = "$rel" ] && ok=1; done
    [ "$ok" -eq 1 ] || fail "$rel has no section in actions.lock — regenerate with \`gh actions-lock\` (never hand-edit)"
  fi
done
[ "$wf_count" -gt 0 ] || fail "found 0 workflows — extraction is broken, not clean"
note "checked $wf_count workflow file(s) against actions.lock sections"

checkout_pin="$(grep -vE '^[[:space:]]*#' "$REUSABLE" | grep -oE 'actions/checkout@[0-9a-f]{40}' | sort -u)"
[ -n "$checkout_pin" ] || fail "could not find the reusable's actions/checkout pin — extraction is broken"
# Look the pin up inside the scanner reusable's OWN lock section, not the
# whole file: checkout is keyed under nearly every workflow, so a global
# search would pass even if the scanner's section lost its record.
lock_section="$(awk "/^    '\\.github\\/workflows\\/secret-scanner-reusable\\.yml':/{f=1;next} /^    '\\.github\\/workflows\\//{f=0} /^dependencies:/{f=0} f{print}" "$LOCKFILE")"
[ -n "$lock_section" ] || fail "actions.lock has no section for secret-scanner-reusable.yml — regenerate with \`gh actions-lock\`"
while IFS= read -r pin; do
  [ -n "$pin" ] || continue
  printf '%s
' "$lock_section" | grep -qF "'$pin'" \
    || fail "scanner reusable uses $pin but its actions.lock section does not key it — callers pinned to this commit will fail lock validation at startup"
done <<< "$checkout_pin"

# --- 8. actions.lock has no leaf self-SHA refs ---------------------------
# Canonical standards reusable-workflow pins are transitive, not leaf actions.
self_sha_leaves="$(awk '
  /^dependencies:/ { in_dep = 1; next }
  /^[a-z_]+:/      { in_dep = 0; cur = ""; next }
  !in_dep { next }
  /^    \x27[^\x27]+\x27:$/ {
    cur = $0; sub(/^    \x27/, "", cur); sub(/\x27:$/, "", cur)
    next
  }
  cur != "" && /^        ref: \x27[^\x27]+\x27$/ {
    r = $0; sub(/^        ref: \x27/, "", r); sub(/\x27$/, "", r)
    n = index(cur, "@")
    nwo = (n > 0) ? substr(cur, 1, n - 1) : cur
    pin = (n > 0) ? substr(cur, n + 1) : ""
    if (tolower(nwo) != "metadatastician/standards" && length(r) == 40 && r ~ /^[0-9a-fA-F]+$/ && tolower(r) == tolower(pin)) {
      print cur
    }
    cur = ""
  }
' "$LOCKFILE")"
if [ -n "$self_sha_leaves" ]; then
  fail "actions.lock contains leaf action entries with ref equal to their own SHA pin (standards#1271):"
  printf '%s\n' "$self_sha_leaves" | sed 's/^/    /'
fi

# --- Verdict ---------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  echo "::error::no-inherit: $fails check(s) failed"
  exit 1
fi
echo "no-inherit: OK — scanner caller contract holds (no inherited secrets;"
echo "  $scanned workflow(s) scanned, $wf_count lock section(s) checked)"
exit 0
