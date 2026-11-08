#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-k9.sh — the LOCAL (hook) K9 gate. It owns no rules.
#
# ── WHAT THIS FILE USED TO BE ───────────────────────────────────────────
# Until standards#1058 this hook implemented its own idea of a K9 file: it
# grepped for a line beginning `contract` and warned if no SPDX identifier
# appeared in the first five lines. Not one of the 30 tracked `*.k9` /
# `*.k9.ncl` files in this repository contains a line beginning `contract`, so
# the hook reported 30 errors on a clean tree and had no rule in common with
# any specification. That is the "local assumption" the issue asked about: it
# was not a weak implementation of the contract, it was an implementation of
# something else that happened to share a filename.
#
# ── WHAT IT IS NOW ──────────────────────────────────────────────────────
# A thin caller around the canonical validator,
# 1-formats/k9/tools/k9-validate.sh, which implements
# 1-formats/k9/spec/K9-CONTRACT-SPEC.adoc against
# 1-formats/k9/spec/contract/k9_contract.ncl. There is exactly one place where
# K9 rules are written down, and this is not it.
#
# The only thing this hook adds is POLICY about which files block a commit:
#
#   * a file changed by this commit that does not conform  -> FAIL
#   * a file in the shrink-only debt ledger that conforms  -> FAIL (stale)
#   * an unlisted, unchanged file that does not conform    -> FAIL
#   * a listed, UNCHANGED file that does not conform       -> advisory
#
# The ledger (.machine_readable/k9-contract-debt.txt) exists because the
# contract landed after 25 files did, and turning 25 files red at once is how
# this estate has twice ended up deleting a gate instead of fixing the files
# (see the A2ML notes in .githooks/pre-commit). It can only shrink: fixing a
# file forces its entry out, and an edit to a listed file removes its
# protection for that commit.
#
# Runs at --layer L1 by default. L2 needs the `nickel` binary and belongs to
# CI, where it is installed and pinned; a pre-commit hook that fails because a
# laptop lacks a toolchain teaches people to pass --no-verify. Set
# K9_VALIDATE_LAYER=all to check semantics locally too.
set -euo pipefail

REPO_ROOT="${INPUT_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

VALIDATOR="1-formats/k9/tools/k9-validate.sh"
LEDGER=".machine_readable/k9-contract-debt.txt"
LAYER="${K9_VALIDATE_LAYER:-L1}"
STAGED_FILES="${INPUT_STAGED_FILES:-}"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
[ -t 2 ] || { RED=''; GRN=''; YEL=''; BLU=''; NC=''; }

if [ ! -x "$VALIDATOR" ] && [ ! -f "$VALIDATOR" ]; then
  # Fail loudly rather than silently. A missing validator that reports success
  # is indistinguishable from a conforming tree.
  echo -e "${RED}[validate-k9] canonical validator missing: $VALIDATOR${NC}" >&2
  exit 1
fi

# The conformance fixtures are the validator's own test corpus. Scanning them
# repo-wide would report the negative controls as violations — and worse, a
# "fix" that made them pass would be a fix that broke the suite.
is_fixture() {
  case "$1" in
    1-formats/k9/tools/fixtures/*) return 0 ;;
    # 9-archive/ is a frozen district, not the live K9 corpus. It holds the
    # LAST COPY of dead upstream trees, kept because the standards-map note
    # says "ARCHIVE, do not delete" — its contents are historical record, not
    # code this estate maintains. Validating it would mean either failing the
    # archive for upstream's nonconformance or growing the debt ledger with
    # entries no one can ever discharge. So: not validated, not ledgered.
    # A grandfathered file moved here stops accruing debt rather than
    # carrying it into the archive — which is the point of archiving it.
    9-archive/*) return 0 ;;
  esac
  return 1
}

is_k9() {
  case "$1" in
    *.k9|*.k9.ncl) return 0 ;;
  esac
  return 1
}

ledger_entries() {
  [ -f "$LEDGER" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$LEDGER"
}

# Test whether $1, a repository-relative file path, exactly matches an entry
# in $LEDGER. Return grep status: 0 for a match, 1 for no match, 2 on error.
in_ledger() {
  # A here-string, deliberately, NOT `ledger_entries | grep -q`. Same SIGPIPE
  # under `set -o pipefail` as the CHANGED check below (see that comment): a
  # matching `grep -q` exits first and SIGPIPEs the grep reading the ledger, so
  # a file that IS listed reports as unlisted (#1219).
  grep -qxF -- "$1" <<< "$(ledger_entries)"
}

# Collect the file list.
FILES=()
if [ -n "$STAGED_FILES" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_k9 "$f" || continue
    is_fixture "$f" && continue
    [ -f "$f" ] || continue
    FILES+=("$f")
  done <<< "$STAGED_FILES"
else
  while IFS= read -r f; do
    is_fixture "$f" && continue
    FILES+=("$f")
  done < <(git ls-files -- '*.k9' '*.k9.ncl')
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo -e "${BLU}[validate-k9]${NC} no K9 files to check"
  exit 0
fi

# One validator invocation for the whole set: it is faster, and it keeps the
# per-file verdicts coming from a single process rather than N slightly
# different environments.
REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT
STRICT_ARGS=()
case "$LAYER" in L2|L3|all) STRICT_ARGS=(--strict) ;; esac
set +e
bash "$VALIDATOR" "${STRICT_ARGS[@]}" --layer "$LAYER" --json --quiet "${FILES[@]}" > "$REPORT"
VALIDATOR_RC=$?
set -e
if [ -n "${K9_JSON_REPORT:-}" ]; then cp "$REPORT" "$K9_JSON_REPORT"; fi
RESULTS=$(grep -cE '"verdict":"(pass|fail|error|routed)"' "$REPORT" || true)
if [ "$RESULTS" -ne "${#FILES[@]}" ]; then
  echo "[validate-k9] ERROR: expected ${#FILES[@]} file results, received $RESULTS (validator exit $VALIDATOR_RC)" >&2
  exit 2
fi
case "$VALIDATOR_RC" in 0|1) ;; *)
  echo "[validate-k9] ERROR: validator incomplete or unavailable (exit $VALIDATOR_RC)" >&2
  exit "$VALIDATOR_RC" ;;
esac

CHANGED="${K9_CHANGED_FILES:-$STAGED_FILES}"
HARD=0
ADVISORY=0
CONFORMING=0
STALE=0
ROUTED=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="$(printf '%s' "$line" | sed -E 's/.*"file":"([^"]*)".*/\1/')"
  verdict="$(printf '%s' "$line" | sed -E 's/.*"verdict":"([^"]*)".*/\1/')"
  # `|| true` is load-bearing: a conforming file has no findings, grep exits 1,
  # and under `set -o pipefail` that would abort the hook halfway through a
  # clean tree — reporting neither a pass nor a failure.
  rules="$(printf '%s' "$line" | grep -oE '"rule":"K9-[ESNC][0-9]+"' | sed 's/.*:"//; s/"//' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"

  case "$verdict" in
    routed)
      ROUTED=$((ROUTED + 1))
      continue ;;
    pass)
      CONFORMING=$((CONFORMING + 1))
      if in_ledger "$file"; then
        # A conforming file must not keep its exemption: that is how a ledger
        # becomes a permanent licence for debt that no longer exists.
        echo -e "${RED}[validate-k9] STALE ledger entry: $file now conforms — remove it from $LEDGER in this change${NC}" >&2
        STALE=$((STALE + 1))
      fi
      continue ;;
  esac

  # A here-string, deliberately, NOT `printf ... | grep -q`. Under `set -o
  # pipefail` a matching `grep -q` exits first, closes the pipe and SIGPIPEs the
  # printf, so the pipeline reports failure for a file that WAS touched — the
  # change then passes as grandfathered advisory instead of blocking (#1219,
  # measured on roughly 12-14% of large change lists). No pipe, no SIGPIPE.
  touched=0
  if [ -n "$CHANGED" ] && grep -qxF -- "$file" <<< "$CHANGED"; then
    touched=1
  fi

  if [ $touched -eq 1 ] || ! in_ledger "$file"; then
    echo -e "${RED}[validate-k9] FAIL${NC} $file ($verdict)${rules:+ — $rules}" >&2
    HARD=$((HARD + 1))
  else
    echo -e "${YEL}[validate-k9] debt${NC} $file ($verdict)${rules:+ — $rules} (grandfathered; touching it makes it blocking)" >&2
    ADVISORY=$((ADVISORY + 1))
  fi
done < "$REPORT"
rm -f "$REPORT"

if [ "$VALIDATOR_RC" -ne 0 ] && [ "$HARD" -eq 0 ] && [ "$ADVISORY" -eq 0 ]; then
  echo "[validate-k9] ERROR: validator failed without attributed violations" >&2
  exit 2
fi

if [ "$STALE" -gt 0 ] || [ "$HARD" -gt 0 ]; then
  echo -e "${RED}[validate-k9] $HARD violation(s), $STALE stale ledger entr(ies)${NC}" >&2
  echo -e "${RED}[validate-k9] spec: 1-formats/k9/spec/K9-CONTRACT-SPEC.adoc · plan: 1-formats/k9/spec/MIGRATION-1058.adoc${NC}" >&2
  exit 1
fi

echo -e "${GRN}[validate-k9]${NC} $CONFORMING conforming, $ADVISORY grandfathered, $ROUTED routed out of scope (layer $LAYER, contract v1.0.0)"
if [ "$LAYER" = "L0" ] || [ "$LAYER" = "L1" ]; then
  # Say out loud what was NOT checked. A lexical pass is not a conformance
  # result, and the difference is the whole point of §12.
  echo -e "${YEL}[validate-k9] lexical layers only — Nickel semantics (L2) and signature verification (L3) were not checked here${NC}" >&2
fi
exit 0
