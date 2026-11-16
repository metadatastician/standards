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
#   --write              write the receipt from the tree and the ledgers
#   --check              regenerate it, refuse any difference, do the git
#                        checks of §8.5.3, check that each current receipt
#                        still describes the tree, and run the pinned reader
#                        with a negative control
#   --digest PROVER      print the §8.5.1 inputs digest of one leg (agda|rocq|lean)
#   --inputs PROVER      print the §8.5.1 input set of one leg, one path a line
#   --run-row PROVER --run URL --commit SHA --checker TEXT --reported TEXT
#                        print one ledger row for a run that just passed
#   --emit-run ROWS --out FILE
#                        write a receipt for the run whose rows are in ROWS:
#                        they become current, and the earlier current receipts
#                        of the same legs become superseded (CI does this)
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
# Functions (each prints to stdout):
#   receipt_claims          the claim list: id | §5 token of the Agda proof |
#                           kind | Rocq route | Rocq §2.2 state | Lean route |
#                           Lean §2.2 state | Rocq reason | Lean reason
#   receipt_runs            the run ledger: prover | run | commit (40 hex) |
#                           checker | invocation | inputs sha256 | what the run
#                           reported | state (current|superseded|regressed) |
#                           reason | axioms (name:c|b|debt, comma-separated)
#   receipt_echoes          the echo ledger: source | image | inputs-sha256 |
#                           fetch ref
#   receipt_header          the comment lines that open the receipt, after
#                           nothing (the SPDX lines are the home's to write)
#   receipt_trusted_base    module | name | binding, one line per Agda
#                           prover postulate of §8.4
#   receipt_invocation P    the invocation of leg P (agda|rocq|lean)
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
#
# Helpers the hooks may use: receipt_agda_cone ROOT INCLUDE... (the modules a
# root imports, directly or not, found under the include directories in
# order), receipt_die MESSAGE.
#
# Scope: legs of Agda, Rocq and Lean only. The run ledger refuses a row of any
# other prover, so a repository with a witness outside dependent type theory
# (§8.3, foundation-diverse) cannot use this generator yet; it writes
# :foundation-diverse #f because no such leg can reach it.
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
  local root="$1"; shift
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
        p="$i/${m//.//}.agda"
        if [[ -f "$p" ]]; then queue+=("$p"); break; fi
      done
    done < <(sed -e 's/--.*$//' "$f" | grep -oE '(^|[[:space:];])import[[:space:]]+[A-Za-z0-9_.]+' | awk '{print $NF}')
  done
}

_receipt_inputs() {
  local f; f="$(mktemp)"
  receipt_inputs "$1" > "$f" || { rm -f "$f"; receipt_die "the hook receipt_inputs of $RECEIPT_SCRIPT failed for $1"; }
  LC_ALL=C sort -u "$f"; rm -f "$f"
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
_receipt_ensure_commit() {
  local commit="$1" ref="${2:-}"
  git cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  [[ -n "$ref" ]] || receipt_die "commit $commit is not here and has no fetch reference"
  git fetch -q origin "+$ref:refs/remotes/origin/receipt-fetch/${commit:0:12}" \
    || receipt_die "cannot fetch $ref for commit $commit"
  git cat-file -e "$commit^{commit}" 2>/dev/null || receipt_die "$ref does not hold commit $commit"
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
_receipt_check_row() {
  local row="$1" prover run commit checker inv dig said state reason axioms x
  local -a a
  IFS='|' read -r prover run commit checker inv dig said state reason axioms <<< "$row"
  [[ "$(tr -cd '|' <<< "$row" | wc -c)" == 9 ]] || receipt_die "a ledger row needs 10 fields: $row"
  [[ "$row" != *'"'* && "$row" != *'\'* ]] || receipt_die "a ledger row holds a quote or backslash: $row"
  [[ "$prover" =~ ^(agda|rocq|lean)$ ]] || receipt_die "unknown prover in row: $row"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || receipt_die "a row's commit must be 40 lowercase hex: $row"
  [[ "$dig" =~ ^[0-9a-f]{64}$ ]] || receipt_die "a row's inputs digest must be a sha256: $row"
  [[ -n "$run" && -n "$checker" && -n "$inv" && -n "$said" ]] || receipt_die "an empty field in row: $row"
  case "$state" in
    current) [[ -z "$reason" ]] || receipt_die "a current row carries no reason: $row" ;;
    superseded|regressed) [[ -n "$reason" ]] || receipt_die "a $state row needs a reason: $row" ;;
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

# ── Grade (§8.2 and §8.5.2, the same rules as readProofReceipt) ───────────────
_receipt_has_current() { awk -F'|' -v p="$1" '$1==p && $8=="current"{f=1} END{exit !f}' "$_receipt_ledger_file"; }
_receipt_current_field() { awk -F'|' -v p="$1" -v f="$2" '$1==p && $8=="current"{print $f}' "$_receipt_ledger_file"; }
_receipt_has_any() { awk -F'|' -v p="$1" '$1==p{f=1} END{exit !f}' "$_receipt_ledger_file"; }
# PROOF-POLICY §2.1: the Agda invocation is at least the estate default.
_receipt_canonical() {
  local w=" $1 "
  [[ "$w" == *' --safe '* && "$w" == *' --without-K '* ]] && [[ "$w" == *' --cubical-compatible '* || "$w" == *' --cubical '* ]]
}
# A leg's witness counts only if every axiom its current receipt reports has
# disposition c (§8.4).
_receipt_axioms_ok() { local x; x=",$(_receipt_current_field "$1" 10),"; [[ "$x" != *':b,'* && "$x" != *':debt,'* ]]; }
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
    2) if _receipt_describes_source agda && _receipt_describes_source rocq && _receipt_describes_source lean; then printf 'PWG-1'; else printf 'PWG-2ii'; fi ;;
    *) receipt_die "unexpected recheck count: $n" ;;
  esac
}
# A leg's §5 token: a RECONCILED re-proof is kernel-checked, so it is proven,
# or proven-with-postulates when its current run reported an axiom (§5: a
# kernel proof resting on named necessary axioms); any other state is open.
_receipt_leg_token() {
  local state="$1" prover="$2"
  if [[ "$state" != RECONCILED ]]; then printf 'open'
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
_receipt_emit_receipts() {
  local prover="$1" row p run commit checker inv dig said state reason axioms want
  # Current first, then the lineage in ledger order.
  for want in current other; do
    while IFS= read -r row; do
      IFS='|' read -r p run commit checker inv dig said state reason axioms <<< "$row"
      [[ "$p" == "$prover" ]] || continue
      if [[ $want == current ]]; then [[ $state == current ]] || continue; else [[ $state != current ]] || continue; fi
      printf '      ; the run reported: %s\n' "$said"
      printf '      (receipt :run "%s"\n' "$run"
      printf '               :commit "%s"\n' "$commit"
      printf '               :checker "%s"\n' "$checker"
      printf '               :invocation "%s"\n' "$inv"
      if [[ $state == current ]]; then
        printf '               :inputs-sha256 "%s"\n' "$dig"
        printf '               :state current\n'
        _receipt_emit_manifest "$prover"
        _receipt_emit_imports "$prover"
        _receipt_emit_axioms "$axioms"
      else
        printf '               :state %s\n               :reason "%s")\n' "$state" "$reason"
      fi
    done < "$_receipt_ledger_file"
  done
}
_receipt_emit_echoes() {
  local src img wit ref p
  while IFS='|' read -r src img wit ref; do
    printf '  ; %s was rewritten into %s on %s; %s keeps it.\n' "${src:0:12}" "${img:0:12}" "$RECEIPT_DEFAULT_BRANCH" "$ref"
    printf '  (echo :source "%s" :image "%s" :witness %s' "$src" "$img" "$wit"
    for p in agda rocq lean; do
      _receipt_has_current "$p" || continue
      printf '\n    (inputs :prover %s :sha256 "%s")' "$p" "$(awk -F'|' -v c="$src" -v p="$p" '$1==c && $2==p{print $3}' "$_receipt_echo_digest_file")"
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
      printf '    (leg :prover %s :route %s :token %s :state %s' "$prover" "$route" "$(_receipt_leg_token "$state" "$prover")" "$state"
      if _receipt_has_any "$prover"; then printf '\n'; _receipt_emit_receipts_closed "$prover" "$close"; else printf '%s\n' "$close"; fi ;;
    *) receipt_die "unknown route for the $prover leg: $route" ;;
  esac
}
_receipt_emit() {
  local id token kind coq coq_state lean lean_state coq_reason lean_reason m name binding
  cat "$_receipt_header_file"
  printf '(praxis-deed\n'
  printf '  :schema-version "1.0.0"\n'
  printf '  :canonical-name "%s"\n' "$RECEIPT_CANONICAL_NAME"
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
    printf '  (claim :id "%s" :pwg %s :foundation-diverse #f\n' "$id" "$(_receipt_pwg_of "$token" "$coq" "$coq_state" "$lean" "$lean_state")"
    printf '    (leg :prover agda :route source :token %s :state AGDA-VERIFIED' "$token"
    if _receipt_has_any agda; then printf '\n'; _receipt_emit_receipts_closed agda ')'; else printf ')\n'; fi
    _receipt_emit_leg rocq "$coq" "$coq_state" "$coq_reason" ')'
    _receipt_emit_leg lean "$lean" "$lean_state" "$lean_reason" '))'
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
# current receipt it is $_receipt_fallback_commit (nothing is graded then).
# Each echo link's witness digests are computed at its source and at its
# image with the reference script, and must be equal (§8.5.3, check 3).
_receipt_prepare() {
  _receipt_ledger_file="$(mktemp)"; _receipt_echo_file="$(mktemp)"; _receipt_echo_digest_file="$(mktemp)"
  _receipt_manifest_dir="$(mktemp -d)"
  _receipt_tmpfiles+=("$_receipt_ledger_file" "$_receipt_echo_file" "$_receipt_echo_digest_file" "$_receipt_manifest_dir")
  _receipt_ledger > "$_receipt_ledger_file"
  _receipt_trusted_base_file="$(mktemp)"; _receipt_tmpfiles+=("$_receipt_trusted_base_file")
  _receipt_hook "$_receipt_trusted_base_file" receipt_trusted_base
  grep . "$_receipt_echoes_file" > "$_receipt_echo_file" || true
  local row p commits src img wit ref a b c n repo commit dir path
  local -a paths
  while IFS= read -r row; do _receipt_check_row "$row"; done < "$_receipt_ledger_file"
  while IFS= read -r row; do _receipt_check_echo "$row"; done < "$_receipt_echo_file"
  [[ "$(cut -d'|' -f1 "$_receipt_echo_file" | sort | uniq -d | wc -l)" == 0 ]] || receipt_die 'an echo source has two images'
  # §8.5.2: no echo chain may cycle, whether or not the current receipts use it.
  local start
  while IFS='|' read -r start _; do
    local hops=0 at="$start"
    while at="$(awk -F'|' -v c="$at" '$1==c{print $2}' "$_receipt_echo_file")" && [[ -n "$at" ]]; do
      hops=$((hops + 1))
      [[ "$at" != "$start" ]] && (( hops < 64 )) || receipt_die "the echoes form a cycle through $start"
    done
  done < "$_receipt_echo_file"
  commits="$(awk -F'|' '$8=="current"{print $3}' "$_receipt_ledger_file" | sort -u)"
  [[ "$(grep -c . <<< "$commits" || true)" -le 1 ]] || receipt_die "the current receipts name different commits: $(tr '\n' ' ' <<< "$commits")"
  for p in agda rocq lean; do
    [[ "$(awk -F'|' -v p="$p" '$1==p && $8=="current"' "$_receipt_ledger_file" | wc -l)" -le 1 ]] || receipt_die "the $p leg has more than one current row"
  done
  while IFS='|' read -r src img wit ref; do
    # An image that is itself an echo source (a chain A -> B -> C) is kept by
    # its own forge reference; only the end of a chain is on the default branch.
    _receipt_ensure_commit "$src" "$ref"
    _receipt_ensure_commit "$img" "$(_receipt_echo_ref "$img" | grep . || printf 'refs/heads/%s' "$RECEIPT_DEFAULT_BRANCH")"
    for p in agda rocq lean; do
      # Only a leg with a current receipt has a manifest for the witness to
      # match (§8.5.3), so only those legs carry one.
      _receipt_has_current "$p" || continue
      a="$(_receipt_ref_digest "$src" "$p")" || receipt_die "cannot compute the $p digest at $src"
      b="$(_receipt_ref_digest "$img" "$p")" || receipt_die "cannot compute the $p digest at $img"
      [[ "$a" == "$b" ]] || receipt_die "echo $src -> $img: the $p inputs differ ($a at the source, $b at the image)"
      printf '%s|%s|%s\n' "$src" "$p" "$a" >> "$_receipt_echo_digest_file"
    done
  done < "$_receipt_echo_file"
  # The inputs manifest of each current receipt, at its commit (§8.5.1).  Its
  # SHA-256 is the digest the ledger records, or the row is wrong.  Then the
  # manifest of each repository the run imported, at its pinned commit.
  for p in agda rocq lean; do
    _receipt_has_current "$p" || continue
    c="$(_receipt_current_field "$p" 3)"
    _receipt_ensure_commit "$c" "$(_receipt_echo_ref "$c")"
    mapfile -t paths < <(_receipt_inputs "$p")
    (( ${#paths[@]} )) || receipt_die "the $p leg has no inputs"
    bash "$(_receipt_digest_script)" --manifest "$c" "${paths[@]}" > "$_receipt_manifest_dir/$p" || receipt_die "cannot list the $p inputs at $c"
    a="$(sha256sum < "$_receipt_manifest_dir/$p" | cut -d' ' -f1)"
    [[ "$a" == "$(_receipt_current_field "$p" 6)" ]] \
      || receipt_die "the $p receipt records inputs $(_receipt_current_field "$p" 6), but the manifest at $c gives $a"
    _receipt_hook "$_receipt_manifest_dir/$p.raw" _receipt_imports "$p" "$c"
    grep . "$_receipt_manifest_dir/$p.raw" > "$_receipt_manifest_dir/$p.lines" || true
    while IFS= read -r row; do _receipt_check_import "$row"; done < "$_receipt_manifest_dir/$p.lines"
    [[ "$(cut -d'|' -f1 "$_receipt_manifest_dir/$p.lines" | LC_ALL=C sort -u | wc -l)" == "$(cut -d'|' -f1 "$_receipt_manifest_dir/$p.lines" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u | wc -l)" ]] \
      || receipt_die "the $p leg names one imported repository in two spellings; GitHub names are case-insensitive, so spell each one way"
    n=0
    while IFS='|' read -r repo commit dir; do
      [[ -n "$repo" ]] || continue
      [[ "$(awk -F'|' -v r="$repo" 'tolower($1)==tolower(r){print $2"|"$3}' "$_receipt_manifest_dir/$p.lines" | sort -u | wc -l)" == 1 ]] \
        || receipt_die "the $p leg imports $repo at more than one commit or clone (one pin per repository)"
      _receipt_ensure_import "$repo" "$commit" "$dir"
      mapfile -t paths < <(awk -F'|' -v r="$repo" '$1==r{print $4}' "$_receipt_manifest_dir/$p.lines" | LC_ALL=C sort -u)
      n=$((n + 1))
      bash "$(_receipt_digest_script)" -C "$dir" --manifest "$commit" "${paths[@]}" > "$_receipt_manifest_dir/$p.import.$n" \
        || receipt_die "cannot list the $p inputs of $repo at $commit"
      printf '%s|%s|%s|%s\n' "$repo" "$commit" "$(sha256sum < "$_receipt_manifest_dir/$p.import.$n" | cut -d' ' -f1)" "$_receipt_manifest_dir/$p.import.$n" \
        >> "$_receipt_manifest_dir/$p.imports"
      # The checker takes one clone per repository, so every leg that imports
      # a repository must name the same clone.
      if [[ -f "$_receipt_manifest_dir/clones" ]] && awk -F= -v r="${repo,,}" -v d="$dir" 'tolower($1)==r && $2!=d{f=1} END{exit !f}' "$_receipt_manifest_dir/clones"; then
        receipt_die "two legs import $repo from different clones; name one clone for it"
      fi
      printf '%s=%s\n' "$repo" "$dir" >> "$_receipt_manifest_dir/clones"
    done < <(cut -d'|' -f1-3 "$_receipt_manifest_dir/$p.lines" | LC_ALL=C sort -u -t'|' -k1,1)
  done
  _receipt_source_commit="${commits:-$_receipt_fallback_commit}"
  local steps=0 next
  while next="$(awk -F'|' -v c="$_receipt_source_commit" '$1==c{print $2}' "$_receipt_echo_file")" && [[ -n "$next" ]]; do
    _receipt_source_commit="$next"; steps=$((steps + 1))
    (( steps < 64 )) || receipt_die 'the echoes form a cycle'
  done
  [[ "$_receipt_source_commit" =~ ^[0-9a-f]{40}$ ]] || receipt_die "no 40-hex source commit (got '${_receipt_source_commit}')"
}

# §8.5.3: the git checks, by the shared checker, so the home gate and every
# consumer check in the same way.
_receipt_check_git_facts() {
  local file="$1" base clone
  local -a imports=()
  base="refs/remotes/origin/$RECEIPT_DEFAULT_BRANCH"
  git rev-parse -q --verify "$base" >/dev/null || base="refs/heads/$RECEIPT_DEFAULT_BRANCH"
  if [[ -f "$_receipt_manifest_dir/clones" ]]; then
    while IFS= read -r clone; do imports+=(--import "$clone"); done < <(sort -u "$_receipt_manifest_dir/clones")
  fi
  bash "$(_receipt_checker)" --branch "$base" "${imports[@]}" "$file" . || receipt_die "the git checks of PROOF-POLICY §8.5.3 failed for $file"
  printf 'PASS: git checks of §8.5.3 (shared checker, standards %s, --branch %s)\n' "${RECEIPT_STANDARDS_COMMIT:0:12}" "$base"
}

# Each current receipt must still describe the tree: its inputs digest is the
# digest of the inputs now.  Otherwise the grade cannot be carried forward
# (§8.4, regression drops the grade): record a new run, or mark the row
# superseded or regressed with its reason.
_receipt_check_currency() {
  local p want got
  for p in agda rocq lean; do
    _receipt_has_current "$p" || continue
    want="$(_receipt_current_field "$p" 6)"; got="$(_receipt_digest "$p")"
    [[ "$want" == "$got" ]] || receipt_die "the $p inputs changed since run $(_receipt_current_field "$p" 2) (recorded $want, now $got): record a new CI run, or mark that row superseded or regressed"
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

receipt_main() {
  local v
  for v in RECEIPT_STD RECEIPT_STANDARDS_COMMIT RECEIPT_OUT RECEIPT_REPOSITORY RECEIPT_DEFAULT_BRANCH RECEIPT_CANONICAL_NAME RECEIPT_SCRIPT; do
    [[ -n "${!v:-}" ]] || receipt_die "the home script must set $v"
  done
  for v in receipt_claims receipt_runs receipt_echoes receipt_header receipt_trusted_base receipt_invocation receipt_inputs receipt_status_ids receipt_recorded_legs; do
    declare -F "$v" >/dev/null || receipt_die "the home script must define $v"
  done
  # The gate's own strictness, whatever the sourcing script set: a failure
  # anywhere stops it rather than letting a later step report success.
  set -euo pipefail
  # Keep the home script's EXIT trap, and clean up before it runs.
  local prior
  prior="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT\$/\1/")"
  trap "_receipt_cleanup${prior:+; $prior}" EXIT
  _receipt_claims_file="$(mktemp)"; _receipt_runs_file="$(mktemp)"; _receipt_echoes_file="$(mktemp)"; _receipt_header_file="$(mktemp)"
  _receipt_tmpfiles+=("$_receipt_claims_file" "$_receipt_runs_file" "$_receipt_echoes_file" "$_receipt_header_file")
  _receipt_hook "$_receipt_claims_file" receipt_claims
  _receipt_hook "$_receipt_runs_file" receipt_runs
  _receipt_hook "$_receipt_echoes_file" receipt_echoes
  _receipt_hook "$_receipt_header_file" receipt_header
  local mode=--write target="$RECEIPT_OUT" row tmp
  local r_prover= r_run= r_commit= r_checker= r_reported=
  _receipt_fallback_commit=
  while (( $# )); do
    case "$1" in
      --write|--check) mode="$1" ;;
      --digest)   mode=--digest; r_prover="${2:-}"; shift ;;
      --inputs)   mode=--inputs; r_prover="${2:-}"; shift ;;
      --run-row)  mode=--run-row; r_prover="${2:-}"; shift ;;
      --emit-run) mode=--emit-run; _receipt_extra="${2:-}"; shift ;;
      --out)      target="${2:-}"; shift ;;
      --commit)   _receipt_fallback_commit="${2:-}"; r_commit="${2:-}"; shift ;;
      --run)      r_run="${2:-}"; shift ;;
      --checker)  r_checker="${2:-}"; shift ;;
      --reported) r_reported="${2:-}"; shift ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$mode" in
    --digest) _receipt_digest "$r_prover" ;;
    --inputs) _receipt_inputs "$r_prover" ;;
    --run-row)
      # A run that passed its gate reported no axiom: every gate fails on one.
      tmp="$(mktemp)"; _receipt_tmpfiles+=("$tmp")
      _receipt_hook "$tmp" receipt_invocation "$r_prover"
      [[ "$(grep -c . "$tmp")" == 1 && "$(wc -l < "$tmp")" == 1 ]] || receipt_die "receipt_invocation must print exactly one line for $r_prover"
      row="$r_prover|$r_run|$r_commit|$r_checker|$(cat "$tmp")|$(_receipt_digest "$r_prover")|$r_reported|current||"
      _receipt_check_row "$row"; printf '%s\n' "$row" ;;
    --write|--emit-run)
      _receipt_check_claim_ids; _receipt_check_leg_records
      [[ -n "$_receipt_fallback_commit" ]] || _receipt_fallback_commit="$(git rev-parse HEAD)"
      if [[ "$mode" == --emit-run ]]; then
        [[ -f "$_receipt_extra" ]] || receipt_die "--emit-run needs a rows file"
        grep -q '[^[:space:]]' "$_receipt_extra" || receipt_die "--emit-run was given no rows: $_receipt_extra is empty"
      fi
      [[ ! -d "$target" ]] || receipt_die "the receipt target $target is a directory"
      _receipt_prepare
      # A receipt must describe the tree it is written from: a current row
      # whose inputs moved is superseded or regressed first, never rewritten.
      _receipt_check_currency
      mkdir -p "$(dirname "$target")"
      # Emit beside the target and move it into place only when the whole
      # receipt was written, so a refusal never leaves a partial file.
      # The staging copy keeps the target's name, which the reader checks.
      tmp="$(mktemp -d "$(dirname "$target")/.receipt.XXXXXX")"; _receipt_tmpfiles+=("$tmp")
      tmp="$tmp/$(basename "$target")"
      _receipt_emit > "$tmp"
      # A run's receipt is read, with its negative control, before it
      # replaces anything.
      if [[ "$mode" == --emit-run ]]; then _receipt_read_with_reader "$tmp"; fi
      mv -T "$tmp" "$target" || receipt_die "cannot install the receipt at $target"
      printf 'WROTE %s (source-commit %s)\n' "$target" "$_receipt_source_commit"
      if [[ "$mode" == --emit-run ]]; then
        printf 'To record this run, add these rows to the run ledger in %s:\n' "$RECEIPT_SCRIPT"
        sed 's/^/  /' "$_receipt_extra"
      fi ;;
    --check)
      _receipt_check_claim_ids; _receipt_check_leg_records
      [[ -f "$RECEIPT_OUT" ]] || receipt_die "$RECEIPT_OUT is missing"
      _receipt_fallback_commit="$(sed -n 's/^  :source-commit "\([0-9a-f]*\)"$/\1/p' "$RECEIPT_OUT")"
      _receipt_prepare
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
