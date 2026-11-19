#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-deed-lint-changed-test.sh — fixture suite for
# scripts/check-deed-lint-changed.sh. Each case builds a two-commit repository
# (base, then the change) and checks the gate's verdict.
#
# Run: bash scripts/tests/check-deed-lint-changed-test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-deed-lint-changed.sh"
LINT="$SCRIPT_DIR/../../1-formats/deed/tools/deed_lint.js"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"; echo "      $(printf '%s' "$out" | tail -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $label — output lacked '$needle'"; echo "      $(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}
g() { git -C "$d" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

GOOD=';; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "x"
  :repo-uuid #uuid"00000000-0000-8000-8000-0000000000a1"
  :beholding-chora #uuid"00000000-0000-8000-8000-0000000000a2")
'
TOML='# SPDX-License-Identifier: MPL-2.0
[metadata]
project = "x"
'
# base <name>: a repository whose base holds one good deed, one A2ML-in-a-deed
# legacy file and one A2ML file. Leaves $d set.
base() {
  d="$WORK/$1"; mkdir -p "$d/.machine_readable/descriptiles"
  git init -q "$d"
  printf '%s' "$GOOD" > "$d/x_chora.deed"
  printf '%s' "$TOML" > "$d/.machine_readable/descriptiles/STATE.deed"
  printf '%s' "$TOML" > "$d/.machine_readable/descriptiles/META.a2ml"
  g add -A && g commit -qm base
}
change() { g add -A && g commit -qm change; }
run() { bash "$GATE" HEAD~1 HEAD "$d" "$LINT"; }

echo "=== passes ==="
base none; printf 'x\n' > "$d/README.adoc"; change
assert "a change touching no .deed passes" 0 "no .deed touched" run
base untouched; printf 'x\n' > "$d/README.adoc"; change
assert "a failing deed the change does not touch is not judged" 0 "deed-lint-changed: OK" run
base editgood; sed -i 's/"x"/"x"\n  ; edited/' "$d/x_chora.deed"; change
assert "editing a good deed so it still lints passes" 0 "1 touched" run
base delete; g rm -q .machine_readable/descriptiles/STATE.deed; change
assert "deleting a failing deed passes" 0 "deed-lint-changed: OK" run
base fixture; mkdir -p "$d/tools/fixtures/heads/invalid"; printf '%s' "$TOML" > "$d/tools/fixtures/heads/invalid/bad_chora.deed"; change
assert "a negative fixture under fixtures/…/invalid/ is not judged" 0 "no .deed touched" run
base hyphen; printf '%s' "$GOOD" > "$d/-y_chora.deed"; sed -i 's/"x"/"-y"/' "$d/-y_chora.deed"; change
assert "a good deed whose name starts with a hyphen passes" 0 "1 touched" run

echo "=== failures ==="
base addtoml; printf '%s' "$TOML" > "$d/.machine_readable/descriptiles/AGENTIC.deed"; change
assert "adding TOML under a .deed name fails, with the file named" 1 "file=.machine_readable/descriptiles/AGENTIC.deed::not a deed" run
assert "the failure names deed_lint's reason, not the fallback" 1 "::not a deed: line" run
base disguise; g mv .machine_readable/descriptiles/META.a2ml .machine_readable/descriptiles/META.deed; change
assert "renaming A2ML to .deed fails (the disguise)" 1 "file=.machine_readable/descriptiles/META.deed::" run
base editbad; printf 'more = "x"\n' >> "$d/.machine_readable/descriptiles/STATE.deed"; change
assert "editing a failing deed makes it judged, and it fails" 1 "file=.machine_readable/descriptiles/STATE.deed::" run
base breakgood; printf 'key = "value"\n' >> "$d/x_chora.deed"; change
assert "breaking a good deed fails" 1 "file=x_chora.deed::" run
base badname; printf '%s' "$GOOD" > "$d/notes.deed"; change
assert "a deed whose file name deed_lint cannot dispatch fails" 1 "file=notes.deed::" run
base count; printf '%s' "$TOML" > "$d/A_praxis.deed"; printf '%s' "$GOOD" > "$d/y_chora.deed"; sed -i 's/"x"/"y"/' "$d/y_chora.deed"; change
assert "the summary counts failures against touched files" 1 "1 of 2 touched" run

echo "=== setup errors ==="
base nolint; printf 'x\n' > "$d/README.adoc"; change
assert "a missing deed_lint is a setup error" 2 "deed_lint not found" bash "$GATE" HEAD~1 HEAD "$d" "$WORK/none.js"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
