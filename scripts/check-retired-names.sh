#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# check-retired-names.sh — the mechanical half of a repository rename.
#
# DOCTRINE: 0-canon/CANONICAL-NAMES.adoc § "What a repository rename
# mechanically entails". This script is the reference implementation of the
# three mechanical pieces described there.
#
#   1. THE REGISTER — `docs/naming/retired-names.txt`
#      One retired SPELLING per line; `#` comments; blank lines ignored.
#      A register that lists one spelling checks one spelling: the register is
#      written by enumerating every spelling the name has actually appeared in
#      (case variants, hyphen/underscore/dot variants, with and without `.jl`).
#
#   2. THE ALLOWLIST — `docs/naming/retired-names-allowlist.txt`
#      One repository-relative path per line: the files that KEEP the retired
#      name as historical record (the changelog, the decision record that
#      retired it, the register and allowlist themselves, a generated module
#      that carries the characters as data, and negative-control fixtures that
#      reproduce the pre-rename defect). Exact path match — no globs, no
#      prefixes — because "everything under docs/" is an escape hatch, not a
#      record.
#
#   3. THE SPELLING-INSENSITIVE TREE CHECK — this script.
#      The primary scan is LITERAL (`grep -F`): a retired name that reappears
#      anywhere in the tracked tree, outside the allowlist, fails.
#      `--spellings` adds the normalised scan: every token in the tree is
#      lowercased and stripped of `.` `_` `-`, and compared against the
#      normalised form of each register entry. That finds a spelling the
#      register forgot to enumerate — `JuliaPackage_Reuse_Audit.jl`,
#      `juliapacakge-reuse-audit`, `JULIAPACKAGE_REUSE_AUDIT` — which a literal
#      scan of three enumerated spellings cannot see.
#      The normalised scan is REPORT-ONLY, always. It is a heuristic: it cannot
#      see a name split across words, and it can collide with unrelated text.
#      Its job is to tell the register author which spellings they missed, not
#      to fail a build.
#
# FAIL-CLOSED, BUT OPT-IN
#   No register -> no-op, exit 0. Most of the estate has never renamed anything
#   and must not be taxed for it. A register that exists but is unreadable, or
#   that declares no names, is a FAILURE: a rename with no record is exactly the
#   state this gate exists to prevent.
#
# USAGE
#   check-retired-names.sh [options]
#
#   --root DIR              repository root (default: `.`)
#   --register PATH         register path relative to root
#                           (default: docs/naming/retired-names.txt)
#   --allowlist PATH        allowlist path relative to root
#                           (default: docs/naming/retired-names-allowlist.txt)
#   --diff BASE             check added lines and added/renamed paths since BASE
#                           (pre-commit / pull-request mode)
#   --spellings             additionally run the normalised (spelling-insensitive)
#                           report
#   --strict                tree mode fails on violations (default: report-only,
#                           exit 0, because a rename lands estate-wide and the
#                           tree it lands on may be mid-migration)
#   --max-show N            show at most N findings per section (default: 25)
#   -h | --help
#
# EXIT
#   0  no violation, or report-only mode
#   1  violation (literal scan in --strict or --diff mode; unreadable/empty
#      register with --strict)
#   2  usage / environment error
#
# Shell + grep + sed + awk only. No Python, no network.

set -uo pipefail

root="."
register="docs/naming/retired-names.txt"
allowlist=""
diff_base=""
do_spellings=false
strict=false
max_show=25

while [ $# -gt 0 ]; do
  case "$1" in
    --root)       root="${2:?--root needs a value}"; shift 2 ;;
    --root=*)     root="${1#*=}"; shift ;;
    --register)   register="${2:?--register needs a value}"; shift 2 ;;
    --register=*) register="${1#*=}"; shift ;;
    --allowlist)  allowlist="${2:?--allowlist needs a value}"; shift 2 ;;
    --allowlist=*) allowlist="${1#*=}"; shift ;;
    --diff)       diff_base="${2:?--diff needs a base ref}"; shift 2 ;;
    --diff=*)     diff_base="${1#*=}"; shift ;;
    --spellings)  do_spellings=true; shift ;;
    --strict)     strict=true; shift ;;
    --max-show)   max_show="${2:?--max-show needs a value}"; shift 2 ;;
    --max-show=*) max_show="${1#*=}"; shift ;;
    -h|--help)    sed -n '2,70p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -d "$root" ] || { echo "ERROR: root '$root' is not a directory" >&2; exit 2; }
[ -n "$allowlist" ] || allowlist="$(dirname "$register")/retired-names-allowlist.txt"

reg_file="$root/$register"
allow_file="$root/$allowlist"

if [ ! -f "$reg_file" ]; then
  echo "[OK] no retired-name register at $register — nothing to check (most repositories have never renamed anything)."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Read the register. An empty register is a defect, not a pass: it is the state
# a rename leaves behind when the mechanics were skipped.
# ─────────────────────────────────────────────────────────────────────────────
names="$(grep -vE '^[[:space:]]*(#|$)' "$reg_file" | sed 's/[[:space:]]*$//')"
name_count="$(printf '%s\n' "$names" | grep -c . || true)"

if [ "$name_count" -eq 0 ]; then
  echo "[FAIL] $register exists but declares no retired names — a rename with no record leaves the next person to rediscover it."
  $strict || [ -n "$diff_base" ] && exit 1
  exit 0
fi

echo "[INFO] $name_count retired name spelling(s) from $register"

# ─────────────────────────────────────────────────────────────────────────────
# Allowlist: exact paths, comments allowed.
# ─────────────────────────────────────────────────────────────────────────────
allowed=""
if [ -f "$allow_file" ]; then
  allowed="$(grep -vE '^[[:space:]]*(#|$)' "$allow_file" | sed 's/[[:space:]]*$//')"
fi

# Return success if the repository-relative path exactly matches an allowlist entry.
is_allowed() {
  local p="$1" a
  [ -n "$allowed" ] || return 1
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ "$p" = "$a" ] && return 0
  done <<<"$allowed"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode 1: diff — only added lines, so a migration in progress is not punished
# for text it inherited. This is the pre-commit / pull-request mode.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$diff_base" ]; then
  echo "[INFO] diff mode against $diff_base (added lines and added/renamed paths)"
  # A base that does not resolve (typo, unfetched branch, shallow checkout) is
  # not "nothing was added". `git diff` used to fail inside a process
  # substitution whose status was discarded and whose stderr was suppressed, so
  # the loop saw zero lines and the gate reported OK — the worst outcome
  # available to a gate.
  if ! git -C "$root" rev-parse --verify --quiet "${diff_base}^{commit}" >/dev/null 2>&1; then
    echo "[FAIL] diff base '$diff_base' does not resolve to a commit in $root." >&2
    echo "[FAIL] Fetch it, or drop --diff to scan the whole tree." >&2
    exit 2
  fi
  patterns="$(mktemp)"; diffout="$(mktemp)"; pathsout="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$patterns' '$diffout' '$pathsout'" EXIT
  printf '%s\n' "$names" > "$patterns"
  if ! git -C "$root" diff "$diff_base" -- . > "$diffout"; then
    echo "[FAIL] git diff $diff_base failed; refusing to report a clean tree." >&2
    exit 2
  fi
  if ! git -C "$root" diff --find-renames --name-status -z --diff-filter=AR "$diff_base" -- . > "$pathsout"; then
    echo "[FAIL] git diff path metadata failed; refusing to report a clean tree." >&2
    exit 2
  fi
  violations=0
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in
      R*) IFS= read -r -d '' path || break ;;
    esac
    if printf '%s' "$path" | grep -qF -f "$patterns"; then
      is_allowed "$path" && continue
      echo "violation: added path $path reintroduces a retired name"
      violations=$((violations + 1))
    fi
  done < "$pathsout"
  current_file=""
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*)
        current_file="${line#+++ b/}"
        ;;
      "+"*)
        [ -z "$current_file" ] && continue
        body="${line#+}"
        if printf '%s' "$body" | grep -qF -f "$patterns"; then
          is_allowed "$current_file" && continue
          echo "violation: $current_file reintroduces a retired name"
          echo "   + $(printf '%s' "$body" | cut -c1-160)"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done < "$diffout"
  if [ "$violations" -gt 0 ]; then
    echo "[FAIL] $violations added line(s) or path(s) reintroduce a retired name."
    echo "[FAIL] Retired names are historical record: see $register and $allowlist."
    exit 1
  fi
  echo "[OK] no added line or path reintroduces a retired name"
  do_spellings=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# Mode 2: whole tree, literal scan (the primary check).
# ─────────────────────────────────────────────────────────────────────────────
# Tracked files only when possible: an untracked build artefact mentioning the
# old name is not a repository-state defect, and `git ls-files` respects
# .gitignore by definition.
if [ -z "$diff_base" ]; then
  patterns="$(mktemp)"; trap 'rm -f "$patterns"' EXIT
  printf '%s\n' "$names" > "$patterns"

  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files="$(git -C "$root" ls-files -z | tr '\0' '\n')"
  else
    files="$(cd "$root" && find . -type f -not -path './.git/*' | sed 's|^\./||')"
  fi

  hits=0; shown=0; violations=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # The PATH is part of the identity too. A directory called
    # `JuliaPackage-Reuse-Audit.jl/` is a surviving retired name even if every
    # file inside it is clean, and a content-only scan cannot see it.
    if printf '%s' "$f" | grep -qF -f "$patterns"; then
      hits=$((hits + 1))
      if ! is_allowed "$f"; then
        violations=$((violations + 1))
        if [ "$shown" -lt "$max_show" ]; then
          echo "  path: $f (retired name in the path itself)"
          shown=$((shown + 1))
        fi
        continue
      fi
    fi
    # Binary-safe: -I skips binary files.
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      hits=$((hits + 1))
      is_allowed "$f" && continue
      violations=$((violations + 1))
      if [ "$shown" -lt "$max_show" ]; then
        echo "  $f:$(printf '%s' "$hit" | cut -c1-140)"
        shown=$((shown + 1))
      fi
    done < <(cd "$root" && grep -n -I -F -f "$patterns" -- "$f" 2>/dev/null || true)
  done <<< "$files"

  if [ "$violations" -eq 0 ]; then
    if [ "$hits" -gt 0 ]; then
      echo "[OK] all $hits occurrence(s) of a retired name sit in the allowlisted historical record."
    else
      echo "[OK] no occurrence of any retired name in the tracked tree."
    fi
  else
    echo "[FAIL] $violations occurrence(s) of a retired name outside the allowlist (showing at most $max_show above)."
    echo "[FAIL] A retired name that survives in the tree is how the next person gets confused."
    echo "[FAIL] Either fix the reference, or add the file to $allowlist WITH A REASON."
    if $strict; then exit 1; fi
    echo "[NOTE] report-only: re-run with --strict to make this fatal (after the tree is clean)."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Mode 3: spelling-insensitive scan (--spellings). Always report-only.
#
# Every token in the tree is normalised (lowercase, strip `.` `_` `-`) and
# compared with the normalised form of each registered spelling. A token that
# matches is a spelling of a retired name that the register did not enumerate.
# ─────────────────────────────────────────────────────────────────────────────
if $do_spellings; then
  echo "[INFO] spelling-insensitive scan (report-only)"
  norm_reg="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$norm_reg' ${patterns:-}" EXIT
  printf '%s\n' "$names" | while IFS= read -r n; do
    printf '%s\n' "$n" | tr '[:upper:]' '[:lower:]' | tr -d '._-'
  done | sort -u > "$norm_reg"

  spell_hits=0
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files="$(git -C "$root" ls-files -z | tr '\0' '\n')"
  else
    files="$(cd "$root" && find . -type f -not -path './.git/*' | sed 's|^\./||')"
  fi

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_allowed "$f" && continue
    # The PATH is a spelling site as well. `JuliaPackage_Reuse_Audit/` normalises
    # to the same token as the retired `juliapackage-reuse-audit`, yet every
    # file inside it can be clean and the literal path scan only matches the
    # exact registered strings. Without this, one capitalisation moved the
    # finding out of the gate's reach.
    path_spell="$(printf '%s\n' "$f" | awk -v reg="$norm_reg" '
        BEGIN { while ((getline r < reg) > 0) want[r] = 1 }
        {
          n = split($0, parts, "/")
          for (i = 1; i <= n; i++) {
            t = tolower(parts[i]); gsub(/[._-]/, "", t)
            if (t in want) print parts[i]
          }
        }' | sort -u | head -5)"
    if [ -n "$path_spell" ]; then
      spell_hits=$((spell_hits + 1))
      if [ "$spell_hits" -le "$max_show" ]; then
        echo "  $f: unregistered spelling(s) in the PATH: $(printf '%s' "$path_spell" | tr '\n' ' ')"
      fi
    fi
    found="$(cd "$root" && grep -oI -E '[A-Za-z0-9][A-Za-z0-9._-]*' -- "$f" 2>/dev/null \
              | awk -v reg="$norm_reg" '
                  BEGIN { while ((getline r < reg) > 0) want[r] = 1 }
                  { t = tolower($0); gsub(/[._-]/, "", t); if (t in want) print $0 }
                ' | sort -u | head -5)"
    if [ -n "$found" ]; then
      spell_hits=$((spell_hits + 1))
      if [ "$spell_hits" -le "$max_show" ]; then
        echo "  $f: unregistered spelling(s): $(printf '%s' "$found" | tr '\n' ' ')"
      fi
    fi
  done <<< "$files"

  if [ "$spell_hits" -eq 0 ]; then
    echo "[OK] no unregistered spelling found in the tree"
  else
    echo "[REPORT] $spell_hits file(s) carry a spelling of a retired name the register does not list."
    echo "[REPORT] Add the spelling to $register (it is what the gate checks), then re-run."
    echo "[REPORT] This scan is heuristic and never fails a build: it cannot see a"
    echo "[REPORT] name split across words, and it can collide with unrelated text."
  fi
fi

exit 0
