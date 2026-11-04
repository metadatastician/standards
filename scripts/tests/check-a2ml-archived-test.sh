#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-a2ml-archived-test.sh — fixture suite for scripts/check-a2ml-archived.sh.
#
# The gate holds two promises: no A2ML file outside 9-archive/ unless the
# legacy ledger names it, and no ledger entry without its file. Each case
# below breaks exactly one of them, or one of the ledger's own rules.
#
# Run: bash scripts/tests/check-a2ml-archived-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-a2ml-archived.sh"
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

# repo <name> [ledger lines…]: a tree holding one ledgered live file and one
# archived file, with the given extra ledger lines.
repo() {
  local d="$WORK/$1"; shift
  mkdir -p "$d/.machine_readable" "$d/9-archive/a2ml/old"
  : > "$d/LIVE.a2ml"; : > "$d/9-archive/a2ml/old/GONE.a2ml"
  { printf '# header comment\n\nLIVE.a2ml   # trailing comment\n'; for l in "$@"; do printf '%s\n' "$l"; done; } > "$d/.machine_readable/a2ml-legacy-allow.txt"
  printf '%s' "$d"
}

echo "=== clean trees ==="
d=$(repo clean)
assert "a ledgered live file and an archived file pass" 0 "1 live (ledgered), 1 archived" bash "$GATE" "$d"
d=$(repo deedonly); : > "$d/repo_chora.deed"; : > "$d/notes.a2ml.md"
assert "a .deed and a name that only contains .a2ml are not A2ML files" 0 "a2ml archive gate: OK" bash "$GATE" "$d"

echo "=== A2ML outside the archive and the ledger ==="
d=$(repo stray); : > "$d/NEW.a2ml"
assert "a new unlisted .a2ml fails and is named" 1 "file=NEW.a2ml::" bash "$GATE" "$d"
d=$(repo tmpl); mkdir -p "$d/1-formats/templates"; : > "$d/1-formats/templates/META.a2ml.template"
assert "an unlisted .a2ml.template fails" 1 "META.a2ml.template" bash "$GATE" "$d"
d=$(repo vtmpl); : > "$d/STATE.a2ml.v2.template"
assert "an unlisted .a2ml.vN.template fails" 1 "STATE.a2ml.v2.template" bash "$GATE" "$d"
d=$(repo dotin); : > "$d/CLADE.a2ml.in"
assert "an unlisted .a2ml.in fails" 1 "CLADE.a2ml.in" bash "$GATE" "$d"
d=$(repo nested); mkdir -p "$d/docs/9-archive"; : > "$d/docs/9-archive/x.a2ml"
assert "a nested docs/9-archive/ is not the archive" 1 "docs/9-archive/x.a2ml" bash "$GATE" "$d"
d=$(repo sibling); mkdir -p "$d/9-archives"; : > "$d/9-archives/x.a2ml"
assert "a sibling 9-archives/ is not the archive" 1 "9-archives/x.a2ml" bash "$GATE" "$d"

echo "=== the ledger's own rules ==="
d=$(repo stale "RETIRED.a2ml")
assert "an entry whose file is gone fails (the ledger shrinks with its files)" 1 "'RETIRED.a2ml' names no A2ML file" bash "$GATE" "$d"
d=$(repo glob "docs/*.a2ml")
assert "a pattern entry fails" 1 "is a pattern" bash "$GATE" "$d"
d=$(repo arch "9-archive/a2ml/old/GONE.a2ml")
assert "an entry under 9-archive/ fails" 1 "needs no exemption" bash "$GATE" "$d"
d=$(repo dup "LIVE.a2ml")
assert "an entry listed twice fails" 1 "listed twice" bash "$GATE" "$d"
d=$(repo noledger); rm "$d/.machine_readable/a2ml-legacy-allow.txt"
assert "a missing ledger is a setup error" 2 "ledger .machine_readable/a2ml-legacy-allow.txt not found" bash "$GATE" "$d"

echo "=== git work tree ==="
if command -v git >/dev/null 2>&1; then
  d=$(repo gitrepo)
  git -C "$d" init -q && printf 'ignored.a2ml\n' > "$d/.gitignore"
  git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  : > "$d/ignored.a2ml"
  assert "an ignored file is not scanned" 0 "a2ml archive gate: OK" bash "$GATE" "$d"
  : > "$d/UNTRACKED.a2ml"
  assert "an untracked, unignored file is scanned before commit" 1 "UNTRACKED.a2ml" bash "$GATE" "$d"
  rm "$d/UNTRACKED.a2ml" "$d/LIVE.a2ml"
  assert "a ledgered file deleted from the work tree leaves a stale entry" 1 "'LIVE.a2ml' names no A2ML file" bash "$GATE" "$d"

  d=$(repo gitbase)
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  assert "--base with the same ledger passes" 0 "a2ml archive gate: OK" bash "$GATE" --base HEAD "$d"
  # The swap a count-only ratchet cannot see: one file archived, one joins.
  git -C "$d" mv LIVE.a2ml 9-archive/a2ml/LIVE.a2ml
  : > "$d/JOINER.a2ml"
  sed -i 's/^LIVE\.a2ml .*/JOINER.a2ml/' "$d/.machine_readable/a2ml-legacy-allow.txt"
  assert "a swapped entry keeps the count but fails --base" 1 "'JOINER.a2ml' is not in the ledger at HEAD" bash "$GATE" --base HEAD "$d"
  assert "the same swap without --base is only caught by the base comparison" 0 "-" bash "$GATE" "$d"
  assert "an unresolvable --base is a setup error" 2 "does not resolve" bash "$GATE" --base no-such-ref "$d"

  d=$(repo gitboot); rm "$d/.machine_readable/a2ml-legacy-allow.txt"; : > "$d/.machine_readable/keep"
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  printf 'LIVE.a2ml\n' > "$d/.machine_readable/a2ml-legacy-allow.txt"
  assert "a ledger new since --base is the bootstrap and passes" 0 "bootstrap" bash "$GATE" --base HEAD "$d"

  d=$(repo gitsymlink)
  git -C "$d" init -q && ln -s no-such-target "$d/LINKED.a2ml"
  git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  assert "a tracked dangling A2ML symlink is still scanned" 1 "LINKED.a2ml" bash "$GATE" "$d"

  d=$(repo gitquoted)
  git -C "$d" init -q && : > "$d/$(printf 'caf\303\251.a2ml')"
  git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  assert "a tracked non-ASCII name is still scanned (git would quote it)" 1 "$(printf 'caf\303\251.a2ml')" bash "$GATE" "$d"
else
  echo "FAIL: git is required for the work-tree cases"; fail=$((fail + 1))
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
