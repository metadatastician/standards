# shellcheck shell=bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# proof-receipt.sh: the shared generator and gate of a proof receipt in the
# shape of PROOF-POLICY §8.5.1 and §8.5.2 (profile proof-receipt), with the
# git checks of §8.5.3.  One generator for every home repository, beside the
# reader it is checked by (1-formats/deed/tools/deed_lint.js), the reference
# digest (scripts/proof-inputs-sha256.sh) and the shared git checker
# (scripts/check-proof-receipt.sh), so one standards commit pins all four.
#
# This file is SOURCED, not run.  The home repository's receipt script
# (conventionally scripts/grade-receipt.sh) fetches this file with the other
# three at its pinned standards commit, checks their sha256, defines its data
# and hooks, and ends with
#
#   . "$RECEIPT_STD/scripts/proof-receipt.sh"
#   receipt_main "$@"
#
# Modes of receipt_main:
#   --write [--commit SHA]
#                        write the receipt from the tree and the ledgers
#                        (--commit names the :source-commit when no leg has a
#                        current run; it must be on the default branch)
#   --check              regenerate it, refuse any difference, do the git
#                        checks of §8.5.3, check that each current receipt
#                        still describes the tree (its home inputs, and its
#                        imports as the hook gives them at HEAD, with each
#                        imported clone holding the pinned files), and run
#                        the pinned reader with a negative control.  Exit 1
#                        is a refusal; exit 2 means the git checks could not
#                        run (no default branch, a tool missing)
#   --digest PROVER      print the §8.5.1 inputs digest of one leg (agda, rocq,
#                        lean, or a prover receipt_extra_legs names)
#   --inputs PROVER      print the §8.5.1 input set of one leg, one path a line
#   --run-row PROVER --run URL --commit SHA --checker TEXT --reported TEXT
#                        --axioms none|NAME:c|b|debt[,…]
#                        [--image NAME@sha256:<64 hex>]
#                        print one ledger row for a run that just passed
#                        (--axioms: what the run's own report listed, "none"
#                        when it listed none; the row never assumes it.
#                        --image: the digest-pinned image the checker ran
#                        in; without it the run never counts toward PWG-1)
#   --emit-run ROWS --out FILE
#                        write a receipt for the run whose rows are in ROWS:
#                        they become current, and the earlier current receipts
#                        of the same legs become superseded (CI does this)
#   --record ROWS        with a ledger file (RECEIPT_LEDGER): check the rows in
#                        ROWS with the ledger, write the receipt they give,
#                        and append them to the ledger file.  A row that does
#                        not describe the tree, or a run the ledger already
#                        holds, is refused and nothing is written.  This is
#                        the one call a recorder makes; what it writes is a
#                        proposal until --check and a review accept it
#
# What the home script provides.  Variables:
#   RECEIPT_STD             directory holding the pinned standards files, in
#                           the standards layout
#   RECEIPT_STANDARDS_COMMIT  the standards commit they were fetched at
#   RECEIPT_OUT             the receipt path, e.g. verification/receipts/agda_praxis.deed
#   RECEIPT_REPOSITORY      OWNER/REPO
#   RECEIPT_DEFAULT_BRANCH  e.g. main
#   RECEIPT_CANONICAL_NAME  the receipt's :canonical-name
#   RECEIPT_SCRIPT          the home script's path, for messages
#   RECEIPT_LEDGER          optional: the run ledger as a data file, one row a
#                           line in the receipt_runs format (# starts a
#                           comment line).  With it the home script defines
#                           no receipt_runs.  The file is append-only: --check
#                           and --write refuse a ledger that changed, moved
#                           or dropped a row the default branch holds
#   RECEIPT_BEHOLDING_CHORA optional: the receipt's :beholding-chora, written
#                           as given, a #u8"…" or #uuid"…" literal (the
#                           estate chora's id, as the home chora deed has it)
#   RECEIPT_KEEP_LINEAGE_DETAIL  optional, 0 (the default) or 1.  With 1, a
#                           receipt that is not current (superseded,
#                           regressed or stale) keeps what its run read: its
#                           :inputs-sha256 and (axioms …) from the ledger row,
#                           and its (inputs-manifest …), rebuilt at the row's
#                           commit from the current receipt_inputs hook.  A
#                           manifest is written only when it hashes to the
#                           row's digest; when the commit is not here or the
#                           input set has moved since, the receipt is written
#                           without it and a NOTE names the run.  Set it the
#                           same for --write and --check: a receipt written
#                           with it does not match a check without it.  With
#                           0 the output is what it was before the option.
# Functions (each prints to stdout):
#   receipt_claims          the claim list: id | §5 token of the Agda proof |
#                           kind | Rocq route | Rocq §2.2 state | Lean route |
#                           Lean §2.2 state | Rocq reason | Lean reason.
#                           A claim whose token is not proven or
#                           proven-with-postulates has no Agda proof yet: its
#                           Agda leg is AGDA-PENDING with no receipt and it
#                           is ungraded.  A recheck leg the kernel accepted
#                           but whose statement is not reconciled is
#                           COQ-CHECKED (Rocq), LEAN-CHECKED (Lean) or
#                           BRIDGE-PENDING: its token is proven and it
#                           carries its receipts, but it counts toward no
#                           grade
#   receipt_runs            the run ledger: prover | run | commit (40 hex) |
#                           checker | invocation | inputs sha256 | what the run
#                           reported | state (current|superseded|regressed; stale
#                           and, among rows typed current, superseded are
#                           derived, never typed: see Derived states) |
#                           reason | axioms (name:c|b|debt, comma-separated)
#                           [| imports: OWNER/REPO@COMMIT=SHA256, comma-separated,
#                           which --run-row writes when the leg imports files
#                           [| trusted base: the sha256 of what
#                           receipt_trusted_base printed, on an Agda row whose
#                           trusted base is not empty; the imports field may
#                           then be empty
#                           [| image: NAME[:TAG]@sha256:<64 hex>, the
#                           digest-pinned image the checker ran in, which
#                           --run-row --image writes; fields 11 and 12 may
#                           then be empty; PWG-1 needs it on all three legs]]]).
#                           The gate refuses a current row whose bindings
#                           differ from what the hooks derive now: the run is
#                           recorded again (§8.4)
#   receipt_echoes          the echo ledger: source | image | inputs-sha256 |
#                           fetch ref
#   receipt_header          the comment lines that open the receipt, after
#                           nothing (the SPDX lines are the home's to write)
#   receipt_trusted_base    module | name | binding, one line per Agda
#                           prover postulate of §8.4
#   receipt_invocation P    the invocation of leg P
#   receipt_inputs P        the §8.5.1 input set of leg P: paths of files of
#                           the home repository, one a line (sorted here)
#   receipt_status_ids      the claim ids the home proof-status file lists
#   receipt_recorded_legs   the claim ids whose recheck legs the home legs
#                           record lists as RECONCILED
# Every hook exits 0, also when it has nothing to print; any other exit is a
# refusal, and the gate stops naming the hook.
# And optionally:
#   receipt_imports P C     the files of other repositories that leg P read
#                           at home commit C, one a line:
#                           OWNER/REPO | COMMIT (40 hex) | CLONE DIR | PATH
#                           (PATH relative to that repository's root).  They
#                           become (import …) clauses of the current receipt
#                           (§8.5.1, Imported repositories).  Default: none.
#   receipt_ensure_import R C D   make commit C of R present in clone D.
#                           Default: refuse when it is not there.
#   receipt_run_scope       the claims a run that is not current checked,
#                           when it did not check every claim with its leg,
#                           one run a line: prover | run | claim ids
#                           (space-separated).  That run's receipt is then
#                           listed under those claims only, so a claim's
#                           lineage never names a run that did not check it.
#                           A current run checks every claim with its leg,
#                           and is refused here.  Default: every run covers
#                           every claim with its leg.
#   receipt_extra_legs      legs outside dependent type theory (§8.3), one a
#                           line: claim id | prover | route | §2.2 state |
#                           reason.  The prover is a lowercase name other than
#                           agda, rocq and lean, and it then takes run rows,
#                           inputs and an invocation like any other leg.  A
#                           claim's :foundation-diverse is #t when one of its
#                           such legs is RECONCILED with a current receipt
#                           whose axioms are all of disposition (c).
#                           Default: none.
#
# Helpers the hooks may use: receipt_agda_cone ROOT INCLUDE... (the modules a
# root imports, directly or not, found under the include directories in
# order), receipt_die MESSAGE.
#
# Legs at different commits: each current leg is followed along its own echo
# chain (§8.5.2).  The :source-commit is the end of the Agda leg's chain (of
# the first current leg's, when Agda has none), and a leg whose chain ends
# elsewhere still counts toward PWG-2i and PWG-2ii but not PWG-1.  An echo
# carries a witness for each current leg whose chain passes through it, and is
# left out when no chain does.
#
# The grade is never typed: it is derived here under §8.2 and §8.5.2 and
# derived again by the pinned reader, which refuses a receipt whose :pwg its
# legs and receipts do not support (§8.4).

receipt_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── Pinned standard files, in the standards layout under $RECEIPT_STD ────────
_receipt_reader() { printf '%s/1-formats/deed/tools/deed_lint.js' "$RECEIPT_STD"; }
_receipt_digest_script() { printf '%s/scripts/proof-inputs-sha256.sh' "$RECEIPT_STD"; }
_receipt_checker() { printf '%s/scripts/check-proof-receipt.sh' "$RECEIPT_STD"; }

# The Agda cone: ROOT and every module it imports, directly or not, that is a
# file under one of the include directories (the first that holds it).  A
# text scan of import statements; a gate should check it against
# agda --dependency-graph, so a scan that drifts from Agda fails there.
# Modules supplied with the prover are under no include directory and are
# not printed.
receipt_agda_cone() {
  local root="${1#./}"; shift
  local -a incs=("$@")
  local f m p i
  local -A seen=()
  local -a queue=("$root")
  while (( ${#queue[@]} )); do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    [[ -z "${seen[$f]:-}" ]] || continue
    seen[$f]=1
    printf '%s\n' "$f"
    while read -r m; do
      for i in "${incs[@]}"; do
        # A source module, plain or literate (the extensions Agda reads).
        for x in .agda .lagda .lagda.tex .lagda.md .lagda.rst .lagda.org .lagda.typ .lagda.tree; do
          p="$i/${m//.//}$x"; p="${p#./}"
          if [[ -f "$p" ]]; then queue+=("$p"); continue 3; fi
        done
      done
    # Split into tokens across lines, so a module name on the line after its
    # `import` is found too; the token after each `import` is the module.
    done < <(sed -e 's/--.*$//' "$f" | tr -s ' \t\r\n;(){}' '\n' | awk 'p{print; p=0; next} $0=="import"{p=1}')
  done
}

_receipt_inputs() {
  local f; f="$(mktemp)"
  receipt_inputs "$1" > "$f" || { rm -f "$f"; receipt_die "the hook receipt_inputs of $RECEIPT_SCRIPT failed for $1"; }
  # A leading ./ is dropped, as the reference digest drops it, so the working
  # tree and a commit hash the same manifest.
  sed 's|^\./||' "$f" | LC_ALL=C sort -u; rm -f "$f"
}
_receipt_imports() {
  if declare -F receipt_imports >/dev/null; then receipt_imports "$1" "$2"; fi
}

# The §8.5.1 digest of a leg's home inputs in the working tree.  On a clean
# checkout this is the reference digest at HEAD; --check confirms that with
# the reference script.
_receipt_digest() {
  local prover="$1" paths p
  paths="$(_receipt_inputs "$prover")"
  [[ -n "$paths" ]] || receipt_die "the $prover leg has no inputs"
  while IFS= read -r p; do
    git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || receipt_die "$p is not tracked by git"
    # A pathspec also matches a directory with tracked files; an input is a file.
    [[ -f "$p" ]] || receipt_die "$p is not a regular file"
    # The reference digest hashes a link's git blob (its target text), which
    # sha256sum of the working tree would not: refuse rather than disagree.
    [[ ! -L "$p" ]] || receipt_die "$p is a symbolic link; list the file it points to as the input"
    # The reference digest refuses these, and sha256sum would escape them.
    [[ "$p" != *'\'* ]] || receipt_die "$p holds a backslash, which §8.5.1 refuses in an input path"
  done <<< "$paths"
  printf '%s\n' "$paths" | xargs -d '\n' sha256sum -- | sha256sum | cut -d' ' -f1
}
# The reference digest of a leg's home inputs at a commit, over the input set
# of the working tree.  If a file of that set is missing at the commit, the
# script fails and so does the gate.
_receipt_ref_digest() {
  local commit="$1" prover="$2"
  local -a paths
  mapfile -t paths < <(_receipt_inputs "$prover")
  (( ${#paths[@]} )) || receipt_die "the $prover leg has no inputs"
  bash "$(_receipt_digest_script)" "$commit" "${paths[@]}"
}
# Make a home commit available, fetching the forge reference that keeps it.
# Make commit $1 present.  With a forge reference $2, the reference is fetched
# and must hold the commit even when the commit is already here: a receipt is
# only as recoverable as the reference it records, and a clean clone has only
# that reference to find the commit by.
_receipt_ensure_commit() {
  local commit="$1" ref="${2:-}" at
  if [[ -z "$ref" ]]; then
    git cat-file -e "$commit^{commit}" 2>/dev/null || receipt_die "commit $commit is not here and has no fetch reference"
    return 0
  fi
  at="refs/remotes/origin/receipt-fetch/${commit:0:12}"
  git fetch -q origin "+$ref:$at" || receipt_die "cannot fetch $ref for commit $commit"
  git merge-base --is-ancestor "$commit" "$at" 2>/dev/null || receipt_die "$ref does not hold commit $commit"
}
_receipt_ensure_import() {
  local repo="$1" commit="$2" dir="$3"
  if git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then return 0; fi
  if declare -F receipt_ensure_import >/dev/null; then
    receipt_ensure_import "$repo" "$commit" "$dir" || receipt_die "the hook receipt_ensure_import of $RECEIPT_SCRIPT failed for $repo at $commit"
  fi
  git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null \
    || receipt_die "the clone $dir of $repo does not hold commit $commit"
}
_receipt_echo_ref() { local c="$1"; awk -F'|' -v c="$c" '$1==c{print $4}' "$_receipt_echoes_file"; }

# ── Ledger rows ───────────────────────────────────────────────────────────────
# Validate one row; print nothing.  A field may not hold " or \ (deed strings)
# and may not be empty, except the reason of a current receipt and the axioms.
# An image reference as the reader (deed_lint.js, readProofReceipt) accepts
# it, so that a row --run-row writes is never refused later by --emit-run:
# the distribution/reference grammar, with an optional registry host (a DNS
# name or a bracketed IPv6 address, with an optional port), non-empty
# lower-case path components, an optional tag of up to 128 characters, a
# lower-case sha256 digest, and a NAME (host and path) of at most 255
# characters.
_receipt_image_ok() {
  local comp='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
  local domain='([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*|\[[a-fA-F0-9:]+\])'
  local re="^((${domain}(:[0-9]+)?/)?${comp}(/${comp})*)(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}\$"
  [[ "$1" =~ $re ]] && (( ${#BASH_REMATCH[1]} <= 255 ))
}
_receipt_check_row() {
  local row="$1" prover run commit checker inv dig said state reason axioms imports tb img x n
  local -a a
  IFS='|' read -r prover run commit checker inv dig said state reason axioms imports tb img <<< "$row"
  # Ten fields; eleven when the run read files of an imported repository,
  # whose last field binds those files to the run (OWNER/REPO@COMMIT=SHA256,
  # comma-separated); twelve on an Agda row with a trusted base, whose last
  # field is that list's sha256 (the imports field may then be empty).  So a
  # receipt can never re-describe what a run imported or trusted.  Thirteen
  # when the run recorded the digest-pinned image its checker ran in, the last
  # field (fields 11 and 12 may then be empty): only such a run can count
  # toward PWG-1 (PROOF-POLICY §8.2, owner ruling 2026-11-16).
  n="$(tr -cd '|' <<< "$row" | wc -c)"
  [[ "$n" == 9 || "$n" == 10 || "$n" == 11 || "$n" == 12 ]] || receipt_die "a ledger row needs 10 fields, 11 with imports, 12 with a trusted base, or 13 with an image: $row"
  if [[ "$n" == 10 || ( "$n" -ge 11 && -n "$imports" ) ]]; then
    [[ "$imports" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}=[0-9a-f]{64}(,[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}=[0-9a-f]{64})*$ ]] \
      || receipt_die "a row's imports must be OWNER/REPO@COMMIT=SHA256, comma-separated: $row"
  fi
  if [[ "$n" == 11 || ( "$n" == 12 && -n "$tb" ) ]]; then
    [[ "$prover" == agda ]] || receipt_die "only an Agda row binds a trusted base: $row"
    [[ "$tb" =~ ^[0-9a-f]{64}$ ]] || receipt_die "a row's trusted-base binding must be a sha256: $row"
  fi
  if [[ "$n" == 12 ]]; then
    _receipt_image_ok "$img" || receipt_die "a row's image must be NAME[:TAG]@sha256:<64 hex>, NAME as the reader accepts it: $row"
  fi
  [[ "$row" != *'"'* && "$row" != *'\'* ]] || receipt_die "a ledger row holds a quote or backslash: $row"
  [[ "$row" != *[[:cntrl:]]* ]] || receipt_die "a ledger row holds a control character, which a deed string cannot: $row"
  _receipt_is_prover "$prover" || receipt_die "unknown prover in row (agda, rocq, lean, or one that receipt_extra_legs names): $row"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || receipt_die "a row's commit must be 40 lowercase hex: $row"
  [[ "$dig" =~ ^[0-9a-f]{64}$ ]] || receipt_die "a row's inputs digest must be a sha256: $row"
  [[ -n "$run" && -n "$checker" && -n "$inv" && -n "$said" ]] || receipt_die "an empty field in row: $row"
  case "$state" in
    current) [[ -z "$reason" ]] || receipt_die "a current row carries no reason: $row" ;;
    superseded|regressed) [[ -n "$reason" ]] || receipt_die "a $state row needs a reason: $row" ;;
    stale) receipt_die "stale is derived from the tree, never typed: give the row as current, and the generator says when it is stale: $row" ;;
    *) receipt_die "unknown receipt state in row: $row" ;;
  esac
  if [[ -n "$axioms" ]]; then
    IFS=',' read -ra a <<< "$axioms"
    for x in "${a[@]}"; do [[ "$x" =~ ^[^:]+:(c|b|debt)$ ]] || receipt_die "an axiom must be name:c, name:b or name:debt: $row"; done
  fi
}
_receipt_check_echo() {
  local row="$1" src img wit ref
  IFS='|' read -r src img wit ref <<< "$row"
  [[ "$src" =~ ^[0-9a-f]{40}$ && "$img" =~ ^[0-9a-f]{40}$ ]] || receipt_die "an echo needs two 40-hex commits: $row"
  [[ "$src" != "$img" ]] || receipt_die "an echo joins a commit to itself: $row"
  [[ "$wit" == inputs-sha256 ]] || receipt_die "this generator writes the inputs-sha256 witness only: $row"
  [[ "$ref" =~ ^refs/ ]] || receipt_die "an echo needs the forge reference that keeps its source: $row"
}
# An import line: OWNER/REPO | COMMIT | DIR | PATH.
_receipt_check_import() {
  local row="$1" repo commit dir path
  IFS='|' read -r repo commit dir path <<< "$row"
  [[ "$(tr -cd '|' <<< "$row" | wc -c)" == 3 ]] || receipt_die "an import line needs 4 fields: $row"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || receipt_die "an import needs OWNER/REPO: $row"
  [[ "${repo,,}" != "${RECEIPT_REPOSITORY,,}" ]] || receipt_die "a repository does not import itself: $row"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || receipt_die "an import's commit must be 40 lowercase hex: $row"
  [[ -d "$dir" && -n "$path" ]] || receipt_die "an import needs its clone directory and a path: $row"
  [[ "$path" != *'"'* && "$path" != *'\'* ]] || receipt_die "an import path holds a quote or backslash: $row"
}

# The ledger in force: receipt_runs, plus the rows of $_receipt_extra (a
# file) as current; an earlier current row of a prover that $_receipt_extra
# covers becomes superseded.
_receipt_extra=
_receipt_new_rows=
# The rows of the ledger file RECEIPT_LEDGER names: one row a line; a line
# starting with # and an empty line are not rows.  The file is data: a row is
# never the output of a hook, so a later change to a hook cannot re-describe a
# run that is past.
_receipt_read_ledger_file() {
  [[ -f "$RECEIPT_LEDGER" && ! -L "$RECEIPT_LEDGER" ]] || receipt_die "the run ledger $RECEIPT_LEDGER is not a regular file"
  grep -v '^#' "$RECEIPT_LEDGER" | grep '[^[:space:]]' || true
}
# The ledger file is append-only (§8.4, lineage is kept): each row it holds on
# the default branch is still there, unchanged and in place, and rows are only
# added after them.  A ledger the default branch does not hold yet is new.
_receipt_check_append_only() {
  local base n=0 want got
  base="refs/remotes/origin/$RECEIPT_DEFAULT_BRANCH"
  git rev-parse -q --verify "$base^{commit}" >/dev/null || base="refs/heads/$RECEIPT_DEFAULT_BRANCH"
  # With neither reference the git checks of §8.5.3 stop the gate (exit 2).
  git rev-parse -q --verify "$base^{commit}" >/dev/null || return 0
  git cat-file -e "$base:$RECEIPT_LEDGER" 2>/dev/null || return 0
  while IFS= read -r want; do
    n=$((n + 1))
    got="$(sed -n "${n}p" "$_receipt_runs_file")"
    [[ "$want" == "$got" ]] || receipt_die "the run ledger $RECEIPT_LEDGER is append-only: row $n of $RECEIPT_DEFAULT_BRANCH was changed, moved or removed (or this branch is behind $RECEIPT_DEFAULT_BRANCH: merge it first). The row reads: $want"
  done < <(git show "$base:$RECEIPT_LEDGER" | grep -v '^#' | grep '[^[:space:]]' || true)
}
_receipt_ledger() {
  local row prover run state
  local -A replaced=()
  if [[ -n "$_receipt_extra" ]]; then
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      IFS='|' read -r prover run _ _ _ _ _ state _ <<< "$row"
      # The rows of a run are what that run earned, so they become current.
      [[ "$state" == current ]] || receipt_die "a row given to --emit-run must be current: $row"
      replaced[$prover]="$run"
      printf '%s\n' "$row"
    done < "$_receipt_extra"
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r prover _ _ _ _ _ _ state _ <<< "$row"
    if [[ "$state" == current && -n "${replaced[$prover]:-}" ]]; then
      printf '%s|superseded|replaced by the later run %s|%s\n' "$(cut -d'|' -f1-7 <<< "$row")" "${replaced[$prover]}" "$(cut -d'|' -f10 <<< "$row")"
    else
      printf '%s\n' "$row"
    fi
  done < "$_receipt_runs_file"
}

# ── Provers ───────────────────────────────────────────────────────────────────
# Agda, Rocq and Lean, then each prover outside dependent type theory that
# receipt_extra_legs names (§8.3), in name order.
_receipt_provers=(agda rocq lean)
_receipt_extra_legs_file=
_receipt_load_provers() {
  local id prover route state reason row
  _receipt_extra_legs_file="$(mktemp)"; _receipt_tmpfiles+=("$_receipt_extra_legs_file" "$_receipt_extra_legs_file.claim")
  if declare -F receipt_extra_legs >/dev/null; then
    _receipt_hook "$_receipt_extra_legs_file.raw" receipt_extra_legs
    _receipt_tmpfiles+=("$_receipt_extra_legs_file.raw")
    grep . "$_receipt_extra_legs_file.raw" > "$_receipt_extra_legs_file" || true
  fi
  while IFS= read -r row; do
    [[ "$(tr -cd '|' <<< "$row" | wc -c)" == 4 ]] || receipt_die "an extra leg needs 5 fields (claim id | prover | route | state | reason): $row"
    IFS='|' read -r id prover route state reason <<< "$row"
    [[ "$row" != *'"'* && "$row" != *'\'* && "$row" != *[[:cntrl:]]* ]] || receipt_die "an extra leg holds a quote, backslash or control character: $row"
    [[ "$prover" =~ ^[a-z][a-z0-9-]*$ ]] || receipt_die "an extra leg's prover must be a lowercase name: $row"
    [[ ! "$prover" =~ ^(agda|rocq|lean)$ ]] || receipt_die "agda, rocq and lean legs come from receipt_claims, not receipt_extra_legs: $row"
    awk -F'|' -v i="$id" '$1==i && $3=="theorem"{f=1} END{exit !f}' "$_receipt_claims_file" \
      || receipt_die "an extra leg names no theorem claim of receipt_claims: $row"
    [[ "$route" =~ ^(transported|re-proved|waived|unavailable)$ ]] || receipt_die "an extra leg's route must be transported, re-proved, waived or unavailable: $row"
  done < "$_receipt_extra_legs_file"
  [[ "$(cut -d'|' -f1,2 "$_receipt_extra_legs_file" | sort | uniq -d | wc -l)" == 0 ]] || receipt_die 'a claim has two extra legs of one prover'
  mapfile -t -O 3 _receipt_provers < <(cut -d'|' -f2 "$_receipt_extra_legs_file" | LC_ALL=C sort -u)
}
_receipt_is_prover() { local x; for x in "${_receipt_provers[@]}"; do [[ "$x" != "$1" ]] || return 0; done; return 1; }

# ── Grade (§8.2 and §8.5.2, the same rules as readProofReceipt) ───────────────
_receipt_has_current() { awk -F'|' -v p="$1" '$1==p && $8=="current"{f=1} END{exit !f}' "$_receipt_ledger_file"; }
_receipt_current_field() { awk -F'|' -v p="$1" -v f="$2" '$1==p && $8=="current"{print $f}' "$_receipt_ledger_file"; }
_receipt_has_any() {
  local row p run state
  while IFS= read -r row; do
    IFS='|' read -r p run _ _ _ _ _ state _ <<< "$row"
    [[ "$p" == "$1" ]] && _receipt_in_scope "$p" "$run" "$state" && return 0
  done < "$_receipt_ledger_file"
  return 1
}

# ── Derived states (PROOF-POLICY §8.4) ────────────────────────────────────────
# A ledger row is typed `current` when its run passed, and `regressed` or
# `superseded` (with a reason) when someone knows more.  Of the rows typed
# current, what git can tell is derived here and never typed:
#
#  superseded  A leg with several rows typed current keeps the newest as
#              current; each earlier one is superseded by it.  A row typed
#              regressed is ordered with them, so a later failure supersedes
#              an earlier pass and the leg is left with no current receipt.  Newest is by
#              ancestry of the rows' commits; rows at one commit keep ledger
#              order, the later row being the newer.  Commits that git cannot
#              order are refused.
#  stale       The newest row no longer describes the tree: the leg's inputs
#              digest, its imports or (Agda) its trusted base differ from the
#              tree's.  The source may well still check; no run of the new
#              inputs is recorded yet.  A stale receipt counts toward no
#              grade, and becomes current again if the tree returns to what
#              the run read.
#
# So a change to a leg's inputs needs no edit of the ledger: --write derives
# the state, and the grade falls to what the remaining receipts support.
# The rewritten rows replace the ledger in force; the typed rows are untouched.
_receipt_stale_notes=()
_receipt_derive_states() {
  local p row line newest newest_commit newest_run c run d want got why out
  local -a lines commits runs states
  out="$(mktemp)"; _receipt_tmpfiles+=("$out")
  cp -- "$_receipt_ledger_file" "$out"
  for p in "${_receipt_provers[@]}"; do
    # A run typed regressed is evidence too: a later failure outranks an
    # earlier pass, so it is ordered with the rows typed current.
    mapfile -t lines < <(awk -F'|' -v p="$p" '$1==p && ($8=="current" || $8=="regressed"){print NR}' "$_receipt_ledger_file")
    (( ${#lines[@]} )) || continue
    commits=(); runs=(); states=()
    for line in "${lines[@]}"; do
      states+=("$(awk -F'|' -v n="$line" 'NR==n{print $8}' "$_receipt_ledger_file")")
      commits+=("$(awk -F'|' -v n="$line" 'NR==n{print $3}' "$_receipt_ledger_file")")
      runs+=("$(awk -F'|' -v n="$line" 'NR==n{print $2}' "$_receipt_ledger_file")")
    done
    # The newest: no other row's commit descends from it, and of the rows at
    # that commit it is the last.
    newest=0
    for (( c = 1; c < ${#lines[@]}; c++ )); do
      if [[ "${commits[c]}" == "${commits[newest]}" ]]; then newest=$c; continue; fi
      if ! git cat-file -e "${commits[c]}^{commit}" 2>/dev/null || ! git cat-file -e "${commits[newest]}^{commit}" 2>/dev/null; then
        receipt_die "cannot order the current rows of the $p leg: commit ${commits[c]} or ${commits[newest]} is not here; fetch the default branch"
      fi
      if git merge-base --is-ancestor "${commits[newest]}" "${commits[c]}"; then newest=$c
      elif git merge-base --is-ancestor "${commits[c]}" "${commits[newest]}"; then :
      else receipt_die "cannot order the current rows of the $p leg: neither of ${commits[c]} and ${commits[newest]} descends from the other"
      fi
    done
    newest_commit="${commits[newest]}"; newest_run="${runs[newest]}"
    for (( c = 0; c < ${#lines[@]}; c++ )); do
      (( c != newest )) || continue
      [[ "${states[c]}" == current ]] || continue
      if [[ "${states[newest]}" == regressed ]]; then
        _receipt_restate "$out" "${lines[c]}" superseded "replaced by the later run $newest_run, which regressed"
      else
        _receipt_restate "$out" "${lines[c]}" superseded "replaced by the later run $newest_run"
      fi
    done
    # A leg whose newest run regressed has no current receipt to test.
    [[ "${states[newest]}" == current ]] || continue
    # Does the newest still describe the tree?
    line="${lines[newest]}"
    want="$(awk -F'|' -v n="$line" 'NR==n{print $6}' "$_receipt_ledger_file")"; got="$(_receipt_digest "$p")"
    why=
    if [[ "$want" != "$got" ]]; then why='inputs'
    else
      d="$(mktemp -d)"; _receipt_tmpfiles+=("$d")
      _receipt_build_imports "$p" HEAD "$d"
      want="$(awk -F'|' -v n="$line" 'NR==n{print $11}' "$_receipt_ledger_file")"; got="$(_receipt_imports_field "$d" "$p")"
      if [[ "$want" != "$got" ]]; then why='imports'
      elif [[ "$p" == agda ]]; then
        want="$(awk -F'|' -v n="$line" 'NR==n{print $12}' "$_receipt_ledger_file")"; got="$(_receipt_trusted_base_field "$_receipt_trusted_base_file")"
        [[ "$want" == "$got" ]] || why='trusted base'
      fi
    fi
    if [[ -n "$why" ]]; then
      # A run handed to --emit-run or --record was just recorded on this tree:
      # one that does not describe it is refused, never written as stale.
      if [[ -n "$_receipt_new_rows" ]] && awk -F'|' -v p="$p" -v r="$newest_run" '$1==p && $2==r{f=1} END{exit !f}' "$_receipt_new_rows"; then
        receipt_die "the $p run being recorded does not describe this tree: the leg's $why differ from what the run recorded (a changed trusted base is earned again, §8.4)"
      fi
      _receipt_restate "$out" "$line" stale "the $p leg's $why changed after commit ${newest_commit:0:12}, so this run no longer describes the tree; no run of the new $why is recorded yet"
      _receipt_stale_notes+=("the $p receipt of run $newest_run is stale: the leg's $why changed after ${newest_commit:0:12}")
      # With no current leg the receipt still names the commit its newest
      # runs describe, which is on the default branch.
      [[ -n "$_receipt_fallback_commit" ]] || _receipt_fallback_commit="$newest_commit"
    fi
  done
  cp -- "$out" "$_receipt_ledger_file"
}
# Say which receipts were derived stale, on stderr: the receipt records it too.
_receipt_note_stale() {
  local n
  for n in "${_receipt_stale_notes[@]}"; do printf 'NOTE: %s\n' "$n" >&2; done
}
# Rewrite line $2 of ledger file $1 as state $3 with reason $4, keeping the
# row's other fields; the fields after the axioms are dropped, as for every
# receipt that is not current.
_receipt_restate() {
  local f="$1" n="$2" state="$3" reason="$4" t
  t="$(mktemp)"; _receipt_tmpfiles+=("$t")
  awk -F'|' -v OFS='|' -v n="$n" -v s="$state" -v r="$reason" \
    'NR==n{print $1,$2,$3,$4,$5,$6,$7,s,r,$10; next} {print}' "$f" > "$t"
  cp -- "$t" "$f"
}

# ── Run scope (receipt_run_scope) ─────────────────────────────────────────────
# $_receipt_scope_file holds "prover|run|claim ids" rows, checked; the claim
# being emitted is $_receipt_claim (empty outside a claim: every row counts).
_receipt_scope_file=
_receipt_claim=
_receipt_load_scope() {
  local row prover run ids id
  _receipt_scope_file="$(mktemp)"; _receipt_tmpfiles+=("$_receipt_scope_file" "$_receipt_scope_file.raw")
  : > "$_receipt_scope_file.raw"
  declare -F receipt_run_scope >/dev/null && _receipt_hook "$_receipt_scope_file.raw" receipt_run_scope
  grep . "$_receipt_scope_file.raw" > "$_receipt_scope_file" || true
  while IFS= read -r row; do
    [[ "$(tr -cd '|' <<< "$row" | wc -c)" == 2 ]] || receipt_die "a run scope needs 3 fields (prover | run | claim ids): $row"
    IFS='|' read -r prover run ids <<< "$row"
    _receipt_is_prover "$prover" || receipt_die "a run scope names an unknown prover: $row"
    awk -F'|' -v p="$prover" -v r="$run" '$1==p && $2==r{f=1} END{exit !f}' "$_receipt_ledger_file" \
      || receipt_die "a run scope names no run of the $prover ledger: $row"
    ! awk -F'|' -v p="$prover" -v r="$run" '$1==p && $2==r && $8=="current"{f=1} END{exit !f}' "$_receipt_ledger_file" \
      || receipt_die "a current run checks every claim with its leg, so it takes no run scope: $row"
    [[ -n "${ids// /}" ]] || receipt_die "a run scope names no claim: $row"
    for id in $ids; do
      awk -F'|' -v i="$id" '$1==i && $3=="theorem"{f=1} END{exit !f}' "$_receipt_claims_file" \
        || receipt_die "a run scope names $id, which is no theorem claim of receipt_claims: $row"
    done
  done < "$_receipt_scope_file"
  [[ "$(cut -d'|' -f1,2 "$_receipt_scope_file" | sort | uniq -d | wc -l)" == 0 ]] || receipt_die 'a run has two run scopes'
}
# Whether the run (prover, run, state) belongs under the claim being emitted.
_receipt_in_scope() {
  local prover="$1" run="$2" state="$3" ids
  [[ -n "$_receipt_claim" && "$state" != current && -s "$_receipt_scope_file" ]] || return 0
  ids="$(awk -F'|' -v p="$prover" -v r="$run" '$1==p && $2==r{print $3}' "$_receipt_scope_file")"
  [[ -z "$ids" || " $ids " == *" $_receipt_claim "* ]]
}
# PROOF-POLICY §2.1: the Agda invocation is at least the estate default.
_receipt_canonical() {
  local w
  # Split on any whitespace, as the reader does.
  w=" $(tr -s '[:space:]' ' ' <<< "$1") "
  [[ "$w" == *' --safe '* && "$w" == *' --without-K '* ]] && [[ "$w" == *' --cubical-compatible '* || "$w" == *' --cubical '* ]]
}
# A leg's witness counts only if every axiom its current receipt reports has
# disposition c (§8.4).
_receipt_axioms_ok() { local x; x=",$(_receipt_current_field "$1" 10),"; [[ "$x" != *':b,'* && "$x" != *':debt,'* ]]; }
# §8.3, as the reader derives it: a claim is foundation-diverse when one of its
# legs outside dependent type theory is kernel-checked (its token is proven or
# proven-with-postulates, which here means RECONCILED), every axiom its current
# run reported is of disposition (c), and it has a current receipt.
_receipt_diverse_of() {
  local xp xroute xstate
  while IFS='|' read -r _ xp xroute xstate _; do
    if [[ "$xroute" == transported || "$xroute" == re-proved ]] && [[ "$xstate" == RECONCILED ]] \
       && _receipt_has_current "$xp" && _receipt_axioms_ok "$xp"; then printf '#t'; return 0; fi
  done < <(awk -F'|' -v i="$1" '$1==i' "$_receipt_extra_legs_file")
  printf '#f'
}
# §8.5.2: the leg's current receipt describes the :source-commit when its
# commit is that commit, or an echo chain leads there and every link's digest
# for this prover equals the receipt's digest.
_receipt_describes_source() {
  local prover="$1" c d img
  c="$(_receipt_current_field "$prover" 3)"; d="$(_receipt_current_field "$prover" 6)"
  while :; do
    [[ "$c" != "$_receipt_source_commit" ]] || return 0
    img="$(awk -F'|' -v c="$c" '$1==c{print $2}' "$_receipt_echo_file")"
    [[ -n "$img" ]] || return 1
    [[ "$(awk -F'|' -v c="$c" -v p="$prover" '$1==c && $2==p{print $3}' "$_receipt_echo_digest_file")" == "$d" ]] || return 1
    c="$img"
  done
}
# §8.2 (owner ruling 2026-11-16): a witness counts toward PWG-1 only when its
# current run recorded the digest-pinned image its checker ran in (field 13).
_receipt_isolated() { [[ -n "$(_receipt_current_field "$1" 13)" ]]; }
_receipt_pwg_of() {
  local token="$1" coq_route="$2" coq_state="$3" lean_route="$4" lean_state="$5" n=0 p route state
  [[ "$token" == proven || "$token" == proven-with-postulates ]] || { printf 'ungraded'; return; }
  _receipt_has_current agda && _receipt_axioms_ok agda && _receipt_canonical "$(_receipt_current_field agda 5)" || { printf 'ungraded'; return; }
  for p in rocq lean; do
    if [[ $p == rocq ]]; then route="$coq_route" state="$coq_state"; else route="$lean_route" state="$lean_state"; fi
    [[ "$route" == transported || "$route" == re-proved ]] && [[ "$state" == RECONCILED ]] && _receipt_has_current "$p" && _receipt_axioms_ok "$p" && n=$((n + 1))
  done
  case "$n" in
    0) printf 'PWG-3' ;;
    1) printf 'PWG-2i' ;;
    2) if _receipt_describes_source agda && _receipt_describes_source rocq && _receipt_describes_source lean \
            && _receipt_isolated agda && _receipt_isolated rocq && _receipt_isolated lean; then printf 'PWG-1'; else printf 'PWG-2ii'; fi ;;
    *) receipt_die "unexpected recheck count: $n" ;;
  esac
}
# A leg's §5 token.  The token and the §2.2 state are separate facts (§2.2: a
# leg can be PROVEN and still BRIDGE-PENDING): a re-proof the kernel accepted
# is proven whether or not its statement has been reconciled with the Agda
# one, or proven-with-postulates when its current run reported an axiom (§5:
# a kernel proof resting on named necessary axioms).  COQ-CHECKED and
# LEAN-CHECKED say the kernel accepted it, as BRIDGE-PENDING and RECONCILED
# do; any other state is open.  Only a RECONCILED leg counts toward a grade.
_receipt_kernel_checked() { [[ "$1" == RECONCILED || "$1" == COQ-CHECKED || "$1" == LEAN-CHECKED || "$1" == BRIDGE-PENDING ]]; }
_receipt_leg_token() {
  local state="$1" prover="$2"
  if ! _receipt_kernel_checked "$state"; then printf 'open'
  elif _receipt_has_current "$prover" && [[ -n "$(_receipt_current_field "$prover" 10)" ]]; then printf 'proven-with-postulates'
  else printf 'proven'; fi
}
# A leg's receipts, then $2 (the closing parentheses) on the last line.  The
# receipts are written to a file first, so a refusal while writing them stops
# the gate whatever the caller's shell options.
_receipt_emit_receipts_closed() {
  local prover="$1" close="$2" f
  f="$(mktemp)"; _receipt_tmpfiles+=("$f")
  _receipt_emit_receipts "$prover" > "$f" || receipt_die "cannot write the $prover receipts"
  sed "\$ s/\$/$close/" "$f"
}

# ── Emit ──────────────────────────────────────────────────────────────────────
_receipt_emit_axioms() {
  local list="$1" x
  local -a a
  if [[ -z "$list" ]]; then printf '               (axioms))\n'; return; fi
  printf '               (axioms'
  IFS=',' read -ra a <<< "$list"
  for x in "${a[@]}"; do printf '\n                 (axiom :name "%s" :disposition %s)' "${x%:*}" "${x##*:}"; done
  printf '))\n'
}
# One (file …) per line of a reference --manifest file, "<sha256>  <path>".
# The path is taken whole, with any leading or trailing space kept, and a
# path that a deed string cannot hold unescaped is refused.
_receipt_emit_files() {
  local file="$1" indent="$2" line sha path
  while IFS= read -r line; do
    sha="${line:0:64}"; path="${line:66}"
    [[ "$sha" =~ ^[0-9a-f]{64}$ && "${line:64:2}" == '  ' && -n "$path" ]] || receipt_die "a manifest line is not '<sha256>  <path>': $line"
    [[ "$path" != *'"'* ]] || receipt_die "the input path $path holds a double quote, which a deed string cannot hold here"
    printf '\n%s(file :path "%s" :sha256 "%s")' "$indent" "$path" "$sha"
  done < "$file"
}
# §8.5.1: the inputs manifest of a leg's current receipt, one (file ...) per
# line of the reference script's --manifest output at the receipt's commit.
# The reader recomputes :inputs-sha256 from it.
_receipt_emit_manifest() {
  local prover="$1" sha path
  printf '               (inputs-manifest'
  _receipt_emit_files "$_receipt_manifest_dir/$prover" '                 '
  printf ')\n'
}
# §8.5.1, Imported repositories: one (import …) per repository the current
# receipt's run read, each with its manifest at its pinned commit.
_receipt_emit_imports() {
  local prover="$1" repo commit dig f sha path
  [[ -f "$_receipt_manifest_dir/$prover.imports" ]] || return 0
  while IFS='|' read -r repo commit dig f; do
    printf '               (import :repository "%s" :commit "%s" :inputs-sha256 "%s"' "$repo" "$commit" "$dig"
    _receipt_emit_files "$f" '                 '
    printf ')\n'
  done < "$_receipt_manifest_dir/$prover.imports"
}
# RECEIPT_KEEP_LINEAGE_DETAIL: the inputs manifest of a receipt that is not
# current, rebuilt at the row's commit over the input set of the working tree.
# Prints the path of the manifest file and returns 0 only when it hashes to the
# row's recorded digest, which is what the reader checks; otherwise returns 1
# and says once, on stderr, why the receipt is written without it.
_receipt_lineage_manifest() {
  local p="$1" run="$2" commit="$3" dig="$4" f a why=
  local -a paths
  f="$_receipt_manifest_dir/lineage.$(printf '%s|%s|%s' "$p" "$run" "$commit" | sha256sum | cut -c1-16)"
  if [[ ! -e "$f" && ! -e "$f.no" ]]; then
    if ! git cat-file -e "$commit^{commit}" 2>/dev/null; then why="commit ${commit:0:12} is not here"
    else
      mapfile -t paths < <(_receipt_inputs "$p")
      if (( ${#paths[@]} )) && bash "$(_receipt_digest_script)" --manifest "$commit" "${paths[@]}" > "$f.try" 2>/dev/null; then
        a="$(sha256sum < "$f.try" | cut -d' ' -f1)"
        if [[ "$a" == "$dig" ]]; then mv -- "$f.try" "$f"
        else why="the input set has moved since, so the leg's inputs at that commit do not hash to the recorded digest"; fi
      else why="the leg's current inputs cannot be listed at that commit"; fi
    fi
    if [[ ! -e "$f" ]]; then
      rm -f -- "$f.try"; : > "$f.no"
      printf 'NOTE: the %s receipt of run %s is written without its inputs manifest: %s\n' "$p" "$run" "$why" >&2
    fi
  fi
  [[ -e "$f" ]] || return 1
  printf '%s\n' "$f"
}
_receipt_emit_receipts() {
  local prover="$1" row p run commit checker inv dig said state reason axioms imports tb img want mf
  # Current first, then the lineage in ledger order.
  for want in current other; do
    while IFS= read -r row; do
      IFS='|' read -r p run commit checker inv dig said state reason axioms imports tb img <<< "$row"
      [[ "$p" == "$prover" ]] || continue
      if [[ $want == current ]]; then [[ $state == current ]] || continue; else [[ $state != current ]] || continue; fi
      _receipt_in_scope "$p" "$run" "$state" || continue
      printf '      ; the run reported: %s\n' "$said"
      printf '      (receipt :run "%s"\n' "$run"
      printf '               :commit "%s"\n' "$commit"
      printf '               :checker "%s"\n' "$checker"
      printf '               :invocation "%s"\n' "$inv"
      if [[ $state == current ]]; then
        [[ -z "$img" ]] || printf '               :image "%s"\n' "$img"
        printf '               :inputs-sha256 "%s"\n' "$dig"
        printf '               :state current\n'
        _receipt_emit_manifest "$prover"
        _receipt_emit_imports "$prover"
        _receipt_emit_axioms "$axioms"
      elif [[ "${RECEIPT_KEEP_LINEAGE_DETAIL:-0}" == 1 ]]; then
        # What the run read stays on the receipt: the digest and axioms of its
        # ledger row, and the manifest when it can be shown to hash to it.
        printf '               :inputs-sha256 "%s"\n' "$dig"
        printf '               :state %s\n               :reason "%s"\n' "$state" "$reason"
        if mf="$(_receipt_lineage_manifest "$p" "$run" "$commit" "$dig")"; then
          printf '               (inputs-manifest'
          _receipt_emit_files "$mf" '                 '
          printf ')\n'
        fi
        _receipt_emit_axioms "$axioms"
      else
        printf '               :state %s\n               :reason "%s")\n' "$state" "$reason"
      fi
    done < "$_receipt_ledger_file"
  done
}
_receipt_emit_echoes() {
  local src img wit ref p d
  # An echo carries a witness for each current leg whose chain passes through
  # it; one that no chain uses would carry none, which the reader refuses, so
  # it is left out.
  while IFS='|' read -r src img wit ref; do
    grep -q "^$src|" "$_receipt_echo_digest_file" || continue
    printf '  ; %s was rewritten into %s on %s; %s keeps it.\n' "${src:0:12}" "${img:0:12}" "$RECEIPT_DEFAULT_BRANCH" "$ref"
    printf '  (echo :source "%s" :image "%s" :witness %s' "$src" "$img" "$wit"
    for p in "${_receipt_provers[@]}"; do
      d="$(awk -F'|' -v c="$src" -v p="$p" '$1==c && $2==p{print $3}' "$_receipt_echo_digest_file")"
      [[ -z "$d" ]] || printf '\n    (inputs :prover %s :sha256 "%s")' "$p" "$d"
    done
    printf ')\n'
  done < "$_receipt_echo_file"
}
# Print one recheck leg, then $5 (the closing parentheses).  A waived or
# unavailable leg carries only its reason (§8.5.1); a transported or
# re-proved leg carries its token, its §2.2 state and its receipts.
_receipt_emit_leg() {
  local prover="$1" route="$2" state="$3" reason="$4" close="$5"
  case "$route" in
    waived|unavailable)
      [[ -n "$reason" && "$reason" != *'"'* ]] || receipt_die "a $route $prover leg needs a reason without a quote"
      printf '    (leg :prover %s :route %s :reason "%s"%s\n' "$prover" "$route" "$reason" "$close" ;;
    transported|re-proved)
      # COQ-CHECKED is a Rocq leg's state and LEAN-CHECKED a Lean leg's.
      [[ "$state" != COQ-CHECKED || "$prover" == rocq ]] || receipt_die "COQ-CHECKED is the state of a Rocq leg, not of the $prover leg"
      [[ "$state" != LEAN-CHECKED || "$prover" == lean ]] || receipt_die "LEAN-CHECKED is the state of a Lean leg, not of the $prover leg"
      printf '    (leg :prover %s :route %s :token %s :state %s' "$prover" "$route" "$(_receipt_leg_token "$state" "$prover")" "$state"
      if _receipt_has_any "$prover"; then printf '\n'; _receipt_emit_receipts_closed "$prover" "$close"; else printf '%s\n' "$close"; fi ;;
    *) receipt_die "unknown route for the $prover leg: $route" ;;
  esac
}
_receipt_emit() {
  local id token kind coq coq_state lean lean_state coq_reason lean_reason m name binding n k xp xroute xstate xreason
  cat "$_receipt_header_file"
  printf '(praxis-deed\n'
  printf '  :schema-version "1.0.0"\n'
  printf '  :canonical-name "%s"\n' "$RECEIPT_CANONICAL_NAME"
  [[ -z "${RECEIPT_BEHOLDING_CHORA:-}" ]] || printf '  :beholding-chora %s\n' "$RECEIPT_BEHOLDING_CHORA"
  printf '  :profile proof-receipt\n'
  printf '  :repository "%s"\n' "$RECEIPT_REPOSITORY"
  printf '  :source-commit "%s"\n' "$_receipt_source_commit"
  # §8.5.1: the clause lists each prover postulate, and is left out when the
  # cone has none (the reader refuses an empty one).
  if grep -q . "$_receipt_trusted_base_file"; then
    printf '  (trusted-base'
    while IFS='|' read -r m name binding; do
      printf '\n    (primitive :prover agda :module "%s" :name "%s" :binding "%s")' "$m" "$name" "$binding"
    done < "$_receipt_trusted_base_file"
    printf ')\n'
  fi
  _receipt_emit_echoes
  while IFS='|' read -r id token kind coq coq_state lean lean_state coq_reason lean_reason; do
    [[ "$kind" == theorem ]] || continue
    # §5: the typed Agda token must agree with what the Agda run reported.
    if [[ "$token" == proven ]] && _receipt_has_current agda && [[ -n "$(_receipt_current_field agda 10)" ]]; then
      receipt_die "claim $id: the current Agda run reported axioms, so its token is proven-with-postulates, not proven"
    fi
    if [[ "$token" == proven-with-postulates ]] && _receipt_has_current agda && [[ -z "$(_receipt_current_field agda 10)" ]]; then
      receipt_die "claim $id: its token proven-with-postulates names axioms, but the current Agda run reported none"
    fi
    _receipt_claim="$id"
    printf '  (claim :id "%s" :pwg %s :foundation-diverse %s\n' "$id" "$(_receipt_pwg_of "$token" "$coq" "$coq_state" "$lean" "$lean_state")" "$(_receipt_diverse_of "$id")"
    # A claim with no Agda proof yet (its token is not proven or
    # proven-with-postulates) is AGDA-PENDING and carries no Agda receipt: the
    # Agda runs checked the other claims, not this one.
    if [[ "$token" == proven || "$token" == proven-with-postulates ]]; then
      printf '    (leg :prover agda :route source :token %s :state AGDA-VERIFIED' "$token"
      if _receipt_has_any agda; then printf '\n'; _receipt_emit_receipts_closed agda ')'; else printf ')\n'; fi
    else
      printf '    (leg :prover agda :route source :token %s :state AGDA-PENDING)\n' "$token"
    fi
    _receipt_emit_leg rocq "$coq" "$coq_state" "$coq_reason" ')'
    # The claim's legs outside dependent type theory follow; the last leg
    # printed closes the claim.
    awk -F'|' -v i="$id" '$1==i' "$_receipt_extra_legs_file" | LC_ALL=C sort -t'|' -k2,2 > "$_receipt_extra_legs_file.claim"
    if [[ -s "$_receipt_extra_legs_file.claim" ]]; then
      _receipt_emit_leg lean "$lean" "$lean_state" "$lean_reason" ')'
      n="$(wc -l < "$_receipt_extra_legs_file.claim")"; k=0
      while IFS='|' read -r _ xp xroute xstate xreason; do
        k=$((k + 1))
        if (( k < n )); then _receipt_emit_leg "$xp" "$xroute" "$xstate" "$xreason" ')'; else _receipt_emit_leg "$xp" "$xroute" "$xstate" "$xreason" '))'; fi
      done < "$_receipt_extra_legs_file.claim"
    else
      _receipt_emit_leg lean "$lean" "$lean_state" "$lean_reason" '))'
    fi
    _receipt_claim=
  done < "$_receipt_claims_file"
  printf ')\n'
}

# Run a hook into a file.  A hook exits 0, also when it has nothing to print;
# any other exit is a refusal, reported by name (a hook's own receipt_die
# message is on stderr above it), never a silent stop.
_receipt_hook() {
  local out="$1"; shift
  "$@" > "$out" || receipt_die "the hook $1 of $RECEIPT_SCRIPT failed (exit $?)"
}

# ── Cross-checks of the typed claim list ──────────────────────────────────────
_receipt_check_claim_ids() {
  local decl doc f
  f="$(mktemp)"; _receipt_tmpfiles+=("$f")
  decl="$(cut -d"|" -f1 "$_receipt_claims_file" | LC_ALL=C sort)"
  _receipt_hook "$f" receipt_status_ids
  doc="$(LC_ALL=C sort -u "$f")"
  [[ -n "$doc" ]] || receipt_die 'no claim ids found in the proof-status file; its table layout changed'
  if [[ "$decl" != "$doc" ]]; then
    diff <(printf '%s\n' "$doc") <(printf '%s\n' "$decl") \
      | grep -E '^[<>] .' | sed "s|^< |  only in the proof-status file: |; s|^> |  only in $RECEIPT_SCRIPT: |" >&2 || true
    receipt_die 'claim ids differ between this receipt and the proof-status file'
  fi
}
_receipt_check_leg_records() {
  local counted recorded f
  f="$(mktemp)"; _receipt_tmpfiles+=("$f")
  counted="$(awk -F'|' '$5=="RECONCILED"||$7=="RECONCILED"{print $1}' "$_receipt_claims_file" | LC_ALL=C sort)"
  _receipt_hook "$f" receipt_recorded_legs
  recorded="$(LC_ALL=C sort -u "$f")"
  if [[ "$counted" != "$recorded" ]]; then
    diff <(printf '%s\n' "$recorded") <(printf '%s\n' "$counted") \
      | grep -E '^[<>] .' | sed "s|^< |  only in the legs record: |; s|^> |  only in $RECEIPT_SCRIPT: |" >&2 || true
    receipt_die 'claims with a RECONCILED leg differ from the legs record'
  fi
}

# Prepare the ledger, the echoes, the manifests and the :source-commit.  The
# current receipts must name one commit; the :source-commit is the end of the
# echo chain from it (§8.5.2), or that commit if it has no echo.  With no
# current receipt it is $_receipt_fallback_commit, which --write takes from
# --commit and --check from the receipt (nothing is graded then).
# Each echo link's witness digests are computed at its source and at its
# image with the reference script, and must be equal (§8.5.3, check 3).
_receipt_prepare() {
  _receipt_ledger_file="$(mktemp)"; _receipt_echo_file="$(mktemp)"; _receipt_echo_digest_file="$(mktemp)"
  _receipt_manifest_dir="$(mktemp -d)"
  _receipt_tmpfiles+=("$_receipt_ledger_file" "$_receipt_echo_file" "$_receipt_echo_digest_file" "$_receipt_manifest_dir")
  [[ -z "${RECEIPT_LEDGER:-}" ]] || _receipt_check_append_only
  _receipt_ledger > "$_receipt_ledger_file"
  _receipt_trusted_base_file="$(mktemp)"; _receipt_tmpfiles+=("$_receipt_trusted_base_file")
  _receipt_hook "$_receipt_trusted_base_file" receipt_trusted_base
  grep . "$_receipt_echoes_file" > "$_receipt_echo_file" || true
  local row p commits src img wit ref a b c n repo commit dir path
  local -a paths
  while IFS= read -r row; do _receipt_check_row "$row"; done < "$_receipt_ledger_file"
  # The states git can tell are derived from the rows as typed, before
  # anything reads a row's state; the run scopes are read after, since a
  # derived superseded run may carry one.
  _receipt_derive_states
  _receipt_load_scope
  while IFS= read -r row; do _receipt_check_echo "$row"; done < "$_receipt_echo_file"
  [[ "$(cut -d'|' -f1 "$_receipt_echo_file" | sort | uniq -d | wc -l)" == 0 ]] || receipt_die 'an echo source has two images'
  # §8.5.2: no echo chain may cycle, whether or not the current receipts use it.
  local start
  while IFS='|' read -r start _; do
    local at="$start"
    local -A visited=(["$start"]=1)
    while at="$(awk -F'|' -v c="$at" '$1==c{print $2}' "$_receipt_echo_file")" && [[ -n "$at" ]]; do
      [[ -z "${visited[$at]:-}" ]] || receipt_die "the echoes form a cycle through $start"
      visited[$at]=1
    done
  done < "$_receipt_echo_file"
  # Current legs may sit at different commits (§8.5.2): each is followed along
  # its own echo chain.  The :source-commit is reached from the Agda leg's
  # commit, or from the first current leg's when Agda has none.
  commits=
  for p in "${_receipt_provers[@]}"; do
    [[ "$(awk -F'|' -v p="$p" '$1==p && $8=="current"' "$_receipt_ledger_file" | wc -l)" -le 1 ]] || receipt_die "the $p leg has more than one current row"
    _receipt_has_current "$p" || continue
    c="$(_receipt_current_field "$p" 3)"
    [[ -n "$commits" ]] || commits="$c"
    # The leg's chain: its commit, then each image in turn (no cycle, above).
    while [[ -n "$c" ]]; do
      printf '%s\n' "$c"
      c="$(awk -F'|' -v c="$c" '$1==c{print $2}' "$_receipt_echo_file")"
    done > "$_receipt_manifest_dir/$p.chain"
  done
  while IFS='|' read -r src img wit ref; do
    # An echo that no current leg's chain passes through is not used, and is
    # neither fetched nor witnessed; the receipt leaves it out.
    grep -qxF "$src" "$_receipt_manifest_dir"/*.chain 2>/dev/null || continue
    # An image that is itself an echo source (a chain A -> B -> C) is kept by
    # its own forge reference; only the end of a chain is on the default branch.
    _receipt_ensure_commit "$src" "$ref"
    _receipt_ensure_commit "$img" "$(_receipt_echo_ref "$img" | grep . || printf 'refs/heads/%s' "$RECEIPT_DEFAULT_BRANCH")"
    for p in "${_receipt_provers[@]}"; do
      # Only a current leg whose chain passes through this link has a manifest
      # for the witness to match (§8.5.3), so only those legs carry one.
      [[ -f "$_receipt_manifest_dir/$p.chain" ]] && grep -qxF "$src" "$_receipt_manifest_dir/$p.chain" || continue
      a="$(_receipt_ref_digest "$src" "$p")" || receipt_die "cannot compute the $p digest at $src"
      b="$(_receipt_ref_digest "$img" "$p")" || receipt_die "cannot compute the $p digest at $img"
      [[ "$a" == "$b" ]] || receipt_die "echo $src -> $img: the $p inputs differ ($a at the source, $b at the image)"
      printf '%s|%s|%s\n' "$src" "$p" "$a" >> "$_receipt_echo_digest_file"
    done
  done < "$_receipt_echo_file"
  # The inputs manifest of each current receipt, at its commit (§8.5.1).  Its
  # SHA-256 is the digest the ledger records, or the row is wrong.  Then the
  # manifest of each repository the run imported, at its pinned commit.
  for p in "${_receipt_provers[@]}"; do
    _receipt_has_current "$p" || continue
    c="$(_receipt_current_field "$p" 3)"
    _receipt_ensure_commit "$c" "$(_receipt_echo_ref "$c")"
    mapfile -t paths < <(_receipt_inputs "$p")
    (( ${#paths[@]} )) || receipt_die "the $p leg has no inputs"
    bash "$(_receipt_digest_script)" --manifest "$c" "${paths[@]}" > "$_receipt_manifest_dir/$p" || receipt_die "cannot list the $p inputs at $c"
    a="$(sha256sum < "$_receipt_manifest_dir/$p" | cut -d' ' -f1)"
    [[ "$a" == "$(_receipt_current_field "$p" 6)" ]] \
      || receipt_die "the $p receipt records inputs $(_receipt_current_field "$p" 6), but the manifest at $c gives $a"
    _receipt_build_imports "$p" "$c" "$_receipt_manifest_dir"
    a="$(_receipt_imports_field "$_receipt_manifest_dir" "$p")"
    [[ "$a" == "$(_receipt_current_field "$p" 11)" ]] \
      || receipt_die "the $p run recorded imports '$(_receipt_current_field "$p" 11)', but the hook now derives '$a' at $c: record the run again"
  done
  # §8.4: a change to the trusted base means the receipt is earned again.
  if _receipt_has_current agda; then
    a="$(_receipt_trusted_base_field "$_receipt_trusted_base_file")"
    [[ "$a" == "$(_receipt_current_field agda 12)" ]] \
      || receipt_die "the agda run recorded trusted base '$(_receipt_current_field agda 12)', but receipt_trusted_base now gives '$a': a changed trusted base is earned again (§8.4), so record the run again"
  fi
  # With no current receipt nothing is graded, but the :source-commit is still
  # checked on the default branch (§8.5.3).  HEAD is not a safe default: on a
  # pull request it is a commit that a squash merge leaves off the default
  # branch, so the receipt would fail its git checks once merged.  The caller
  # names the commit instead.
  [[ -n "$commits" || -n "$_receipt_fallback_commit" ]] \
    || receipt_die "no leg has a current run, so nothing names the :source-commit: pass --commit with a commit on $RECEIPT_DEFAULT_BRANCH"
  _receipt_source_commit="${commits:-$_receipt_fallback_commit}"
  _receipt_prepare_tail
}
# The (import …) manifests of leg $1 at home commit $2, built in $3: one
# $1.import.N manifest per repository, $1.imports lines (repo|commit|digest|
# manifest), and the clone of each repository in clones.
_receipt_build_imports() {
  local p="$1" c="$2" d="$3" row n repo commit dir
  local -a paths
  _receipt_hook "$d/$p.raw" _receipt_imports "$p" "$c"
  grep . "$d/$p.raw" > "$d/$p.lines" || true
    while IFS= read -r row; do _receipt_check_import "$row"; done < "$d/$p.lines"
    [[ "$(cut -d'|' -f1 "$d/$p.lines" | LC_ALL=C sort -u | wc -l)" == "$(cut -d'|' -f1 "$d/$p.lines" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u | wc -l)" ]] \
      || receipt_die "the $p leg names one imported repository in two spellings; GitHub names are case-insensitive, so spell each one way"
    n=0
    while IFS='|' read -r repo commit dir; do
      [[ -n "$repo" ]] || continue
      [[ "$(awk -F'|' -v r="$repo" 'tolower($1)==tolower(r){print $2"|"$3}' "$d/$p.lines" | sort -u | wc -l)" == 1 ]] \
        || receipt_die "the $p leg imports $repo at more than one commit or clone (one pin per repository)"
      _receipt_ensure_import "$repo" "$commit" "$dir"
      mapfile -t paths < <(awk -F'|' -v r="$repo" '$1==r{print $4}' "$d/$p.lines" | LC_ALL=C sort -u)
      n=$((n + 1))
      bash "$(_receipt_digest_script)" -C "$dir" --manifest "$commit" "${paths[@]}" > "$d/$p.import.$n" \
        || receipt_die "cannot list the $p inputs of $repo at $commit"
      printf '%s|%s|%s|%s\n' "$repo" "$commit" "$(sha256sum < "$d/$p.import.$n" | cut -d' ' -f1)" "$d/$p.import.$n" \
        >> "$d/$p.imports"
      # The checker takes one clone per repository, so every leg that imports
      # a repository must name the same clone.
      if [[ -f "$d/clones" ]] && awk -F= -v r="${repo,,}" -v d="$dir" 'tolower($1)==r && $2!=d{f=1} END{exit !f}' "$d/clones"; then
        receipt_die "two legs import $repo from different clones; name one clone for it"
      fi
      printf '%s=%s\n' "$repo" "$dir" >> "$d/clones"
    done < <(cut -d'|' -f1-3 "$d/$p.lines" | LC_ALL=C sort -u -t'|' -k1,1)
}
# The run-row field that binds a leg's imports: OWNER/REPO@COMMIT=SHA256 per
# imported repository, sorted, comma-separated; empty when it imports none.
_receipt_imports_field() {
  local d="$1" p="$2"
  [[ -f "$d/$p.imports" ]] || return 0
  awk -F'|' '{print $1 "@" $2 "=" $3}' "$d/$p.imports" | LC_ALL=C sort | paste -sd, -
}
# At --run-row, each imported file in its clone's working tree must be the
# file at the pinned commit: no uncommitted change, no other checkout, and no
# symbolic link (whose recorded blob is its target's name, not the bytes read).
_receipt_check_import_worktree() {
  local d="$1" p="$2" repo commit dir path
  [[ -f "$d/$p.lines" ]] || return 0
  while IFS='|' read -r repo commit dir path; do
    [[ -n "$repo" ]] || continue
    [[ ! -L "$dir/$path" ]] || receipt_die "the $p leg imports $repo:$path, which is a symbolic link; list the file it points to"
    git -C "$dir" diff --quiet "$commit" -- "$path" \
      || receipt_die "the $p leg read $repo:$path from $dir, which differs from $repo at $commit (an uncommitted change or another checkout): run the prover on the pinned files"
  done < "$d/$p.lines"
}
# The run-row field that binds the trusted base: the sha256 of what
# receipt_trusted_base printed (file $1); empty when it printed nothing.
_receipt_trusted_base_field() {
  grep -q . "$1" || return 0
  sha256sum < "$1" | cut -d' ' -f1
}
_receipt_prepare_tail() {
  local steps=0 next
  while next="$(awk -F'|' -v c="$_receipt_source_commit" '$1==c{print $2}' "$_receipt_echo_file")" && [[ -n "$next" ]]; do
    _receipt_source_commit="$next"; steps=$((steps + 1))
    # Every chain was checked for a cycle above; this only guards the walk.
    (( steps <= $(wc -l < "$_receipt_echo_file") )) || receipt_die 'the echoes form a cycle'
  done
  [[ "$_receipt_source_commit" =~ ^[0-9a-f]{40}$ ]] || receipt_die "no 40-hex source commit (got '${_receipt_source_commit}')"
}

# §8.5.3: the git checks, by the shared checker, so the home gate and every
# consumer check in the same way.
_receipt_check_git_facts() {
  local file="$1" base clone rc=0
  local -a imports=()
  base="refs/remotes/origin/$RECEIPT_DEFAULT_BRANCH"
  git rev-parse -q --verify "$base^{commit}" >/dev/null || base="refs/heads/$RECEIPT_DEFAULT_BRANCH"
  # Ancestry is checked against the default branch only, never against
  # whatever HEAD is: a clone that has neither ref cannot run the checks.
  git rev-parse -q --verify "$base^{commit}" >/dev/null || {
    printf 'ERROR: cannot run the git checks of §8.5.3: this clone has neither origin/%s nor %s; fetch the default branch\n' \
      "$RECEIPT_DEFAULT_BRANCH" "$RECEIPT_DEFAULT_BRANCH" >&2
    exit 2
  }
  if [[ -f "$_receipt_manifest_dir/clones" ]]; then
    while IFS= read -r clone; do imports+=(--import "$clone"); done < <(sort -u "$_receipt_manifest_dir/clones")
  fi
  bash "$(_receipt_checker)" --branch "$base" "${imports[@]}" "$file" . || rc=$?
  # Exit 2 is the checker's "cannot run" (a tool missing, a shallow clone):
  # the checks did not happen, which is not the same as a receipt that fails
  # them, so the gate exits 2 as well and a caller can tell the two apart.
  if (( rc == 2 )); then printf 'ERROR: the git checks of PROOF-POLICY §8.5.3 could not run for %s\n' "$file" >&2; exit 2; fi
  (( rc == 0 )) || receipt_die "the git checks of PROOF-POLICY §8.5.3 failed for $file"
  printf 'PASS: git checks of §8.5.3 (shared checker, standards %s, --branch %s)\n' "${RECEIPT_STANDARDS_COMMIT:0:12}" "$base"
}

# Each current receipt must still describe the tree: its inputs digest is the
# digest of the inputs now.  Otherwise the grade cannot be carried forward
# (§8.4, regression drops the grade).  A row that no longer describes the tree
# was derived stale before this runs (Derived states), so the two digest
# comparisons here are a second look at what is still current, and they stop
# the gate if the derivation ever lets one through.
#
# The imported files count too (§8.5.1, Imported repositories).  The hook is
# asked again at HEAD, so a repin moves the binding even when the pin is not
# among the home inputs; and the files in each clone must be the files at the
# pin, so a sibling checkout moved or edited since the run is not taken for
# what the run read.
_receipt_check_currency() {
  local p want got d run
  for p in "${_receipt_provers[@]}"; do
    _receipt_has_current "$p" || continue
    run="$(_receipt_current_field "$p" 2)"
    want="$(_receipt_current_field "$p" 6)"; got="$(_receipt_digest "$p")"
    [[ "$want" == "$got" ]] || receipt_die "the $p inputs changed since run $run (recorded $want, now $got), yet the row was not derived stale: the generator is at fault, so stop"
    d="$(mktemp -d)"; _receipt_tmpfiles+=("$d")
    _receipt_build_imports "$p" HEAD "$d"
    want="$(_receipt_current_field "$p" 11)"; got="$(_receipt_imports_field "$d" "$p")"
    [[ "$want" == "$got" ]] || receipt_die "the $p imports changed since run $run (recorded '$want', now '$got' at HEAD), yet the row was not derived stale: the generator is at fault, so stop"
    _receipt_check_import_worktree "$d" "$p"
  done
}

# Run the pinned reader on $1 and print each claim's derived grade.  Then the
# negative control: the same receipt with one claim's :pwg changed must be
# refused, so a reader that stopped deriving grades cannot pass this gate.
_receipt_read_with_reader() {
  local file="$1" json first wrong ctl err
  command -v bun >/dev/null || receipt_die 'bun is needed to run the pinned reader'
  json="$(bun "$(_receipt_reader)" --proof-receipt-json "$file")" || receipt_die "the pinned reader refused $file"
  printf 'PASS: the pinned reader (standards %s) accepts %s\n' "${RECEIPT_STANDARDS_COMMIT:0:12}" "$file"
  grep -oE '"source_commit":"[0-9a-f]{40}"' <<< "$json" | sed 's/"source_commit":"\(.*\)"/  source-commit \1/'
  grep -oE '"id":"[^"]*","pwg":"[^"]*","foundation_diverse":(true|false)' <<< "$json" \
    | sed -E 's/"id":"([^"]*)","pwg":"([^"]*)","foundation_diverse":(.*)/  \1  \2  foundation-diverse \3/'
  # The first (claim …) line, never a comment that mentions a grade.
  first="$(grep -m1 -E '^  \(claim :id "[^"]*" :pwg ' "$file" | grep -oE ':pwg [A-Za-z0-9-]+' | cut -d' ' -f2)"
  [[ -n "$first" ]] || receipt_die "negative control: $file has no claim to alter"
  case "$first" in PWG-1) wrong=PWG-2ii ;; *) wrong=PWG-1 ;; esac
  ctl="$(mktemp -d)"; _receipt_tmpfiles+=("$ctl")
  awk -v w="$wrong" '!done && /^  \(claim :id "[^"]*" :pwg /{sub(/:pwg [A-Za-z0-9-]+/, ":pwg " w); done=1} {print}' "$file" > "$ctl/control_praxis.deed"
  if err="$(bun "$(_receipt_reader)" --proof-receipt-json "$ctl/control_praxis.deed" 2>&1)"; then
    receipt_die "negative control: the reader accepted a receipt whose first claim records :pwg $wrong"
  fi
  grep -q 'records :pwg' <<< "$err" || { printf '%s\n' "$err" >&2; receipt_die 'negative control: refused for another reason than the grade'; }
  printf 'PASS: negative control (the first claim recorded as :pwg %s is refused: its legs support %s)\n' "$wrong" "$first"
}

_receipt_tmpfiles=()
_receipt_cleanup() { (( ${#_receipt_tmpfiles[@]} )) && rm -rf "${_receipt_tmpfiles[@]}"; return 0; }

# The gate runs in a subshell under its own strictness and its own EXIT trap.
# A subshell starts without the caller's trap handlers, so the home script's
# EXIT trap is neither read nor replaced: it runs, as written, when the home
# script exits.  The subshell's status is returned; a refusal is a non-zero
# status.  The caller's errexit is suspended only around the subshell, so
# that set -e inside it is not ignored, and then restored.  Call it as a plain
# command: bash ignores set -e inside a command that if, && or || tests.
receipt_main() {
  local rc had_e=
  [[ $- != *e* ]] || had_e=1
  set +e
  ( _receipt_tmpfiles=(); trap _receipt_cleanup EXIT; set -euo pipefail; _receipt_main "$@" )
  rc=$?
  [[ -z "$had_e" ]] || set -e
  return "$rc"
}

_receipt_main() {
  local v
  for v in RECEIPT_STD RECEIPT_STANDARDS_COMMIT RECEIPT_OUT RECEIPT_REPOSITORY RECEIPT_DEFAULT_BRANCH RECEIPT_CANONICAL_NAME RECEIPT_SCRIPT; do
    [[ -n "${!v:-}" ]] || receipt_die "the home script must set $v"
  done
  if [[ -n "${RECEIPT_BEHOLDING_CHORA:-}" ]]; then
    [[ "$RECEIPT_BEHOLDING_CHORA" =~ ^#(u8|uuid)\"[^\"\\[:cntrl:]]+\"$ ]] \
      || receipt_die 'RECEIPT_BEHOLDING_CHORA must be a #u8"…" or #uuid"…" literal'
  fi
  case "${RECEIPT_KEEP_LINEAGE_DETAIL:-0}" in
    0|1) ;;
    *) receipt_die 'RECEIPT_KEEP_LINEAGE_DETAIL must be 0 or 1' ;;
  esac
  for v in receipt_claims receipt_echoes receipt_header receipt_trusted_base receipt_invocation receipt_inputs receipt_status_ids receipt_recorded_legs; do
    declare -F "$v" >/dev/null || receipt_die "the home script must define $v"
  done
  # The run ledger has one source: the data file RECEIPT_LEDGER names, or the
  # hook receipt_runs.
  if [[ -n "${RECEIPT_LEDGER:-}" ]]; then
    ! declare -F receipt_runs >/dev/null || receipt_die "the home script sets RECEIPT_LEDGER and defines receipt_runs: the run ledger has one source"
  else
    declare -F receipt_runs >/dev/null || receipt_die "the home script must define receipt_runs, or set RECEIPT_LEDGER to the run ledger file"
  fi
  _receipt_claims_file="$(mktemp)"; _receipt_runs_file="$(mktemp)"; _receipt_echoes_file="$(mktemp)"; _receipt_header_file="$(mktemp)"
  _receipt_tmpfiles+=("$_receipt_claims_file" "$_receipt_runs_file" "$_receipt_echoes_file" "$_receipt_header_file")
  _receipt_hook "$_receipt_claims_file" receipt_claims
  if [[ -n "${RECEIPT_LEDGER:-}" ]]; then _receipt_read_ledger_file > "$_receipt_runs_file"; else _receipt_hook "$_receipt_runs_file" receipt_runs; fi
  _receipt_hook "$_receipt_echoes_file" receipt_echoes
  _receipt_hook "$_receipt_header_file" receipt_header
  _receipt_load_provers
  local mode=--write target="$RECEIPT_OUT" row tmp
  local r_prover= r_run= r_commit= r_checker= r_reported='' r_axioms='' r_axioms_given=''
  local r_image=""
  _receipt_fallback_commit=
  while (( $# )); do
    case "$1" in
      --write|--check) mode="$1" ;;
      --digest)   mode=--digest; r_prover="${2:-}"; shift ;;
      --inputs)   mode=--inputs; r_prover="${2:-}"; shift ;;
      --run-row)  mode=--run-row; r_prover="${2:-}"; shift ;;
      --emit-run) mode=--emit-run; _receipt_extra="${2:-}"; _receipt_new_rows="${2:-}"; shift ;;
      --record)   mode=--record; _receipt_new_rows="${2:-}"; shift ;;
      --out)      target="${2:-}"; shift ;;
      --commit)   _receipt_fallback_commit="${2:-}"; r_commit="${2:-}"; shift ;;
      --run)      r_run="${2:-}"; shift ;;
      --checker)  r_checker="${2:-}"; shift ;;
      --reported) r_reported="${2:-}"; shift ;;
      --axioms)   r_axioms="${2:-}"; r_axioms_given=1; shift ;;
      --image)    r_image="${2:-}"; shift ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$mode" in --digest|--inputs|--run-row)
    _receipt_is_prover "$r_prover" || receipt_die "unknown prover '$r_prover': agda, rocq, lean, or one that receipt_extra_legs names" ;;
  esac
  case "$mode" in
    --digest) _receipt_digest "$r_prover" ;;
    --inputs) _receipt_inputs "$r_prover" ;;
    --run-row)
      # The axioms are what the run reported, stated by the caller: a gate
      # that refuses every axiom passes "none", and a leg whose kernel admits
      # named axioms (§8.4, disposition c, b or debt) lists them.  Leaving it
      # out is refused, so a row never asserts "no axioms" on a run's behalf.
      [[ -n "$r_axioms_given" ]] || receipt_die "--run-row needs --axioms: none, or what the run reported as NAME:c|b|debt, comma-separated"
      [[ -n "$r_axioms" ]] || receipt_die "--axioms needs a value: none, or NAME:c|b|debt, comma-separated"
      [[ "$r_axioms" != none ]] || r_axioms=
      tmp="$(mktemp)"; _receipt_tmpfiles+=("$tmp")
      _receipt_hook "$tmp" receipt_invocation "$r_prover"
      [[ "$(grep -c . "$tmp")" == 1 && "$(wc -l < "$tmp")" == 1 ]] || receipt_die "receipt_invocation must print exactly one line for $r_prover"
      local imd imf tbf=
      imd="$(mktemp -d)"; _receipt_tmpfiles+=("$imd")
      _receipt_build_imports "$r_prover" "$r_commit" "$imd"
      # The row records the pinned commit's bytes; the prover read the clone's
      # working files.  They must be the same files, or the row would bind
      # bytes the run never read.
      _receipt_check_import_worktree "$imd" "$r_prover"
      imf="$(_receipt_imports_field "$imd" "$r_prover")"
      if [[ "$r_prover" == agda ]]; then
        _receipt_hook "$imd/trusted-base" receipt_trusted_base
        tbf="$(_receipt_trusted_base_field "$imd/trusted-base")"
      fi
      row="$r_prover|$r_run|$r_commit|$r_checker|$(cat "$tmp")|$(_receipt_digest "$r_prover")|$r_reported|current||$r_axioms"
      if [[ -n "$r_image" ]]; then row+="|$imf|$tbf|$r_image"
      elif [[ -n "$tbf" ]]; then row+="|$imf|$tbf"; elif [[ -n "$imf" ]]; then row+="|$imf"; fi
      _receipt_check_row "$row"; printf '%s\n' "$row" ;;
    --write|--emit-run|--record)
      _receipt_check_claim_ids; _receipt_check_leg_records
      if [[ "$mode" == --record ]]; then
        # The rows of a run that just passed join the ledger file: they are
        # checked with the ledger first, and appended only once the receipt
        # they give has been written, read and checked.
        [[ -n "${RECEIPT_LEDGER:-}" ]] || receipt_die "--record appends to the run ledger file, so the home script must set RECEIPT_LEDGER"
        [[ -f "$_receipt_new_rows" ]] || receipt_die "--record needs a rows file"
        grep -q '[^[:space:]]' "$_receipt_new_rows" || receipt_die "--record was given no rows: $_receipt_new_rows is empty"
        while IFS= read -r row; do
          [[ -n "$row" ]] || continue
          [[ "$(cut -d'|' -f8 <<< "$row")" == current ]] || receipt_die "a row given to --record must be current: $row"
          ! awk -F'|' -v p="$(cut -d'|' -f1 <<< "$row")" -v r="$(cut -d'|' -f2 <<< "$row")" '$1==p && $2==r{f=1} END{exit !f}' "$_receipt_runs_file" \
            || receipt_die "the run ledger already holds this run of the $(cut -d'|' -f1 <<< "$row") leg: $(cut -d'|' -f2 <<< "$row")"
          printf '%s\n' "$row" >> "$_receipt_runs_file"
        done < "$_receipt_new_rows"
      fi
      if [[ "$mode" == --emit-run ]]; then
        [[ -f "$_receipt_extra" ]] || receipt_die "--emit-run needs a rows file"
        grep -q '[^[:space:]]' "$_receipt_extra" || receipt_die "--emit-run was given no rows: $_receipt_extra is empty"
      fi
      [[ ! -d "$target" ]] || receipt_die "the receipt target $target is a directory"
      _receipt_prepare
      _receipt_note_stale
      # What is still current must describe the tree it is written from (a
      # row whose inputs moved was derived stale above).
      _receipt_check_currency
      mkdir -p "$(dirname "$target")"
      # Emit beside the target and move it into place only when the whole
      # receipt was written, so a refusal never leaves a partial file.
      # The staging copy keeps the target's name, which the reader checks.
      tmp="$(mktemp -d "$(dirname "$target")/.receipt.XXXXXX")"; _receipt_tmpfiles+=("$tmp")
      tmp="$tmp/$(basename "$target")"
      _receipt_emit > "$tmp"
      # The receipt is read, with its negative control, before it replaces
      # anything (PROOF-POLICY §8.5.1: a gate that writes receipts validates
      # them with the reader).
      _receipt_read_with_reader "$tmp"
      # --write installs the receipt the gate will hold: the git checks of
      # §8.5.3 run on it first, as --check runs them.  (--emit-run writes to
      # --out for a run CI has just recorded; the recording PR's --check runs
      # them there.)
      [[ "$mode" == --emit-run ]] || _receipt_check_git_facts "$tmp"
      local ledger_new='' deed_old=''
      if [[ "$mode" == --record ]]; then
        # The ledger with the new rows is written beside the ledger first, so
        # two renames are all that is left: the receipt and the ledger change
        # together, and a failed second rename puts the receipt back.
        ledger_new="$(mktemp "$(dirname "$RECEIPT_LEDGER")/.ledger.XXXXXX")" || receipt_die "cannot write beside $RECEIPT_LEDGER"
        _receipt_tmpfiles+=("$ledger_new")
        {
          cat "$RECEIPT_LEDGER"
          # The file ends in a newline before a row is appended to it.
          [[ ! -s "$RECEIPT_LEDGER" || -z "$(tail -c1 "$RECEIPT_LEDGER")" ]] || printf '\n'
          grep '[^[:space:]]' "$_receipt_new_rows"
        } > "$ledger_new" || receipt_die "cannot write the new ledger beside $RECEIPT_LEDGER"
        chmod --reference="$RECEIPT_LEDGER" "$ledger_new" 2>/dev/null || true
        if [[ -f "$target" ]]; then
          deed_old="$(mktemp "$(dirname "$target")/.receipt-old.XXXXXX")" || receipt_die "cannot write beside $target"
          _receipt_tmpfiles+=("$deed_old")
          cp -p -- "$target" "$deed_old" || receipt_die "cannot keep a copy of $target"
        fi
      fi
      mv -T "$tmp" "$target" || receipt_die "cannot install the receipt at $target"
      if [[ "$mode" == --record ]] && ! mv -T "$ledger_new" "$RECEIPT_LEDGER"; then
        # The receipt never describes rows the ledger lacks.
        if [[ -n "$deed_old" ]]; then mv -T "$deed_old" "$target" || true; else rm -f -- "$target"; fi
        receipt_die "cannot install the new ledger at $RECEIPT_LEDGER; the receipt was put back as it was"
      fi
      printf 'WROTE %s (source-commit %s)\n' "$target" "$_receipt_source_commit"
      if [[ "$mode" == --record ]]; then
        printf 'RECORDED %s row(s) in %s\n' "$(grep -c '[^[:space:]]' "$_receipt_new_rows")" "$RECEIPT_LEDGER"
      fi
      if [[ "$mode" == --emit-run ]]; then
        printf 'To record this run, add these rows to the run ledger in %s:\n' "$RECEIPT_SCRIPT"
        sed 's/^/  /' "$_receipt_extra"
      fi ;;
    --check)
      _receipt_check_claim_ids; _receipt_check_leg_records
      [[ -f "$RECEIPT_OUT" ]] || receipt_die "$RECEIPT_OUT is missing"
      _receipt_fallback_commit="$(sed -n 's/^  :source-commit "\([0-9a-f]*\)"$/\1/p' "$RECEIPT_OUT")"
      _receipt_prepare
      _receipt_note_stale
      _receipt_check_currency
      tmp="$(mktemp)"; _receipt_tmpfiles+=("$tmp")
      _receipt_emit > "$tmp"
      if ! diff -u "$RECEIPT_OUT" "$tmp" >&2; then
        receipt_die "the receipt does not match the tree and the ledgers: regenerate with bash $RECEIPT_SCRIPT --write"
      fi
      printf 'PASS: %s matches the tree and the ledgers (source-commit %s)\n' "$RECEIPT_OUT" "$_receipt_source_commit"
      _receipt_check_git_facts "$RECEIPT_OUT"
      _receipt_read_with_reader "$RECEIPT_OUT" ;;
    *) receipt_die "unknown mode: $mode" ;;
  esac
}
