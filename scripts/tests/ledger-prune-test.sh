#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ledger-prune-test.sh — fixture suite for the prune mode of the shrink-only
# ledgers and for the pre-commit hook that runs it.
#
# Under test:
#   scripts/lib/ledger-prune.sh          the one writer (deletes or lowers lines)
#   scripts/check-inline-python.sh --prune
#   scripts/check-a2ml-archived.sh --prune
#   .githooks/validate-k9.sh --prune
#   .githooks/validate-ledger-prune.sh   the pre-commit hook
#
# The invariant every case defends: a prune only deletes the lines the checker
# itself reports stale, or lowers a `path:count` the checker reports too high.
# It never adds a line, never raises a count, never reorders, and leaves
# comments and blank lines byte-for-byte. A ledger with a problem pruning may
# not hide (a new offender, a grown count) is left unchanged and the prune
# exits 1.
#
# Every fixture is a temporary directory or a temporary git repository. The
# suite reads nothing from the repository it lives in except the scripts under
# test and two K9 fixtures.
#
# Fixture text is assembled from fragments ($PY) so this file never contains
# the literal forms and does not appear in the inline-Python gate's own scan.
#
# Run: bash scripts/tests/ledger-prune-test.sh
# Fixture text is written with literal $ on purpose (it must not expand here).
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The scripts under test. A mutant run points one of these at a modified copy.
S_IPY="$REAL/scripts/check-inline-python.sh"
S_A2ML="$REAL/scripts/check-a2ml-archived.sh"
S_LIB="$REAL/scripts/lib/ledger-prune.sh"
S_K9="$REAL/.githooks/validate-k9.sh"
S_HOOK="$REAL/.githooks/validate-ledger-prune.sh"
S_MARK="$REAL/scripts/check-marker-issue-refs.sh"
S_PGQ="$REAL/scripts/check-pipe-grep-q.sh"
S_DEP="$REAL/scripts/departures.sh"
S_IE="$REAL/scripts/issue-evidence.sh"
export K9_VALIDATOR="$REAL/1-formats/k9/tools/k9-validate.sh"
K9_GOOD="$REAL/1-formats/k9/tools/fixtures/valid/kennel-data.k9.ncl"
K9_BAD="$REAL/1-formats/k9/tools/fixtures/invalid/L1-K9-S001-no-pedigree.k9.ncl"

IPY_L=.machine_readable/inline-python-allow.txt
A2ML_L=.machine_readable/a2ml-legacy-allow.txt
K9_L=.machine_readable/k9-contract-debt.txt

PY="pyth""on3"
pass=0 fail=0
OUT=""   # output of the last run, for diagnostics

# ── harness ────────────────────────────────────────────────────────────────

# check <label> <case-fn> [args…] — the case must return 0.
check() {
  local label=$1; shift
  if "$@"; then
    echo "PASS: $label"; pass=$((pass + 1))
  else
    echo "FAIL: $label"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    fail=$((fail + 1))
  fi
}

# tools <dir> — installs the scripts under test at their repository paths.
tools() {
  mkdir -p "$1/scripts/lib" "$1/.githooks"
  cp "$S_IPY" "$1/scripts/check-inline-python.sh"
  cp "$S_A2ML" "$1/scripts/check-a2ml-archived.sh"
  cp "$S_LIB" "$1/scripts/lib/ledger-prune.sh"
  cp "$S_K9" "$1/.githooks/validate-k9.sh"
  cp "$S_HOOK" "$1/.githooks/validate-ledger-prune.sh"
  cp "$S_MARK" "$1/scripts/check-marker-issue-refs.sh"
  cp "$S_PGQ" "$1/scripts/check-pipe-grep-q.sh"
  cp "$S_DEP" "$1/scripts/departures.sh"
  cp "$S_IE" "$1/scripts/issue-evidence.sh"
}

# dir <name> — a fresh plain directory (not a git repository).
dir() {
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d/.machine_readable"
  printf '%s' "$d"
}

# repo <name> — a fresh git repository holding the scripts under test, with
# core.hooksPath at a pre-commit that calls the prune hook the way
# .githooks/pre-commit's run_validator does.
repo() {
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d/.machine_readable" "$d/.hooks"
  git init -q "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.hooksPath .hooks
  tools "$d"
  cat > "$d/.hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
R="$(git rev-parse --show-toplevel)"
INPUT_PATH="$R" INPUT_STAGED_FILES="" bash "$R/.githooks/validate-ledger-prune.sh"
EOF
  chmod +x "$d/.hooks/pre-commit"
  printf '%s' "$d"
}

commit_all() { git -C "$1" add -A && git -C "$1" commit -q --no-verify -m "${2:-fixture}"; }

# run_hook <repo> — runs the prune hook directly; sets OUT, returns its status.
run_hook() {
  local rc
  OUT="$(cd "$1" && INPUT_PATH="$1" INPUT_STAGED_FILES="" bash "$1/.githooks/validate-ledger-prune.sh" 2>&1)"; rc=$?
  OUT+=$'\n'"(hook exit $rc)"
  return "$rc"
}

has() { grep -qF -- "$1" <<< "$OUT"; }
staged_ledger() { git -C "$1" show ":$2"; }

# subseq <orig> <new> — 0 when <new> is <orig> with some non-comment,
# non-blank lines deleted and some `key:N` lines lowered to `key:M`, M < N,
# and nothing else: no line added, none raised, none reordered, every comment
# and blank line kept.
subseq() {
  local -a O N
  local i=0 n o k1 k2 c1 c2 matched
  mapfile -t O < "$1"; mapfile -t N < "$2"
  for n in "${N[@]}"; do
    matched=0
    while [ "$i" -lt "${#O[@]}" ]; do
      o=${O[$i]}; i=$((i + 1))
      if [ "$n" = "$o" ]; then matched=1; break; fi
      if [[ "$o" =~ ^(.+):([0-9]+)$ ]]; then
        k1=${BASH_REMATCH[1]}; c1=${BASH_REMATCH[2]}
        if [[ "$n" =~ ^(.+):([0-9]+)$ ]]; then
          k2=${BASH_REMATCH[1]}; c2=${BASH_REMATCH[2]}
          if [ "$k1" = "$k2" ] && [ "$c2" -lt "$c1" ] && [ "$c2" -gt 0 ]; then matched=1; break; fi
        fi
      fi
      # $o is dropped: it must not be a comment or a blank line.
      [[ "$o" =~ ^[[:space:]]*(#|$) ]] && return 1
    done
    [ "$matched" -eq 1 ] || return 1
  done
  while [ "$i" -lt "${#O[@]}" ]; do
    [[ "${O[$i]}" =~ ^[[:space:]]*(#|$) ]] && return 1
    i=$((i + 1))
  done
  return 0
}

# ── inline-python: the checker's --prune ──────────────────────────────────

ipy() { # <root> [args…] — runs the inline-Python gate; sets OUT, returns status
  local root=$1 rc; shift
  tools "$WORK/bin"
  OUT="$(bash "$WORK/bin/scripts/check-inline-python.sh" --root "$root" "$@" 2>&1)"; rc=$?
  OUT+=$'\n'"(exit $rc)"
  return "$rc"
}

# A tree with one live file (w.yml, 2 hits), one cleaned file (gone.sh) and a
# ledger that lists both plus an over-counted one (low.yml: 1 hit, ledger 3).
ipy_tree() {
  local d; d=$(dir "$1")
  printf 'a: |\n  %s -c 1\n  %s -c 2\n' "$PY" "$PY" > "$d/w.yml"
  printf 'b: |\n  %s -c 1\n' "$PY" > "$d/low.yml"
  printf 'echo clean\n' > "$d/gone.sh"
  printf '# header\n#   comment with w.yml:9 inside\n\ngone.sh:1\nlow.yml:3\n\n# tail comment\nw.yml:2\n' > "$d/$IPY_L"
  printf '%s' "$d"
}

c_ipy_stale_removed() {
  local d; d=$(ipy_tree ipy1); cp "$d/$IPY_L" "$WORK/ipy1.orig"
  ipy "$d" --prune || return 1
  ! grep -qx 'gone.sh:1' "$d/$IPY_L" \
    && has "prune: delete $IPY_L:4: gone.sh:1 [stale ledger entry gone.sh:1 — no inline Python left; delete the line]"
}
c_ipy_count_lowered() {
  local d; d=$(ipy_tree ipy2)
  ipy "$d" --prune || return 1
  grep -qx 'low.yml:1' "$d/$IPY_L" && ! grep -qx 'low.yml:3' "$d/$IPY_L" \
    && has "prune: lower $IPY_L:5: low.yml:3 -> low.yml:1 [stale ledger entry low.yml:3 — now 1; shrink the ledger to low.yml:1 in this change]"
}
c_ipy_live_kept_and_comments() {
  local d; d=$(ipy_tree ipy3); cp "$d/$IPY_L" "$WORK/ipy3.orig"
  ipy "$d" --prune || return 1
  grep -qx 'w.yml:2' "$d/$IPY_L" && subseq "$WORK/ipy3.orig" "$d/$IPY_L" \
    && [ "$(grep -c '^#\|^$' "$d/$IPY_L")" -eq "$(grep -c '^#\|^$' "$WORK/ipy3.orig")" ]
}
c_ipy_then_check_passes() {
  local d; d=$(ipy_tree ipy4)
  ipy "$d" --prune || return 1
  ipy "$d" && has "none stale"
}
c_ipy_idempotent() {
  local d; d=$(ipy_tree ipy5)
  ipy "$d" --prune || return 1
  cp "$d/$IPY_L" "$WORK/ipy5.once"
  ipy "$d" --prune || return 1
  cmp -s "$WORK/ipy5.once" "$d/$IPY_L" && has "nothing stale"
}
c_ipy_new_offender_not_hidden() {
  local d; d=$(ipy_tree ipy6); cp "$d/$IPY_L" "$WORK/ipy6.orig"
  printf 'x=$(%s -c 1)\n' "$PY" > "$d/new.sh"
  ipy "$d" --prune && return 1
  case "$OUT" in *"(exit 1)") ;; *) return 1 ;; esac
  cmp -s "$WORK/ipy6.orig" "$d/$IPY_L" && has "new inline Python in new.sh"
}
c_ipy_grown_not_hidden() {
  local d; d=$(ipy_tree ipy7); cp "$d/$IPY_L" "$WORK/ipy7.orig"
  printf 'a: |\n  %s -c 1\n  %s -c 2\n  %s -c 3\n' "$PY" "$PY" "$PY" > "$d/w.yml"
  ipy "$d" --prune && return 1
  cmp -s "$WORK/ipy7.orig" "$d/$IPY_L" && has "GREW in w.yml"
}
c_ipy_malformed_refused() {
  local d; d=$(ipy_tree ipy8); printf 'w.yml:two\n' >> "$d/$IPY_L"; cp "$d/$IPY_L" "$WORK/ipy8.orig"
  ipy "$d" --prune && return 1
  cmp -s "$WORK/ipy8.orig" "$d/$IPY_L"
}
c_ipy_duplicate_stale_refused() {
  local d; d=$(ipy_tree ipy9); printf 'gone.sh:1\n' >> "$d/$IPY_L"; cp "$d/$IPY_L" "$WORK/ipy9.orig"
  ipy "$d" --prune && return 1
  cmp -s "$WORK/ipy9.orig" "$d/$IPY_L" && has "listed on lines"
}
c_ipy_no_final_newline_kept() {
  local d; d=$(ipy_tree ipy10)
  printf '# h\ngone.sh:1\nw.yml:2' > "$d/$IPY_L"
  rm "$d/low.yml"
  ipy "$d" --prune || return 1
  [ "$(cat "$d/$IPY_L"; printf x)" = "$(printf '# h\nw.yml:2x')" ]
}
c_ipy_print_and_prune_is_usage() {
  local d; d=$(ipy_tree ipy11)
  ipy "$d" --print --prune; [ $? -eq 2 ]
}

# Property: on random fixtures with no new offender, a prune exits 0, its output
# is a subsequence of its input (modulo lowered counts), the check then passes,
# and a second prune changes nothing. A fixed seed keeps the run reproducible.
c_ipy_property() {
  local trial d f hits want k body
  RANDOM=1117
  for trial in $(seq 1 12); do
    d=$(dir "ipyp$trial")
    { echo "# trial $trial"; echo; } > "$d/$IPY_L"
    for k in 1 2 3 4 5; do
      f="f$k.sh"; hits=$((RANDOM % 3)); body=""
      for _ in $(seq 1 "$hits"); do body+="$PY -c 1"$'\n'; done
      printf '%s' "$body" > "$d/$f"
      if [ $((RANDOM % 4)) -ne 0 ] || [ "$hits" -gt 0 ]; then
        want=$((hits + RANDOM % 2)); [ "$want" -gt 0 ] || want=1
        echo "$f:$want" >> "$d/$IPY_L"
      fi
      [ $((RANDOM % 2)) -eq 0 ] && echo "# note $k" >> "$d/$IPY_L"
    done
    cp "$d/$IPY_L" "$WORK/ipyp$trial.orig"
    ipy "$d" --prune || return 1
    subseq "$WORK/ipyp$trial.orig" "$d/$IPY_L" || { OUT+=$'\n'"trial $trial: not a subsequence"; return 1; }
    ipy "$d" || { OUT+=$'\n'"trial $trial: check fails after prune"; return 1; }
    cp "$d/$IPY_L" "$WORK/ipyp$trial.once"
    ipy "$d" --prune || return 1
    cmp -s "$WORK/ipyp$trial.once" "$d/$IPY_L" || { OUT+=$'\n'"trial $trial: not idempotent"; return 1; }
  done
}

echo "== inline-python --prune =="
check "inline-python: a stale line is deleted"                c_ipy_stale_removed
check "inline-python: a count above the tree is lowered"       c_ipy_count_lowered
check "inline-python: live lines, comments and blanks are kept" c_ipy_live_kept_and_comments
check "inline-python: the check passes after a prune"          c_ipy_then_check_passes
check "inline-python: prune twice equals prune once"           c_ipy_idempotent
check "inline-python: a new offender is not hidden (exit 1, ledger unchanged)" c_ipy_new_offender_not_hidden
check "inline-python: a grown count is not hidden"             c_ipy_grown_not_hidden
check "inline-python: a malformed ledger is not touched"       c_ipy_malformed_refused
check "inline-python: a stale path listed twice is refused"    c_ipy_duplicate_stale_refused
check "inline-python: a missing final newline is preserved"    c_ipy_no_final_newline_kept
check "inline-python: --print with --prune is a usage error"   c_ipy_print_and_prune_is_usage
check "inline-python: property over 12 random ledgers"         c_ipy_property

# ── a2ml: the checker's --prune ───────────────────────────────────────────

a2ml() { # <root> [args…]
  local root=$1 rc; shift
  tools "$WORK/bin"
  OUT="$(bash "$WORK/bin/scripts/check-a2ml-archived.sh" "$@" "$root" 2>&1)"; rc=$?
  OUT+=$'\n'"(exit $rc)"
  return "$rc"
}
a2ml_tree() {
  local d; d=$(dir "$1")
  : > "$d/LIVE.a2ml"; : > "$d/KEEP.a2ml.in"
  printf '# header\n\nLIVE.a2ml   # trailing comment\nGONE.a2ml\n# group\nKEEP.a2ml.in\nALSO-GONE.a2ml  # why\n' > "$d/$A2ML_L"
  printf '%s' "$d"
}
c_a2ml_stale_removed() {
  local d; d=$(a2ml_tree a1); cp "$d/$A2ML_L" "$WORK/a1.orig"
  a2ml "$d" --prune || return 1
  ! grep -q 'GONE.a2ml' "$d/$A2ML_L" && has "prune: delete $A2ML_L:4: GONE.a2ml [ledger entry 'GONE.a2ml' names no A2ML file]" \
    && has "prune: delete $A2ML_L:7: ALSO-GONE.a2ml  # why" \
    && grep -qx 'LIVE.a2ml   # trailing comment' "$d/$A2ML_L" && grep -qx 'KEEP.a2ml.in' "$d/$A2ML_L" \
    && subseq "$WORK/a1.orig" "$d/$A2ML_L"
}
c_a2ml_then_check_and_idempotent() {
  local d; d=$(a2ml_tree a2)
  a2ml "$d" --prune || return 1
  cp "$d/$A2ML_L" "$WORK/a2.once"
  a2ml "$d" || return 1
  a2ml "$d" --prune || return 1
  cmp -s "$WORK/a2.once" "$d/$A2ML_L" && has "nothing stale"
}
c_a2ml_new_offender_not_hidden() {
  local d; d=$(a2ml_tree a3); : > "$d/NEW.a2ml"; cp "$d/$A2ML_L" "$WORK/a3.orig"
  a2ml "$d" --prune && return 1
  case "$OUT" in *"(exit 1)") ;; *) return 1 ;; esac
  cmp -s "$WORK/a3.orig" "$d/$A2ML_L" && has "file=NEW.a2ml::"
}
c_a2ml_pattern_not_touched() {
  local d; d=$(a2ml_tree a4); printf 'docs/*.a2ml\n' >> "$d/$A2ML_L"; cp "$d/$A2ML_L" "$WORK/a4.orig"
  a2ml "$d" --prune && return 1
  cmp -s "$WORK/a4.orig" "$d/$A2ML_L"
}
c_a2ml_check_mode_unchanged() {
  # Check mode on a stale ledger still fails with its own message.
  local d; d=$(a2ml_tree a5); cp "$d/$A2ML_L" "$WORK/a5.orig"
  a2ml "$d" && return 1
  has "'GONE.a2ml' names no A2ML file" && cmp -s "$WORK/a5.orig" "$d/$A2ML_L"
}
c_a2ml_property() {
  local trial d k
  RANDOM=2026
  for trial in $(seq 1 10); do
    d=$(dir "a2p$trial")
    echo "# trial $trial" > "$d/$A2ML_L"
    for k in 1 2 3 4 5 6; do
      [ $((RANDOM % 2)) -eq 0 ] && : > "$d/F$k.a2ml"
      if [ -e "$d/F$k.a2ml" ] || [ $((RANDOM % 2)) -eq 0 ]; then
        if [ $((RANDOM % 3)) -eq 0 ]; then echo "F$k.a2ml  # c$k"; else echo "F$k.a2ml"; fi >> "$d/$A2ML_L"
      fi
      [ $((RANDOM % 3)) -eq 0 ] && echo >> "$d/$A2ML_L"
    done
    cp "$d/$A2ML_L" "$WORK/a2p$trial.orig"
    a2ml "$d" --prune || return 1
    subseq "$WORK/a2p$trial.orig" "$d/$A2ML_L" || { OUT+=$'\n'"trial $trial: not a subsequence"; return 1; }
    a2ml "$d" || { OUT+=$'\n'"trial $trial: check fails after prune"; return 1; }
  done
}

echo
echo "== a2ml --prune =="
check "a2ml: stale lines are deleted, live lines and comments kept" c_a2ml_stale_removed
check "a2ml: the check passes after a prune; prune is idempotent"    c_a2ml_then_check_and_idempotent
check "a2ml: a new unlisted file is not hidden (exit 1, unchanged)"   c_a2ml_new_offender_not_hidden
check "a2ml: a pattern entry blocks the prune"                        c_a2ml_pattern_not_touched
check "a2ml: check mode still fails on a stale entry"                 c_a2ml_check_mode_unchanged
check "a2ml: property over 10 random ledgers"                         c_a2ml_property

# ── k9: validate-k9.sh --prune ────────────────────────────────────────────

k9() { # <root> <staged-list|''> [args…]
  local root=$1 staged=$2 rc; shift 2
  tools "$WORK/bin"
  OUT="$(cd "$root" && INPUT_PATH="$root" INPUT_STAGED_FILES="$staged" bash "$WORK/bin/.githooks/validate-k9.sh" "$@" 2>&1)"; rc=$?
  OUT+=$'\n'"(exit $rc)"
  return "$rc"
}
k9_tree() {
  local d; d=$(repo "$1")
  mkdir -p "$d/conf"
  cp "$K9_GOOD" "$d/conf/fixed.k9.ncl"
  cp "$K9_BAD" "$d/conf/debt.k9.ncl"
  printf '# header\n\nconf/fixed.k9.ncl\n# kept\nconf/debt.k9.ncl\n' > "$d/$K9_L"
  commit_all "$d"
  printf '%s' "$d"
}
c_k9_stale_removed_live_kept() {
  local d; d=$(k9_tree k1); cp "$d/$K9_L" "$WORK/k1.orig"
  k9 "$d" "" --prune || return 1
  ! grep -qx 'conf/fixed.k9.ncl' "$d/$K9_L" && grep -qx 'conf/debt.k9.ncl' "$d/$K9_L" \
    && has "prune: delete $K9_L:3: conf/fixed.k9.ncl [conf/fixed.k9.ncl now conforms]" && subseq "$WORK/k1.orig" "$d/$K9_L"
}
c_k9_then_check_and_idempotent() {
  local d; d=$(k9_tree k2)
  k9 "$d" "" --prune || return 1
  cp "$d/$K9_L" "$WORK/k2.once"
  k9 "$d" "" || return 1
  k9 "$d" "" --prune || return 1
  cmp -s "$WORK/k2.once" "$d/$K9_L" && has "nothing stale"
}
c_k9_new_offender_not_hidden() {
  local d; d=$(k9_tree k3); cp "$K9_BAD" "$d/conf/new.k9.ncl"; git -C "$d" add conf/new.k9.ncl
  cp "$d/$K9_L" "$WORK/k3.orig"
  k9 "$d" "" --prune && return 1
  case "$OUT" in *"(exit 1)") ;; *) return 1 ;; esac
  cmp -s "$WORK/k3.orig" "$d/$K9_L" && has "conf/new.k9.ncl"
}
c_k9_unknown_argument() {
  local d; d=$(k9_tree k4)
  k9 "$d" "" --bogus; [ $? -eq 2 ]
}

echo
echo "== validate-k9 --prune =="
check "k9: a ledgered file that now conforms is deleted; debt kept" c_k9_stale_removed_live_kept
check "k9: the check passes after a prune; prune is idempotent"    c_k9_then_check_and_idempotent
check "k9: a new nonconforming file is not hidden"                 c_k9_new_offender_not_hidden
check "k9: an unknown argument is a usage error"                   c_k9_unknown_argument

# ── the pre-commit hook ───────────────────────────────────────────────────

ABG=scripts/tests/apply-branch-gates-test.sh

# The 2026-11-17 shape: a ledgered test script with one inline-Python line,
# a second ledgered file that stays live, and a commented ledger.
nov17_repo() {
  local d; d=$(repo "$1")
  mkdir -p "$d/scripts/tests"
  printf '#!/usr/bin/env bash\nset -e\nout=$(%s -c "print(1)")\necho "$out"\n' "$PY" > "$d/$ABG"
  printf 'a: |\n  %s -c 1\n' "$PY" > "$d/w.yml"
  printf 'readme\n' > "$d/README.adoc"
  printf '# SHRINK-ONLY ledger\n#\n%s:1\nw.yml:1\n' "$ABG" > "$d/$IPY_L"
  commit_all "$d"
  printf '%s' "$d"
}
clean_abg() { printf '#!/usr/bin/env bash\nset -e\necho "1"\n' > "$1/$ABG"; }

c_hook_nov17() {
  local d; d=$(nov17_repo h1)
  clean_abg "$d"; git -C "$d" add "$ABG"
  # Reproduce the failure on main: the checker reports the stale line.
  ipy "$d" && return 1
  has "stale ledger entry $ABG:1 — no inline Python left; delete the line" || return 1
  run_hook "$d" || return 1
  has "prune: delete $IPY_L:3: $ABG:1" || return 1
  grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")" && return 1
  grep -qx 'w.yml:1' <<< "$(staged_ledger "$d" "$IPY_L")" || return 1
  grep -qxF "$IPY_L" <<< "$(git -C "$d" diff --cached --name-only)" || return 1
  git -C "$d" diff --quiet -- "$IPY_L" || return 1          # working tree = index
  git -C "$d" commit -q --no-verify -m fix || return 1
  ipy "$d"
}
c_hook_through_git_commit() {
  local d; d=$(nov17_repo h2)
  clean_abg "$d"; git -C "$d" add "$ABG"
  OUT="$(git -C "$d" commit -m fix 2>&1)" || return 1
  has "prune: delete $IPY_L:3: $ABG:1" || return 1
  grep -qxF "$ABG:1" <<< "$(git -C "$d" show "HEAD:$IPY_L")" && return 1
  [ -z "$(git -C "$d" status --porcelain)" ] || { OUT+=$'\n'"status: $(git -C "$d" status --porcelain)"; return 1; }
  ipy "$d"
}
c_hook_commit_all() {
  local d; d=$(nov17_repo h3)
  clean_abg "$d"
  OUT="$(git -C "$d" commit -a -m fix 2>&1)" || return 1
  grep -qxF "$ABG:1" <<< "$(git -C "$d" show "HEAD:$IPY_L")" && return 1
  [ -z "$(git -C "$d" status --porcelain)" ]
}
c_hook_commit_only_paths_refused() {
  local d head; d=$(nov17_repo h4); head=$(git -C "$d" rev-parse HEAD)
  clean_abg "$d"
  OUT="$(git -C "$d" commit -m fix -- "$ABG" 2>&1)" && return 1
  [ "$(git -C "$d" rev-parse HEAD)" = "$head" ] || return 1
  has "$ABG:1" && has "git commit <path>" && grep -qxF "$ABG:1" "$d/$IPY_L"
}
c_hook_index_not_worktree() {
  local d; d=$(nov17_repo h5)
  # Staged: the removal. Working tree: the Python is back. The commit is
  # what counts, so the line is pruned.
  clean_abg "$d"; git -C "$d" add "$ABG"
  printf 'x=$(%s -c 1)\n' "$PY" >> "$d/$ABG"
  run_hook "$d" || return 1
  grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")" && return 1
  # Converse: removal only in the working tree, a ledgered file staged.
  d=$(nov17_repo h5b)
  clean_abg "$d"
  printf 'a: |\n  %s -c 1\n# edit\n' "$PY" > "$d/w.yml"; git -C "$d" add w.yml
  run_hook "$d" || return 1
  grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")" && grep -qxF "$ABG:1" "$d/$IPY_L"
}
c_hook_unstaged_ledger_refused() {
  local d; d=$(nov17_repo h6)
  clean_abg "$d"; git -C "$d" add "$ABG"
  printf '# a note the user is still writing\n' >> "$d/$IPY_L"
  cp "$d/$IPY_L" "$WORK/h6.wt"
  run_hook "$d" && return 1
  has "$ABG:1" && has "unstaged" && cmp -s "$WORK/h6.wt" "$d/$IPY_L" \
    && grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")"
}
c_hook_partially_staged_ledger_refused() {
  local d; d=$(nov17_repo h7)
  clean_abg "$d"; git -C "$d" add "$ABG"
  printf '# staged note\n' >> "$d/$IPY_L"; git -C "$d" add "$IPY_L"
  printf '# unstaged note\n' >> "$d/$IPY_L"
  run_hook "$d" && return 1
  has "unstaged" && grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")"
}
c_hook_new_offender_refused() {
  local d; d=$(nov17_repo h8)
  clean_abg "$d"; git -C "$d" add "$ABG"
  printf 'x=$(%s -c 1)\n' "$PY" > "$d/new.sh"; git -C "$d" add new.sh
  run_hook "$d" && return 1
  has "new inline Python in new.sh" && grep -qxF "$ABG:1" <<< "$(staged_ledger "$d" "$IPY_L")"
}
c_hook_noop_when_nothing_ledgered() {
  local d; d=$(nov17_repo h9)
  # Stub the checker: if the hook runs it, the sentinel appears.
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$WORK/h9.ran" > "$d/scripts/check-inline-python.sh"
  printf 'more\n' >> "$d/README.adoc"; printf 'echo hi\n' > "$d/other.sh"
  git -C "$d" add README.adoc other.sh
  run_hook "$d" || return 1
  [ ! -e "$WORK/h9.ran" ] && git -C "$d" diff --quiet -- "$IPY_L" \
    && ! grep -qxF "$IPY_L" <<< "$(git -C "$d" diff --cached --name-only)"
}
c_hook_a2ml_deletion() {
  local d; d=$(repo h10)
  : > "$d/LIVE.a2ml"; : > "$d/OLD.a2ml"
  printf '# ledger\n\nLIVE.a2ml   # trailing\nOLD.a2ml\n' > "$d/$A2ML_L"
  commit_all "$d"
  git -C "$d" rm -q OLD.a2ml
  run_hook "$d" || return 1
  has "prune: delete $A2ML_L:4: OLD.a2ml" \
    && ! grep -qx 'OLD.a2ml' <<< "$(staged_ledger "$d" "$A2ML_L")" \
    && grep -qx 'LIVE.a2ml   # trailing' <<< "$(staged_ledger "$d" "$A2ML_L")" \
    && git -C "$d" diff --quiet -- "$A2ML_L"
}
c_hook_k9_fixed_file() {
  local d; d=$(k9_tree h11)
  printf '# ledger\nconf/debt.k9.ncl\n' > "$d/$K9_L"; commit_all "$d"
  cp "$K9_GOOD" "$d/conf/debt.k9.ncl"; git -C "$d" add conf/debt.k9.ncl
  run_hook "$d" || return 1
  has "prune: delete $K9_L:2: conf/debt.k9.ncl" \
    && ! grep -qx 'conf/debt.k9.ncl' <<< "$(staged_ledger "$d" "$K9_L")"
}

# Wiring: .githooks/pre-commit dispatches the prune hook for every commit
# (not only when added or changed files are staged: a deletion-only commit
# counts), and before the K9 gate, which reads the ledger the prune wrote.
c_precommit_wiring() {
  local pc="$REAL/.githooks/pre-commit" p k
  p=$(grep -n '^run_validator[a-z_]* "[^"]*" "validate-ledger-prune.sh" "always"$' "$pc" | cut -d: -f1)
  k=$(grep -n '^run_validator[a-z_]* "[^"]*" "validate-k9.sh"' "$pc" | cut -d: -f1)
  OUT="prune line: ${p:-none}; k9 line: ${k:-none}"
  [ -n "$p" ] && [ -n "$k" ] && [ "$p" -lt "$k" ] && [ -x "$REAL/.githooks/validate-ledger-prune.sh" ]
}

echo
echo "== the pre-commit hook (validate-ledger-prune.sh) =="
check "hook: .githooks/pre-commit runs it on every commit, before the K9 gate"    c_precommit_wiring
check "hook: 2026-11-17 — removing inline Python prunes and stages its ledger line" c_hook_nov17
check "hook: through a real 'git commit', the tree is clean afterwards"           c_hook_through_git_commit
check "hook: 'git commit -a' commits the pruned ledger"                           c_hook_commit_all
check "hook: 'git commit <path>' is refused, naming the stale line"               c_hook_commit_only_paths_refused
check "hook: the index is judged, not the working tree (both directions)"         c_hook_index_not_worktree
check "hook: a ledger with unstaged edits is refused, not edited"                 c_hook_unstaged_ledger_refused
check "hook: a partially staged ledger is refused"                                c_hook_partially_staged_ledger_refused
check "hook: a new offender beside a stale line fails the hook"                   c_hook_new_offender_refused
check "hook: no checker runs when nothing ledgered is staged"                     c_hook_noop_when_nothing_ledgered
check "hook: deleting a ledgered A2ML file prunes its line"                       c_hook_a2ml_deletion
check "hook: fixing a ledgered K9 file prunes its line"                           c_hook_k9_fixed_file

# ── the hook on the two newer ledgers ─────────────────────────────────────

MK="TO""DO"
MARK_L=.machine_readable/marker-allow.txt
DEP_L=.machine_readable/departures.jsonl

c_hook_marker_cited() {
  local d; d=$(repo h12)
  printf '# %s: a\necho x\n' "$MK" > "$d/a.sh"
  printf '# %s: b\n' "$MK" > "$d/b.sh"
  printf '# ledger\na.sh:1\nb.sh:1\n' > "$d/$MARK_L"
  commit_all "$d"
  printf '# %s(#955): a\necho x\n' "$MK" > "$d/a.sh"; git -C "$d" add a.sh
  run_hook "$d" || return 1
  has "prune: delete $MARK_L:2: a.sh:1" \
    && ! grep -qx 'a.sh:1' <<< "$(staged_ledger "$d" "$MARK_L")" \
    && grep -qx 'b.sh:1' <<< "$(staged_ledger "$d" "$MARK_L")" \
    && bash "$d/scripts/check-marker-issue-refs.sh" --root "$d" --cached >/dev/null
}

PGQ_L=.machine_readable/pipe-grep-q-allow.txt
c_hook_pgq_fixed() {
  local d g="gr""ep"; d=$(repo h16)
  printf '#!/bin/sh\nw | %s -q a\n' "$g" > "$d/a.sh"
  printf '#!/bin/sh\nw | %s -q b\n' "$g" > "$d/b.sh"
  printf '# ledger\na.sh:1\nb.sh:1\n' > "$d/$PGQ_L"
  commit_all "$d"
  printf '#!/bin/sh\nout=$(w); %s -q a <<<"$out"\n' "$g" > "$d/a.sh"; git -C "$d" add a.sh
  run_hook "$d" || return 1
  has "prune: delete $PGQ_L:2: a.sh:1" \
    && ! grep -qx 'a.sh:1' <<< "$(staged_ledger "$d" "$PGQ_L")" \
    && grep -qx 'b.sh:1' <<< "$(staged_ledger "$d" "$PGQ_L")" \
    && bash "$d/scripts/check-pipe-grep-q.sh" --root "$d" >/dev/null
}

# drow ID CHECKS_JSON — one canonical departures row.
drow() {
  jq -c -S -n --arg id "$1" --argjson checks "$2" \
    '{id: $id, repo: "o/r", ruling: "Test ruling", claim: "The defect is present.",
      checks: $checks, fix: "open", added: "2026-11-17"}'
}
dep_repo() {
  local d; d=$(repo "$1")
  mkdir -p "$d/docs"
  printf 'defect A\ndefect B\n' > "$d/docs/a.adoc"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/scripts/gone.sh"; chmod +x "$d/scripts/gone.sh"
  {
    drow defect-a '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^defect A$"}]'
    drow defect-b '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^defect B$"}]'
    drow by-script '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^defect A$"},{"kind":"script","path":"scripts/gone.sh"}]'
  } > "$d/$DEP_L"
  commit_all "$d"
  printf '%s' "$d"
}
c_hook_departures_commit() {
  local d; d=$(dep_repo h13)
  printf 'defect A\n' > "$d/docs/a.adoc"; git -C "$d" add docs/a.adoc
  OUT="$(git -C "$d" commit -m "fix: defect B" 2>&1)" || return 1
  has "prune: delete $DEP_L:2: defect-b [RESOLVED: [0] grep-present docs/a.adoc no longer holds]" || return 1
  grep -qF '"id":"defect-b"' <<< "$(git -C "$d" show "HEAD:$DEP_L")" && return 1
  grep -qF '"id":"defect-a"' <<< "$(git -C "$d" show "HEAD:$DEP_L")" || return 1
  [ -z "$(git -C "$d" status --porcelain)" ] || return 1
  # The row whose only failing check is a script was not judged at commit
  # time (left for CI); on the real checkout `check` evaluates it.
  grep -qF '"id":"by-script"' <<< "$(git -C "$d" show "HEAD:$DEP_L")" || return 1
  OUT="$(cd "$d" && bash scripts/departures.sh check 2>&1)"
  has "by-script: RESOLVED"
}
c_hook_departures_glob() {
  local d; d=$(repo h14)
  mkdir -p "$d/docs"; printf 'fine\n' > "$d/docs/a.adoc"
  drow no-ok '[{"kind":"tree-grep-absent","glob":"docs/**","pattern":"^ok$"}]' > "$d/$DEP_L"
  commit_all "$d"
  # docs/new.adoc is spelled nowhere in the ledger; the glob still reaches it.
  printf 'ok\n' > "$d/docs/new.adoc"; git -C "$d" add docs/new.adoc
  run_hook "$d" || return 1
  has "prune: delete $DEP_L:1: no-ok" && [ -z "$(staged_ledger "$d" "$DEP_L")" ]
}

echo
echo "== the hook on marker-allow.txt and departures.jsonl =="
check "hook: citing an issue on a ledgered marker prunes its line"                c_hook_marker_cited
check "hook: fixing a pipe into a quiet grep prunes its ledger line"            c_hook_pgq_fixed
check "hook: departures — fixing a defect removes its row from the commit"        c_hook_departures_commit
check "hook: departures — a glob row is judged though no path is spelled"         c_hook_departures_glob
c_hook_departures_history() {
  local d sha; d=$(dep_repo h15); sha=$(git -C "$d" rev-parse HEAD)
  # A row that holds while a commit is in the history: the throwaway commit
  # must have HEAD as its parent, or this row would read RESOLVED and go.
  drow history "[{\"kind\":\"commit-on-main\",\"sha\":\"$sha\"}]" >> "$d/$DEP_L"
  commit_all "$d" ledger
  printf 'defect A\n' > "$d/docs/a.adoc"; git -C "$d" add docs/a.adoc
  run_hook "$d" || return 1
  grep -qF '"id":"history"' <<< "$(staged_ledger "$d" "$DEP_L")" \
    && ! grep -qF '"id":"defect-b"' <<< "$(staged_ledger "$d" "$DEP_L")"
}
check "hook: departures — a history row survives (the index commit has HEAD as parent)" c_hook_departures_history

# ── mutants: the suite must see each regression ───────────────────────────

# mutant <var> <sed-expr> <label> <case-fn> — points <var> at a copy of its
# script with <sed-expr> applied; the copy must parse and differ, and <case-fn>
# must FAIL under it.
mutant() {
  local var=$1 expr=$2 label=$3 fn=$4 src m saved
  src=${!var}; m="$WORK/mutant-$(basename "$src")"
  sed "$expr" "$src" > "$m"
  if ! bash -n "$m" || cmp -s "$m" "$src"; then
    echo "FAIL: mutant ($label) is invalid or identical to its source — it proves nothing"
    fail=$((fail + 1)); return
  fi
  saved=$src; printf -v "$var" '%s' "$m"
  if "$fn"; then
    echo "FAIL: mutant survived ($label)"; fail=$((fail + 1))
  else
    echo "PASS: mutant killed ($label)"; pass=$((pass + 1))
  fi
  printf -v "$var" '%s' "$saved"
}

echo
echo "== mutants =="
mutant S_LIB 's/^\( *\)deleted=\$((deleted + 1)) ;;/\1printf "%s%s" "$line" "$nl" >> "$out"; deleted=$((deleted + 1)) ;;/' \
  "the writer keeps a line it was told to delete" c_ipy_stale_removed
mutant S_IPY 's/if \[ "\$hard" -gt 0 \]; then/if false; then/' \
  "inline-python prunes past a new offender" c_ipy_new_offender_not_hidden
mutant S_A2ML 's/if \[ "\$hard" -ne 0 \]; then/if false; then/' \
  "a2ml prunes past a new offender" c_a2ml_new_offender_not_hidden
mutant S_HOOK 's/if ! git diff --quiet -- "\$ledger"; then/if false; then/' \
  "the hook edits a ledger with unstaged edits" c_hook_unstaged_ledger_refused
mutant S_HOOK 's/git add -- "\$ledger"/: "$ledger"/' \
  "the hook prunes but does not stage" c_hook_nov17
mutant S_HOOK 's/^is_partial_commit() {$/is_partial_commit() { return 1/' \
  "the hook edits a 'git commit <path>' commit" c_hook_commit_only_paths_refused
mutant S_HOOK '/^  .machine_readable\/departures.jsonl$/d' \
  "the hook forgets the departures ledger" c_hook_departures_commit
mutant S_HOOK 's/grep -qF '"'"'"glob":'"'"' <<< "$text"/false/' \
  "the hook judges a glob row only when a path is spelled" c_hook_departures_glob
mutant S_HOOK 's/ ${parent:+-p "$parent"}//' \
  "the index commit has no parent" c_hook_departures_history
mutant S_HOOK '/^  .machine_readable\/marker-allow.txt$/d' \
  "the hook forgets the marker ledger" c_hook_marker_cited
mutant S_HOOK '/^  .machine_readable\/pipe-grep-q-allow.txt$/d' \
  "the hook forgets the pipe-grep-q ledger" c_hook_pgq_fixed

echo
echo "ledger-prune: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
