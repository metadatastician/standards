#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves scripts/proof-receipt.sh, the shared receipt generator: a home
# repository whose Agda root imports a pinned sibling gets a receipt with an
# (import …) clause that the reader accepts at PWG-1 and the shared git
# checker holds; --check passes on it and fails on a tampered receipt; and a
# self-import, a missing import commit and a moved input each fail for their
# own reason.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v bun >/dev/null || { echo "SKIP: bun is needed to run the reader" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
# expect LABEL EXIT FRAGMENT|- ARGS... (runs the home script in $R)
expect() {
  local label=$1 want_rc=$2 want_msg=$3; shift 3
  local out rc=0
  out=$(cd "$R" && bash scripts/grade-receipt.sh "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ]; then bad "$label (exit $rc, want $want_rc)"; printf '%s\n' "$out" | sed 's/^/        /' | tail -20; return; fi
  if [ "$want_msg" != - ] && ! grep -qF -- "$want_msg" <<<"$out"; then bad "$label (no \"$want_msg\")"; printf '%s\n' "$out" | sed 's/^/        /' | tail -20; return; fi
  ok "$label"
}
gitq() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }

# The sibling: one module, pinned at SC.
SIB="$WORK/sibling"
git init -q -b main "$SIB"
mkdir -p "$SIB/src"; printf 'module Sib where\n' >"$SIB/src/Sib.agda"
gitq -C "$SIB" add -A; gitq -C "$SIB" commit -qm sib
SC=$(git -C "$SIB" rev-parse HEAD)

# The home repository.
R="$WORK/home"
git init -q -b main "$R"
mkdir -p "$R/src/T" "$R/scripts" "$R/legs/rocq" "$R/legs/lean/T" "$R/verification/receipts"
printf 'module T.A where\nopen import Sib\nimport T.B\n' >"$R/src/T/A.agda"
printf 'module T.B where\n' >"$R/src/T/B.agda"
printf 'Theorem t : True. Proof. exact I. Qed.\n' >"$R/legs/rocq/T.v"
printf 'theorem t : True := trivial\n' >"$R/legs/lean/T/A.lean"
printf 'import T.A\n' >"$R/legs/lean/T.lean"
printf 'name = "t"\n' >"$R/legs/lean/lakefile.toml"
printf 'leanprover/lean4:v4.24.0\n' >"$R/legs/lean/lean-toolchain"
printf '%s\n' "$SC" >"$R/scripts/sibling.pin"
printf '| T-1 | proven\n| T-2 | tested-only\n' >"$R/STATUS.adoc"
printf '| T-1 | RECONCILED | RECONCILED\n' >"$R/legs/README.adoc"
: >"$R/runs.rows"
cat >"$R/scripts/grade-receipt.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")/.."
export LC_ALL=C.UTF-8
RECEIPT_STD="$ROOT"
RECEIPT_STANDARDS_COMMIT=0000000000000000000000000000000000000000
RECEIPT_OUT=verification/receipts/t_praxis.deed
RECEIPT_REPOSITORY="\${HOME_REPOSITORY:-o/home}"
RECEIPT_DEFAULT_BRANCH=main
RECEIPT_CANONICAL_NAME=t-proof-receipt
RECEIPT_SCRIPT=scripts/grade-receipt.sh
SIB="$SIB"
receipt_claims() { printf '%s\n' 'T-1|proven|theorem|re-proved|RECONCILED|re-proved|RECONCILED||' 'T-2|tested-only|demonstration|n/a|n/a|n/a|n/a||'; }
receipt_runs() { if [ -n "\${PARTIAL_FAIL:-}" ]; then cat runs.rows; return 3; fi; [ -z "\${FAIL_RUNS:-}" ] || return 4; cat "\${RUNS_FILE:-runs.rows}"; }
receipt_echoes() { if [ -n "\${ECHO_ROW:-}" ]; then printf "%s\\n" "\$ECHO_ROW"; fi; }
receipt_header() { printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n;; test receipt\n'; }
receipt_trusted_base() { [ -z "\${FAIL_HOOK:-}" ] || return 3; }
receipt_invocation() {
  case "\$1" in
    agda) printf 'agda --safe --without-K --cubical-compatible -i src -i _deps/sibling/src src/T/A.agda\n' ;;
    rocq) printf 'coqc -q T.v (in legs/rocq)\n' ;;
    lean) printf 'lake build (in legs/lean)\n' ;;
  esac
}
receipt_inputs() {
  case "\$1" in
    agda) receipt_agda_cone src/T/A.agda src "\$SIB/src" | grep -v "^\$SIB/"; printf 'scripts/sibling.pin\n' ;;
    rocq) printf 'legs/rocq/T.v\n' ;;
    lean) git ls-files -- legs/lean ;;
  esac
}
receipt_imports() {
  local pin; pin="\${IMPORT_COMMIT:-\$(git show "\$2:scripts/sibling.pin")}"
  case "\$1" in
    agda) receipt_agda_cone src/T/A.agda src "\$SIB/src" | sed -n "s|^\$SIB/||p" \
            | while read -r p; do printf '%s|%s|%s|%s\n' "\${IMPORT_REPOSITORY:-o/sibling}" "\$pin" "\$SIB" "\$p"; done ;;
  esac
}
receipt_status_ids() { grep -oE '^\\| T-[0-9]+ ' STATUS.adoc | tr -d '| ' || true; }
receipt_recorded_legs() { grep -oE '^\\| T-[0-9]+ \\| RECONCILED \\| RECONCILED\$' legs/README.adoc | cut -d" " -f2 || true; }
. "\$RECEIPT_STD/scripts/proof-receipt.sh"
receipt_main "\$@"
EOF
gitq -C "$R" add -A; gitq -C "$R" commit -qm home
C=$(git -C "$R" rev-parse HEAD)

# Inputs: the cone stays home, the sibling module goes to the import.
expect "the Agda input set holds the home cone and the pin, not the sibling" 0 "scripts/sibling.pin" --inputs agda
out=$(cd "$R" && bash scripts/grade-receipt.sh --inputs agda)
[ "$out" = $'scripts/sibling.pin\nsrc/T/A.agda\nsrc/T/B.agda' ] && ok "the Agda input set is exactly the home files, sorted" || bad "the Agda input set: $out"

# Rows for a run that passed at C, then a receipt for that run.
for p in agda rocq lean; do
  (cd "$R" && bash scripts/grade-receipt.sh --run-row "$p" --run "https://ci.example/run/1" --commit "$C" --checker "$p 1" --reported "ok") >>"$WORK/rows" \
    || bad "--run-row $p"
done
expect "--emit-run writes a receipt the reader accepts at PWG-1" 0 "T-1  PWG-1" --emit-run "$WORK/rows" --out "$WORK/emitted_praxis.deed"
grep -q '(import :repository "o/sibling" :commit "'"$SC"'"' "$WORK/emitted_praxis.deed" \
  && ok "the receipt carries the (import …) of the sibling at its pin" || bad "no (import …) in the receipt"
grep -q '(file :path "src/Sib.agda"' "$WORK/emitted_praxis.deed" \
  && ok "the import lists the sibling file by its path in the sibling" || bad "the import does not list src/Sib.agda"
grep -q 'T-2' "$WORK/emitted_praxis.deed" && bad "a demonstration got a claim" || ok "a demonstration has no claim"

# Record the run, write, check.
cp "$WORK/rows" "$R/runs.rows"; gitq -C "$R" commit -qam "record the run"
expect "--write writes the receipt" 0 "WROTE verification/receipts/t_praxis.deed" --write
gitq -C "$R" add -A; gitq -C "$R" commit -qm receipt
expect "--check passes: tree, ledgers, git checks with --import, reader, control" 0 "PASS: negative control" --check
expect "--check runs the shared checker on the import" 0 "import o/sibling: the manifest holds at $SC" --check

# A tampered receipt fails the regeneration diff.
sed -i 's/:pwg PWG-1/:pwg PWG-2ii/' "$R/verification/receipts/t_praxis.deed"
expect "a hand-edited grade fails --check" 1 "does not match the tree and the ledgers" --check
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed

# Each refusal, for its own reason.
HOME_REPOSITORY=o/sibling expect "a repository that imports itself is refused" 1 "a repository does not import itself" --write
IMPORT_COMMIT=0123456789abcdef0123456789abcdef01234567 expect "an import commit not in the clone is refused" 1 "does not hold commit 0123456789abcdef" --write
IMPORT_REPOSITORY=not-a-repo expect "an import without OWNER/REPO is refused" 1 "an import needs OWNER/REPO" --write
FAIL_HOOK=1 expect "a failing hook stops the gate by name" 1 "the hook receipt_trusted_base of scripts/grade-receipt.sh failed" --write
printf -- '-- moved\n' >>"$R/src/T/B.agda"
expect "a moved input makes the current receipt stale" 1 "the agda inputs changed since run" --check
gitq -C "$R" checkout -q -- src/T/B.agda
printf '| T-1 | RECONCILED | PENDING\n' >"$R/legs/README.adoc"
expect "a legs record that disagrees with the claim list is refused" 1 "differ from the legs record" --write

gitq -C "$R" checkout -q -- legs/README.adoc

# A failing ledger hook stops the gate by name, never a receipt from part of the data.
FAIL_RUNS=1 expect "a failing run-ledger hook stops the gate by name" 1 "the hook receipt_runs of scripts/grade-receipt.sh failed" --write

# A ledger hook that prints valid rows and then fails still stops the gate.
PARTIAL_FAIL=1 expect "a run-ledger hook that prints rows and then fails stops the gate" 1 "the hook receipt_runs of scripts/grade-receipt.sh failed" --write

# The rows of a run become current, so --emit-run refuses any other state.
sed 's/|current||$/|superseded|by hand|/' "$WORK/rows" | head -1 >"$WORK/badrows"
expect "--emit-run refuses a row that is not current" 1 "a row given to --emit-run must be current" --emit-run "$WORK/badrows" --out "$WORK/bad_praxis.deed"

# A counted leg whose run reported an axiom is proven-with-postulates (§5).
awk -F'|' 'BEGIN{OFS="|"} $1=="rocq"{$10="Classical:c"} {print}' "$WORK/rows" >"$WORK/axrows"
expect "--emit-run with a Rocq axiom of disposition c is accepted" 0 "PASS: the pinned reader" --emit-run "$WORK/axrows" --out "$WORK/ax_praxis.deed"
grep -q ':prover rocq :route re-proved :token proven-with-postulates' "$WORK/ax_praxis.deed" \
  && ok "that leg's token is proven-with-postulates" || bad "the Rocq leg with an axiom is not proven-with-postulates"
grep -q ':prover lean :route re-proved :token proven :state' "$WORK/ax_praxis.deed" \
  && ok "a leg without axioms stays proven" || bad "the Lean leg lost its proven token"
awk -F'|' 'BEGIN{OFS="|"} $1=="agda"{$10="funext:c"} {print}' "$WORK/rows" >"$WORK/agdaax"
expect "an Agda run with an axiom refuses a claim typed proven" 1 "its token is proven-with-postulates, not proven" --emit-run "$WORK/agdaax" --out "$WORK/agdaax_praxis.deed"

# A symbolic link among the inputs is refused, not hashed through.
ln -s T.lean "$R/legs/lean/Link.lean"; gitq -C "$R" add -A; gitq -C "$R" commit -qm link
expect "a symbolic link in an input set is refused" 1 "is a symbolic link" --digest lean
gitq -C "$R" rm -q legs/lean/Link.lean; gitq -C "$R" commit -qm unlink

# Two spellings of one imported repository are refused.
cp "$R/scripts/grade-receipt.sh" "$WORK/grade.orig"
sed -i 's/receipt_imports() {/receipt_imports() { if [ -n "${MIXED_CASE:-}" ]; then printf "%s|%s|%s|%s\\n" o\/sibling "$(git show "$2:scripts\/sibling.pin")" "$SIB" src\/Sib.agda O\/Sibling "$(git show "$2:scripts\/sibling.pin")" "$SIB" src\/Sib.agda; return 0; fi/' "$R/scripts/grade-receipt.sh"
MIXED_CASE=1 expect "an imported repository named in two spellings is refused" 1 "names one imported repository in two spellings" --write
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# A path a deed string cannot hold is refused, not written.
printf 'module T.Q where\n' >"$R/src/T/Q\"uote.agda"
gitq -C "$R" add -A; gitq -C "$R" commit -qm quote
QC=$(git -C "$R" rev-parse HEAD)
sed -i 's/^    rocq) printf .legs\/rocq\/T.v\\n. ;;$/    rocq) printf "legs\/rocq\/T.v\\n"; if [ -n "${QUOTE:-}" ]; then printf "src\/T\/Q\\"uote.agda\\n"; fi ;;/' "$R/scripts/grade-receipt.sh"
(cd "$R" && QUOTE=1 bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/q" --commit "$QC" --checker "rocq 1" --reported ok) >"$WORK/qrows" 2>/dev/null
RUNS_FILE="$WORK/qrows" QUOTE=1 expect "an input path holding a double quote is refused" 1 "holds a double quote" --write
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# PWG-3 across a squash: only the Agda leg has a current receipt, and the
# echo carries a witness for that leg alone, so the git checks hold.
grep '^agda|' "$R/runs.rows" >"$WORK/agda.rows"
printf 'docs\n' >"$R/README.adoc"; gitq -C "$R" add -A; gitq -C "$R" commit -qm docs
IMG=$(git -C "$R" rev-parse HEAD)
git -C "$R" update-ref refs/pull/1/head "$C"
RUNS_FILE="$WORK/agda.rows" ECHO_ROW="$C|$IMG|inputs-sha256|refs/pull/1/head" expect "a PWG-3 receipt carried by an echo writes" 0 "WROTE" --write
grep -q ':pwg PWG-3' "$R/verification/receipts/t_praxis.deed" && ok "the receipt derives PWG-3 with one current leg" || bad "no PWG-3 in the echo receipt"
grep -q '(inputs :prover rocq' "$R/verification/receipts/t_praxis.deed" && bad "the echo carries a witness for a leg with no current receipt" || ok "the echo carries witnesses only for current legs"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "pwg3 receipt"
RUNS_FILE="$WORK/agda.rows" ECHO_ROW="$C|$IMG|inputs-sha256|refs/pull/1/head" expect "its --check passes the git checks of the echo" 0 "PASS: negative control" --check

echo "proof-receipt-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
