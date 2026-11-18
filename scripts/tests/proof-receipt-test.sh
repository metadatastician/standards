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
mkdir -p "$R/legs/isabelle"; printf 'theory T imports Main begin lemma t: True by simp end\n' >"$R/legs/isabelle/T.thy"
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
RECEIPT_STD="\${STD_DIR:-$ROOT}"
RECEIPT_STANDARDS_COMMIT=0000000000000000000000000000000000000000
RECEIPT_OUT=verification/receipts/t_praxis.deed
RECEIPT_REPOSITORY="\${HOME_REPOSITORY:-o/home}"
RECEIPT_DEFAULT_BRANCH="\${DEFAULT_BRANCH:-main}"
RECEIPT_CANONICAL_NAME=t-proof-receipt
[ -z "\${BEHOLDING:-}" ] || RECEIPT_BEHOLDING_CHORA="\$BEHOLDING"
RECEIPT_SCRIPT=scripts/grade-receipt.sh
SIB="$SIB"
receipt_claims() { printf '%s\n' 'T-1|proven|theorem|re-proved|RECONCILED|re-proved|RECONCILED||' 'T-2|tested-only|demonstration|n/a|n/a|n/a|n/a||'; [ -z "\${SECOND:-}" ] || printf '%s\n' 'T-3|proven|theorem|re-proved|RECONCILED|re-proved|RECONCILED||'; [ -z "\${PENDING:-}" ] || printf 'T-4|%s\n' "\$PENDING"; }
receipt_run_scope() { [ -z "\${SCOPE:-}" ] || printf '%s\n' "\$SCOPE"; }
receipt_runs() { if [ -n "\${PARTIAL_FAIL:-}" ]; then cat runs.rows; return 3; fi; [ -z "\${FAIL_RUNS:-}" ] || return 4; cat "\${RUNS_FILE:-runs.rows}"; }
receipt_echoes() { if [ -n "\${ECHO_ROW:-}" ]; then printf "%s\\n" "\$ECHO_ROW"; fi; }
receipt_header() { printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n;; test receipt (a comment may say :pwg PWG-1 without moving the control)\n'; }
receipt_extra_legs() { [ -z "\${EXTRA:-}" ] || printf 'T-1|isabelle|re-proved|%s|\n' "\$EXTRA"; }
receipt_trusted_base() { [ -z "\${FAIL_HOOK:-}" ] || return 3; [ -z "\${TB:-}" ] || printf 'Agda.Primitive|Level|BUILTIN LEVEL\n'; }
receipt_invocation() {
  case "\$1" in
    agda) printf 'agda --safe --without-K --cubical-compatible -i src -i _deps/sibling/src src/T/A.agda\n' ;;
    rocq) printf 'coqc -q T.v (in legs/rocq)\n'; if [ -n "\${TWO_LINES:-}" ]; then printf 'second line\n'; fi ;;
    lean) printf 'lake build (in legs/lean)\n' ;;
    isabelle) printf 'isabelle build -D legs/isabelle\n' ;;
  esac
}
receipt_inputs() {
  case "\$1" in
    agda) receipt_agda_cone src/T/A.agda src "\$SIB/src" | grep -v "^\$SIB/"; printf 'scripts/sibling.pin\n' ;;
    rocq) printf 'legs/rocq/T.v\n' ;;
    lean) git ls-files -- legs/lean ;;
    isabelle) printf 'legs/isabelle/T.thy\n' ;;
  esac
}
receipt_imports() {
  local pin; pin="\${IMPORT_COMMIT:-\$(git show "\$2:scripts/sibling.pin")}"
  # A repin the home inputs do not see: only the hook, asked at HEAD, knows.
  [ "\$2" != HEAD ] || pin="\${HEAD_IMPORT_COMMIT:-\$pin}"
  case "\$1" in
    agda) receipt_agda_cone src/T/A.agda src "\$SIB/src" | sed -n "s|^\$SIB/||p" \
            | while read -r p; do printf '%s|%s|%s|%s\n' "\${IMPORT_REPOSITORY:-o/sibling}" "\$pin" "\$SIB" "\$p"; done ;;
  esac
}
receipt_status_ids() { grep -oE '^\\| T-[0-9]+ ' STATUS.adoc | tr -d '| ' || true; }
receipt_recorded_legs() { grep -oE '^\\| T-[0-9]+ \\| RECONCILED \\| RECONCILED\$' legs/README.adoc | cut -d" " -f2 || true; }
[ -z "\${LEDGER:-}" ] || { RECEIPT_LEDGER="\$LEDGER"; unset -f receipt_runs; }
. "\$RECEIPT_STD/scripts/proof-receipt.sh"
receipt_main "\$@"
EOF
gitq -C "$R" add -A; gitq -C "$R" commit -qm home
git -C "$R" remote add origin "$R"
C=$(git -C "$R" rev-parse HEAD)

# Inputs: the cone stays home, the sibling module goes to the import.
expect "the Agda input set holds the home cone and the pin, not the sibling" 0 "scripts/sibling.pin" --inputs agda
out=$(cd "$R" && bash scripts/grade-receipt.sh --inputs agda)
[ "$out" = $'scripts/sibling.pin\nsrc/T/A.agda\nsrc/T/B.agda' ] && ok "the Agda input set is exactly the home files, sorted" || bad "the Agda input set: $out"

# §8.2 (owner ruling 2026-11-16): a run counts toward PWG-1 only when it
# recorded the digest-pinned image its checker ran in.  The same run recorded
# without --image derives PWG-2ii, and a malformed image is refused.
IMG="ubuntu:24.04@sha256:$(printf 'a%.0s' $(seq 64))"
RUN_IMG="$IMG"   # kept: IMG is reused below for an echo image
for p in agda rocq lean; do
  (cd "$R" && bash scripts/grade-receipt.sh --run-row "$p" --run "https://ci.example/run/1" --commit "$C" --checker "$p 1" --reported "ok" --axioms none) >>"$WORK/noimgrows" \
    || bad "--run-row $p without --image"
done
expect "a run recorded without --image derives PWG-2ii, not PWG-1" 0 "T-1  PWG-2ii" --emit-run "$WORK/noimgrows" --out "$WORK/noimg_praxis.deed"
grep -q ':image ' "$WORK/noimg_praxis.deed" && bad "a run without --image got an :image" || ok "a run without --image carries no :image"
expect "a run row with a tag-only image is refused" 1 "a row's image must be NAME[:TAG]@sha256" --run-row rocq --run "https://ci.example/run/1" --commit "$C" --checker "rocq 1" --reported ok --axioms none --image "ubuntu:24.04"
# The generator accepts exactly what the reader accepts, so no row it writes
# is refused later: a malformed NAME is refused at --run-row, and the same
# row hand-written into a rows file is refused at --emit-run.
D64=$(printf 'a%.0s' $(seq 64))
for bad_img in "a//b@sha256:$D64" "debian:@sha256:$D64" "$(printf 'a%.0s' $(seq 256))@sha256:$D64"; do
  expect "a run row with image ${bad_img:0:12}… is refused" 1 "a row's image must be NAME[:TAG]@sha256" --run-row rocq --run "https://ci.example/run/1" --commit "$C" --checker "rocq 1" --reported ok --axioms none --image "$bad_img"
done
grep '^rocq|' "$WORK/noimgrows" | sed "s/\$/|||a\/\/b@sha256:$D64/" >"$WORK/badimgrows"
expect "a rows file with a malformed image is refused at --emit-run" 1 "a row's image must be NAME[:TAG]@sha256" --emit-run "$WORK/badimgrows" --out "$WORK/badimg_praxis.deed"

# Rows for a run that passed at C in a pinned image, then a receipt for it.
for p in agda rocq lean; do
  (cd "$R" && bash scripts/grade-receipt.sh --run-row "$p" --run "https://ci.example/run/1" --commit "$C" --checker "$p 1" --reported "ok" --axioms none --image "$IMG") >>"$WORK/rows" \
    || bad "--run-row $p"
done
expect "--emit-run writes a receipt the reader accepts at PWG-1" 0 "T-1  PWG-1" --emit-run "$WORK/rows" --out "$WORK/emitted_praxis.deed"
grep -q '(import :repository "o/sibling" :commit "'"$SC"'"' "$WORK/emitted_praxis.deed" \
  && ok "the receipt carries the (import …) of the sibling at its pin" || bad "no (import …) in the receipt"
grep -q '(file :path "src/Sib.agda"' "$WORK/emitted_praxis.deed" \
  && ok "the import lists the sibling file by its path in the sibling" || bad "the import does not list src/Sib.agda"
grep -q 'T-2' "$WORK/emitted_praxis.deed" && bad "a demonstration got a claim" || ok "a demonstration has no claim"
[ "$(grep -c ":image \"$IMG\"" "$WORK/emitted_praxis.deed")" = 3 ] && ok "each current leg receipt names its image" || bad "the receipt does not name the image on each current leg"

# Record the run, write, check.
cp "$WORK/rows" "$R/runs.rows"; gitq -C "$R" commit -qam "record the run"
expect "--write writes the receipt" 0 "WROTE verification/receipts/t_praxis.deed" --write
gitq -C "$R" add -A; gitq -C "$R" commit -qm receipt
expect "--check passes: tree, ledgers, git checks with --import, reader, control" 0 "PASS: negative control" --check
expect "--check runs the shared checker on the import" 0 "import o/sibling: the manifest holds at $SC" --check

# A run row states the axioms its run reported; it never assumes "none".
expect "a run row without --axioms is refused" 1 "--run-row needs --axioms" --run-row rocq --run "https://ci.example/run/x" --commit "$C" --checker "rocq 1" --reported ok
expect "a run row with a malformed axiom is refused" 1 "an axiom must be name:c" --run-row rocq --run "https://ci.example/run/x" --commit "$C" --checker "rocq 1" --reported ok --axioms Classical
out=$(cd "$R" && bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/x" --commit "$C" --checker "rocq 1" --reported ok --axioms Classical:c 2>&1)
[ "$(cut -d'|' -f10 <<<"$out")" = Classical:c ] && ok "a run row records the axioms it was given" || bad "the axioms field: $out"
out=$(cd "$R" && bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/x" --commit "$C" --checker "rocq 1" --reported ok --axioms none 2>&1)
[ -z "$(cut -d'|' -f10 <<<"$out")" ] && ok "--axioms none records an empty axioms field" || bad "--axioms none: $out"

# The imported files count toward currency (§8.5.1).  A repin that the home
# inputs do not see is caught by asking the hook again at HEAD: the commit is
# another, so the binding moves even though the bytes are the same.
SCX=$(gitq -C "$SIB" commit-tree "$SC^{tree}" -p "$SC" -m "same tree, another commit")
HEAD_IMPORT_COMMIT="$SCX" expect "a repin the home inputs do not see makes the receipt stale" 1 "is stale: the leg's imports changed" --check
# And the sibling checkout must hold the pinned files: one edited since the
# run is not taken for what the run read.
printf -- '-- edited\n' >>"$SIB/src/Sib.agda"
expect "an edited imported checkout makes the receipt stale" 1 "differs from o/sibling at $SC" --check
gitq -C "$SIB" checkout -q -- src/Sib.agda
expect "with the checkout restored, --check passes again" 0 "PASS: negative control" --check

# No current run, so nothing is graded and nothing names the :source-commit.
# HEAD is not taken for it (on a pull request it may not survive the merge):
# --write needs --commit.
awk -F'|' 'BEGIN{OFS="|"} {$8="superseded"; $9="by hand"; print}' "$R/runs.rows" >"$WORK/superrows"
RUNS_FILE="$WORK/superrows" expect "--write with no current run and no --commit is refused" 1 "pass --commit with a commit on main" --write
RUNS_FILE="$WORK/superrows" expect "--write with no current run takes --commit" 0 "WROTE verification/receipts/t_praxis.deed (source-commit $C)" --write --commit "$C"
grep -q ':pwg' "$R/verification/receipts/t_praxis.deed" && grep -q ':pwg ungraded' "$R/verification/receipts/t_praxis.deed" \
  && ok "and grades nothing" || bad "a receipt with no current run carries a grade"
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed

# The git checks run against the default branch only.  A clone without it
# cannot run them, and a checker that cannot run is exit 2, not a failed check.
DEFAULT_BRANCH=trunk expect "a clone without the default branch cannot run the git checks (exit 2)" 2 "neither origin/trunk nor trunk" --check
mkdir -p "$WORK/std/scripts"
ln -s "$ROOT/1-formats" "$WORK/std/1-formats"
for s in proof-receipt.sh proof-inputs-sha256.sh; do ln -s "$ROOT/scripts/$s" "$WORK/std/scripts/$s"; done
printf '#!/usr/bin/env bash\necho "cannot run: jq is not installed" >&2\nexit 2\n' >"$WORK/std/scripts/check-proof-receipt.sh"
STD_DIR="$WORK/std" expect "a checker that cannot run makes the gate exit 2, not 1" 2 "could not run" --check

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
expect "a moved input makes the current receipt stale" 1 "is stale: the leg's inputs changed" --check
expect "and the committed receipt, which says current, no longer matches" 1 "does not match the tree and the ledgers" --check
gitq -C "$R" checkout -q -- src/T/B.agda
printf '| T-1 | RECONCILED | PENDING\n' >"$R/legs/README.adoc"
expect "a legs record that disagrees with the claim list is refused" 1 "differ from the legs record" --write

gitq -C "$R" checkout -q -- legs/README.adoc

# A failing ledger hook stops the gate by name, never a receipt from part of the data.
FAIL_RUNS=1 expect "a failing run-ledger hook stops the gate by name" 1 "the hook receipt_runs of scripts/grade-receipt.sh failed" --write

# A ledger hook that prints valid rows and then fails still stops the gate.
PARTIAL_FAIL=1 expect "a run-ledger hook that prints rows and then fails stops the gate" 1 "the hook receipt_runs of scripts/grade-receipt.sh failed" --write

# The rows of a run become current, so --emit-run refuses any other state.
awk -F'|' 'BEGIN{OFS="|"} NR==1{$8="superseded"; $9="by hand"; print}' "$WORK/rows" >"$WORK/badrows"
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

# An invocation hook must print one line, not have its tail dropped.
TWO_LINES=1 expect "an invocation hook that prints two lines is refused" 1 "must print exactly one line" --run-row rocq --run "https://ci.example/run/2" --commit "$C" --checker "rocq 1" --reported ok --axioms none

# A claim typed proven-with-postulates needs the axioms its token names.
sed -i 's/T-1|proven|theorem/T-1|proven-with-postulates|theorem/' "$R/scripts/grade-receipt.sh"
expect "proven-with-postulates with no reported axiom is refused" 1 "names axioms, but the current Agda run reported none" --write
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# An echo cycle is refused even when the current receipts do not use it.
X1=1111111111111111111111111111111111111111; X2=2222222222222222222222222222222222222222
ECHO_ROW="$X1|$X2|inputs-sha256|refs/pull/7/head
$X2|$X1|inputs-sha256|refs/pull/8/head" expect "a cycle among echoes the receipts do not use is refused" 1 "the echoes form a cycle" --write

# A directory among the inputs is refused, not hashed as nothing.
sed -i 's/^    rocq) printf .legs\/rocq\/T.v\\n. ;;$/    rocq) printf "legs\/rocq\\n" ;;/' "$R/scripts/grade-receipt.sh"
expect "a directory given as an input is refused" 1 "is not a regular file" --digest rocq
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# The home script's own EXIT trap still runs.
sed -i 's/^\. "\$RECEIPT_STD\/scripts\/proof-receipt.sh"$/trap "echo HOME-TRAP-RAN" EXIT\n&/' "$R/scripts/grade-receipt.sh"
expect "the home script's EXIT trap is kept" 0 "HOME-TRAP-RAN" --digest agda
out=$(cd "$R" && bash scripts/grade-receipt.sh --digest agda 2>&1)
[ "$(grep -c HOME-TRAP-RAN <<<"$out")" = 1 ] && ok "and runs once, as written, never through the gate" || bad "the home EXIT trap ran $(grep -c HOME-TRAP-RAN <<<"$out") times"
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# --emit-run needs rows, a file target, and writes nothing a reader refuses.
: >"$WORK/emptyrows"
expect "--emit-run refuses an empty rows file" 1 "was given no rows" --emit-run "$WORK/emptyrows" --out "$WORK/empty_praxis.deed"
mkdir -p "$WORK/adir_praxis.deed"
expect "a directory as the receipt target is refused" 1 "is a directory" --emit-run "$WORK/rows" --out "$WORK/adir_praxis.deed"

# A current row whose inputs have since moved is derived stale (§8.4): no
# ledger edit is needed, the receipt says so, and the grade falls to what
# the receipts that still describe the tree support.  The row is current
# again once the tree is what the run read.
cp "$R/verification/receipts/t_praxis.deed" "$WORK/before-stale.deed"
printf -- '-- moved again\n' >>"$R/src/T/B.agda"
expect "--write derives stale for a current row whose inputs moved" 0 "is stale: the leg's inputs changed" --write
grep -q ':state stale' "$R/verification/receipts/t_praxis.deed" && ok "the receipt records the stale state" || bad "no :state stale in the receipt"
grep -q ':reason "the agda leg'"'"'s inputs changed after commit' "$R/verification/receipts/t_praxis.deed" && ok "with a derived reason" || bad "no derived reason"
grep -q '(claim :id "T-1" :pwg ungraded' "$R/verification/receipts/t_praxis.deed" && ok "and the grade falls: T-1 is ungraded without a current Agda receipt" || bad "T-1 kept a grade: $(grep -o '(claim :id "T-1" :pwg [A-Za-z0-9-]*' "$R/verification/receipts/t_praxis.deed")"
expect "the stale receipt checks" 0 "PASS: the pinned reader" --check
gitq -C "$R" checkout -q -- src/T/B.agda
expect "once the tree is what the run read, the stale receipt no longer matches" 1 "does not match the tree and the ledgers" --check
expect "and --write makes the row current again" 0 "WROTE" --write
cmp -s "$R/verification/receipts/t_praxis.deed" "$WORK/before-stale.deed" && ok "the receipt is byte-identical to the one before the change" || bad "the receipt differs after the tree returned"

# A module name with a hyphen is followed whole, not cut at the hyphen.
printf 'import T.B-x\n' >>"$R/src/T/A.agda"; printf 'module T.B-x where\n' >"$R/src/T/B-x.agda"
out=$(cd "$R" && bash scripts/grade-receipt.sh --inputs agda 2>&1)
grep -qx 'src/T/B-x.agda' <<<"$out" && ok "a hyphenated module name is followed whole" || bad "the cone missed src/T/B-x.agda: $out"
gitq -C "$R" checkout -q -- src/T/A.agda; rm -f "$R/src/T/B-x.agda"

# A tab can never sit in a deed string, so a row holding one is refused.
awk -F'|' 'BEGIN{OFS="|"} $1=="agda"{gsub(/ /,"\t",$5)} {print}' "$WORK/rows" >"$WORK/tabrows"
expect "a row with a tab in a field is refused" 1 "holds a control character" --emit-run "$WORK/tabrows" --out "$WORK/tab_praxis.deed"

# --write runs the reader before it replaces the receipt.
cp "$R/verification/receipts/t_praxis.deed" "$WORK/before_praxis.deed"
awk -F'|' 'BEGIN{OFS="|"} $1=="rocq"{$10="X:c,X:c"} {print}' "$R/runs.rows" >"$WORK/duprows"
RUNS_FILE="$WORK/duprows" expect "--write refuses a receipt the reader refuses" 1 "the pinned reader refused" --write
cmp -s "$WORK/before_praxis.deed" "$R/verification/receipts/t_praxis.deed" \
  && ok "and leaves the existing receipt as it was" || bad "a refused --write changed the receipt"

# The home EXIT handler sees the gate's own failure status.
sed -i 's/^\. "\$RECEIPT_STD\/scripts\/proof-receipt.sh"$/trap '"'"'echo "HOME-RC=$?"'"'"' EXIT\n&/' "$R/scripts/grade-receipt.sh"
expect "the home EXIT handler sees the refusal's status" 1 "HOME-RC=1" --emit-run "$WORK/emptyrows" --out "$WORK/rc_praxis.deed"
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# A literate module is followed like a plain one.
printf 'import T.L\n' >>"$R/src/T/A.agda"; printf '```agda\nmodule T.L where\n```\n' >"$R/src/T/L.lagda.md"
out=$(cd "$R" && bash scripts/grade-receipt.sh --inputs agda 2>&1)
grep -qx 'src/T/L.lagda.md' <<<"$out" && ok "a literate module (.lagda.md) is in the cone" || bad "the cone missed src/T/L.lagda.md: $out"
gitq -C "$R" checkout -q -- src/T/A.agda; rm -f "$R/src/T/L.lagda.md"

# A module named on the line after its import is followed too.
printf 'open import\n  T.M\n' >>"$R/src/T/A.agda"; printf 'module T.M where\n' >"$R/src/T/M.agda"
out=$(cd "$R" && bash scripts/grade-receipt.sh --inputs agda 2>&1)
grep -qx 'src/T/M.agda' <<<"$out" && ok "a module named on the next line is in the cone" || bad "the cone missed src/T/M.agda: $out"
gitq -C "$R" checkout -q -- src/T/A.agda; rm -f "$R/src/T/M.agda"

# A run row binds what the run imported: a hook that now derives other
# imported files cannot re-describe that run.
grep -q '|o/sibling@'"$SC"'=' "$R/runs.rows" && ok "the recorded Agda row binds the sibling import" || bad "the Agda row carries no import binding"
printf -- '-- later\n' >>"$SIB/src/Sib.agda"; gitq -C "$SIB" commit -qam later
SC_LATER=$(git -C "$SIB" rev-parse HEAD)
IMPORT_COMMIT="$SC_LATER" expect "a hook that now imports something else leaves that run stale" 0 "is stale: the leg's imports changed" --write
grep -q "o/sibling@$SC=" "$R/runs.rows" && ok "and the recorded binding is not rewritten" || bad "the binding moved"
# The run row binds the pinned bytes, so the imported clone must hold them:
# a sibling checked out at another commit is refused at --run-row.
expect "a run row is refused when the imported clone is not at its pin" 1 "differs from o/sibling at $SC" --run-row agda --run "https://ci.example/run/w" --commit "$C" --checker "agda 1" --reported ok --axioms none
gitq -C "$SIB" checkout -q "$SC"
expect "with the sibling back at its pin the row is current again" 0 "WROTE" --write
grep -q ':state stale' "$R/verification/receipts/t_praxis.deed" && bad "the receipt still says stale" || ok "and the receipt no longer says stale"

# The gate never reads or rewrites the home EXIT handler, so one holding quotes runs as written.
sed -i 's/^\. "\$RECEIPT_STD\/scripts\/proof-receipt.sh"$/trap "echo '"'"'it is kept'"'"'" EXIT\n&/' "$R/scripts/grade-receipt.sh"
expect "a home handler holding quotes runs as written" 0 "it is kept" --digest agda
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# A changed trusted base is earned again (§8.4): the Agda row binds the list
# its run had, and a list that differs now is refused.
TB=1 expect "a trusted base the recorded run did not bind leaves that run stale" 0 "is stale: the leg's trusted base changed" --write
expect "and without that trusted base the row is current again" 0 "WROTE" --write
(cd "$R" && TB=1 bash scripts/grade-receipt.sh --run-row agda --run "https://ci.example/run/3" --commit "$C" --checker "agda 1" --reported ok --axioms none) >"$WORK/tbrows" || bad "--run-row agda with a trusted base"
[ "$(tr -cd '|' <"$WORK/tbrows" | wc -c)" = 11 ] && ok "an Agda row with a trusted base binds its sha256 as a twelfth field" || bad "the Agda row binds no trusted base: $(cat "$WORK/tbrows")"
grep -v '^agda|' "$R/runs.rows" >>"$WORK/tbrows"
TB=1 expect "a run bound to its trusted base writes a receipt" 0 "PASS: the pinned reader" --emit-run "$WORK/tbrows" --out "$WORK/tb_praxis.deed"
grep -q '(primitive :prover agda :module "Agda.Primitive" :name "Level"' "$WORK/tb_praxis.deed" && ok "that receipt lists the trusted base" || bad "no trusted base in the receipt"
expect "the same run is refused by --emit-run once the trusted base changes" 1 "does not describe this tree" --emit-run "$WORK/tbrows" --out "$WORK/tb2_praxis.deed"

# A path a deed string cannot hold is refused, not written.
printf 'module T.Q where\n' >"$R/src/T/Q\"uote.agda"
gitq -C "$R" add -A; gitq -C "$R" commit -qm quote
QC=$(git -C "$R" rev-parse HEAD)
sed -i 's/^    rocq) printf .legs\/rocq\/T.v\\n. ;;$/    rocq) printf "legs\/rocq\/T.v\\n"; if [ -n "${QUOTE:-}" ]; then printf "src\/T\/Q\\"uote.agda\\n"; fi ;;/' "$R/scripts/grade-receipt.sh"
(cd "$R" && QUOTE=1 bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/q" --commit "$QC" --checker "rocq 1" --reported ok --axioms none) >"$WORK/qrows" 2>/dev/null
RUNS_FILE="$WORK/qrows" QUOTE=1 expect "an input path holding a double quote is refused" 1 "holds a double quote" --write
cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"

# Legs at different commits (§8.5.2): each follows its own chain, so a Rocq
# leg re-run at a later commit still counts toward PWG-2ii, not PWG-1, and the
# :source-commit stays the Agda leg's.
D=$(git -C "$R" rev-parse HEAD)
(cd "$R" && bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/d" --commit "$D" --checker "rocq 1" --reported ok --axioms none) >"$WORK/drows"
expect "current legs at different commits write a receipt" 0 "T-1  PWG-2ii" --emit-run "$WORK/drows" --out "$WORK/diff_praxis.deed"
grep -q ":source-commit \"$C\"" "$WORK/diff_praxis.deed" && ok "its :source-commit is the Agda leg's commit" || bad "the :source-commit is not the Agda leg's"
bash "$ROOT/scripts/check-proof-receipt.sh" --branch refs/heads/main --import "o/sibling=$SIB" "$WORK/diff_praxis.deed" "$R" >/dev/null 2>&1 && ok "the shared checker holds on it" || bad "the shared checker refuses the receipt with legs at different commits"

# A leg outside dependent type theory (§8.3) takes rows like any other, and
# makes its claim foundation-diverse when it is RECONCILED with a current run.
(cd "$R" && EXTRA=RECONCILED bash scripts/grade-receipt.sh --run-row isabelle --run "https://ci.example/run/i" --commit "$C" --checker "isabelle 1" --reported ok --axioms none) >"$WORK/irows" || bad "--run-row isabelle"
cat "$WORK/rows" >>"$WORK/irows"
EXTRA=RECONCILED expect "a RECONCILED Isabelle leg makes the claim foundation-diverse" 0 "T-1  PWG-1  foundation-diverse true" --emit-run "$WORK/irows" --out "$WORK/iso_praxis.deed"
grep -q '(leg :prover isabelle :route re-proved :token proven :state RECONCILED' "$WORK/iso_praxis.deed" && ok "the receipt carries the Isabelle leg" || bad "no Isabelle leg in the receipt"
EXTRA=BRIDGE-PENDING expect "an Isabelle leg that is not RECONCILED does not" 0 "T-1  PWG-1  foundation-diverse false" --emit-run "$WORK/irows" --out "$WORK/iso2_praxis.deed"
expect "a row of a prover no leg names is refused" 1 "unknown prover in row" --emit-run "$WORK/irows" --out "$WORK/iso3_praxis.deed"

# An echo's forge reference must hold its source, even when the commit is here.
grep "^agda|" "$R/runs.rows" >"$WORK/agda.rows"
X=$(gitq -C "$R" commit-tree "$C^{tree}" -m orphan)
git -C "$R" update-ref refs/pull/2/head "$X"
RUNS_FILE="$WORK/agda.rows" ECHO_ROW="$C|$D|inputs-sha256|refs/pull/9/head" expect "an echo whose reference is missing is refused, the commit being here" 1 "cannot fetch refs/pull/9/head" --write
RUNS_FILE="$WORK/agda.rows" ECHO_ROW="$C|$D|inputs-sha256|refs/pull/2/head" expect "an echo whose reference does not hold its source is refused" 1 "refs/pull/2/head does not hold commit $C" --write

# --write runs the git checks of §8.5.3 before it installs the receipt: a
# source commit off the default branch is refused there, not first in --check.
cp "$R/verification/receipts/t_praxis.deed" "$WORK/before2_praxis.deed"
gitq -C "$R" checkout -q -b side; printf 'side\n' >"$R/side.txt"; gitq -C "$R" add -A; gitq -C "$R" commit -qm side
S=$(git -C "$R" rev-parse HEAD); gitq -C "$R" checkout -q main
(cd "$R" && bash scripts/grade-receipt.sh --run-row agda --run "https://ci.example/run/s" --commit "$S" --checker "agda 1" --reported ok --axioms none) >"$WORK/srows"
RUNS_FILE="$WORK/srows" expect "--write refuses a receipt whose source is off the default branch" 1 "the git checks of PROOF-POLICY §8.5.3 failed" --write
cmp -s "$WORK/before2_praxis.deed" "$R/verification/receipts/t_praxis.deed" \
  && ok "and leaves the existing receipt as it was" || bad "a refused --write changed the receipt"

# A leading ./ in an input path hashes as the reference digest does.
a=$(cd "$R" && bash scripts/grade-receipt.sh --digest rocq)
sed -i "s|printf 'legs/rocq/T.v|printf './legs/rocq/T.v|" "$R/scripts/grade-receipt.sh"
b=$(cd "$R" && bash scripts/grade-receipt.sh --digest rocq); cp "$WORK/grade.orig" "$R/scripts/grade-receipt.sh"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "an input listed as ./path has the reference digest" || bad "./path changes the digest ($a, $b)"

# An echo that no current leg's chain uses is neither fetched nor written.
ECHO_ROW="$X1|$X2|inputs-sha256|refs/pull/77/head" expect "an echo no current chain uses is left out" 0 "WROTE" --write
grep -q "$X1" "$R/verification/receipts/t_praxis.deed" && bad "the unused echo is in the receipt" || ok "and the receipt does not carry it"
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed

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

# Run scope (receipt_run_scope): a superseded run that checked only some
# claims is listed under those claims alone.  T-3 joins T-1 as a theorem
# with the same legs; run 1 (at C) is superseded by run 9 (at N), and run 1
# of the Rocq leg is scoped to T-1.
printf '| T-3 | proven\n' >>"$R/STATUS.adoc"
printf '| T-3 | RECONCILED | RECONCILED\n' >>"$R/legs/README.adoc"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "a second theorem"
git -C "$R" fetch -q origin
N=$(git -C "$R" rev-parse HEAD)
sed 's/|current||/|superseded|replaced by run 9|/' "$WORK/rows" >"$WORK/scope.rows"
for p in agda rocq lean; do
  (cd "$R" && SECOND=1 bash scripts/grade-receipt.sh --run-row "$p" --run "https://ci.example/run/9" --commit "$N" --checker "$p 1" --reported ok --axioms none --image "$RUN_IMG") >>"$WORK/scope.rows" \
    || bad "--run-row $p at N"
done
# The lines of one leg of one claim in the receipt.
leg_of() {
  awk -v c="(claim :id \"$1\"" -v l="(leg :prover $2 " '
    index($0, "(claim :id") == 3 { inc = (index($0, c) == 3); inl = 0 }
    inc && index($0, "(leg :prover") == 5 { inl = (index($0, l) == 5) }
    inc && inl' "$R/verification/receipts/t_praxis.deed"
}
RUNS_FILE="$WORK/scope.rows" SECOND=1 expect "two theorems and a superseded run write without a scope" 0 "WROTE" --write
leg_of T-3 rocq | grep -q 'run/1"' && ok "without a scope, the superseded run is listed under every claim with its leg" || bad "the unscoped run is missing under T-3"
SC1='rocq|https://ci.example/run/1|T-1'
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" expect "a run scoped to T-1 writes" 0 "WROTE" --write
leg_of T-1 rocq | grep -q 'run/1"' && ok "the scoped run is listed under the claim it checked" || bad "the scoped run is missing under T-1"
leg_of T-3 rocq | grep -q 'run/1"' && bad "the scoped run is listed under a claim it did not check" || ok "and not under a claim it did not check"
leg_of T-3 rocq | grep -q 'run/9"' && ok "that claim keeps its current receipt" || bad "T-3 lost its current Rocq receipt"
leg_of T-3 agda | grep -q 'run/1"' && ok "a scope on one leg leaves the other legs' runs alone" || bad "the Agda run 1 is missing under T-3"
[ "$(grep -c '^  (claim :id "T-[13]" :pwg PWG-1 ' "$R/verification/receipts/t_praxis.deed")" = 2 ] && ok "a scope changes no grade: both theorems derive PWG-1" || bad "a scope moved a grade"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "scoped receipt"
git -C "$R" fetch -q origin
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" expect "--check passes on a scoped receipt" 0 "PASS: negative control" --check
# A leg whose only run is scoped to another claim has no receipt under this
# one: the leg is written without receipts, and the reader accepts it.
{ grep '^agda|https://ci.example/run/9|' "$WORK/scope.rows"; grep '^rocq|https://ci.example/run/1|' "$WORK/scope.rows"; } >"$WORK/scope-only.rows"
RUNS_FILE="$WORK/scope-only.rows" SECOND=1 SCOPE="$SC1" expect "a leg left with no receipt under a claim writes, and the reader accepts it" 0 "WROTE" --write
leg_of T-3 rocq | grep -q '(receipt' && bad "T-3's Rocq leg lists a run scoped away from it" || ok "that leg is written with no receipt"
leg_of T-1 rocq | grep -q 'run/1"' && ok "the claim the run checked still lists it" || bad "T-1 lost its scoped Rocq run"
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/9|T-1' expect "a scope on a current run is refused" 1 "a current run checks every claim with its leg" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/7|T-1' expect "a scope on a run the ledger lacks is refused" 1 "names no run of the rocq ledger" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/1|T-9' expect "a scope naming an unknown claim is refused" 1 "T-9, which is no theorem claim" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/1|T-2' expect "a scope naming a demonstration is refused" 1 "T-2, which is no theorem claim" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/1| ' expect "a scope naming no claim is refused" 1 "a run scope names no claim" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='rocq|https://ci.example/run/1' expect "a scope with two fields is refused" 1 "a run scope needs 3 fields" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1"$'\n'"$SC1" expect "two scopes of one run are refused" 1 "a run has two run scopes" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE='coq|https://ci.example/run/1|T-1' expect "a scope naming an unknown prover is refused" 1 "a run scope names an unknown prover" --check
RUNS_FILE="$WORK/scope.rows" SECOND=1 expect "dropping the scope makes the receipt stale for --check" 1 "does not match the tree and the ledgers" --check

# A claim with no Agda proof yet, and a recheck leg the kernel accepted whose
# statement is not reconciled (§2.2: the token and the state are separate).
# T-4 joins as a theorem claim; its rows are given by PENDING.
printf '| T-4 | open\n' >>"$R/STATUS.adoc"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "a claim with no Agda proof"
git -C "$R" fetch -q origin
P1='open|theorem|unavailable||re-proved|LEAN-CHECKED|Rocq cannot import the statement|'
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a claim with no Agda proof and a LEAN-CHECKED leg writes, and the reader accepts it" 0 "WROTE" --write
grep -q '^  (claim :id "T-4" :pwg ungraded ' "$R/verification/receipts/t_praxis.deed" && ok "the claim with no Agda proof is ungraded" || bad "T-4 is not ungraded"
[ "$(leg_of T-4 agda)" = '    (leg :prover agda :route source :token open :state AGDA-PENDING)' ] && ok "its Agda leg is AGDA-PENDING and lists no run" || bad "T-4's Agda leg is not a bare AGDA-PENDING leg: $(leg_of T-4 agda | head -2)"
leg_of T-4 lean | grep -q ':token proven :state LEAN-CHECKED' && ok "a LEAN-CHECKED leg is proven, not open" || bad "T-4's Lean leg is not proven and LEAN-CHECKED"
leg_of T-4 lean | grep -q 'run/9"' && ok "and it carries the Lean leg's current receipt" || bad "T-4's Lean leg lost its receipt"
[ "$(grep -c '^  (claim :id "T-[13]" :pwg PWG-1 ' "$R/verification/receipts/t_praxis.deed")" = 2 ] && ok "the other claims keep their grade" || bad "a pending claim moved another claim's grade"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "receipt with a pending claim"
git -C "$R" fetch -q origin
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "--check passes on it" 0 "PASS: negative control" --check
P2='proven|theorem|re-proved|COQ-CHECKED|re-proved|LEAN-CHECKED||'
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P2" expect "a proven claim with two checked, unreconciled legs writes" 0 "WROTE" --write
grep -q '^  (claim :id "T-4" :pwg PWG-3 ' "$R/verification/receipts/t_praxis.deed" && ok "unreconciled legs count toward no grade: PWG-3" || bad "T-4 is not PWG-3 with two unreconciled legs"
leg_of T-4 rocq | grep -q ':token proven :state COQ-CHECKED' && ok "a COQ-CHECKED leg is proven" || bad "T-4's Rocq leg is not proven and COQ-CHECKED"
leg_of T-4 agda | grep -q ':state AGDA-VERIFIED' && ok "a proven claim's Agda leg stays AGDA-VERIFIED" || bad "T-4's Agda leg is not AGDA-VERIFIED"
P3='open|theorem|unavailable||re-proved|QUARANTINED|Rocq cannot import the statement|'
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P3" expect "a quarantined leg writes" 0 "WROTE" --write
leg_of T-4 lean | grep -q ':token open :state QUARANTINED' && ok "a leg the kernel did not accept stays open" || bad "a QUARANTINED leg is not open"
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING='open|theorem|unavailable||re-proved|COQ-CHECKED|r|' expect "COQ-CHECKED on a Lean leg is refused" 1 "COQ-CHECKED is the state of a Rocq leg" --write
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING='open|theorem|re-proved|LEAN-CHECKED|unavailable|||r' expect "LEAN-CHECKED on a Rocq leg is refused" 1 "LEAN-CHECKED is the state of a Lean leg" --write
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed

# :beholding-chora (RECEIPT_BEHOLDING_CHORA): written as given, after
# :canonical-name, and refused when it is not a #u8 or #uuid literal.
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" BEHOLDING='#u8"chora:estate/github.com/o"' expect "a receipt with a :beholding-chora writes, and the reader accepts it" 0 "WROTE" --write
grep -A1 '^  :canonical-name ' "$R/verification/receipts/t_praxis.deed" | grep -qxF '  :beholding-chora #u8"chora:estate/github.com/o"' && ok ":beholding-chora follows :canonical-name" || bad "no :beholding-chora after :canonical-name"
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" BEHOLDING='chora:estate' expect "a :beholding-chora that is no id literal is refused" 1 "RECEIPT_BEHOLDING_CHORA must be" --write
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" BEHOLDING='#u5"x"' expect "a #u5 :beholding-chora is refused" 1 "RECEIPT_BEHOLDING_CHORA must be" --write
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "without it the committed receipt still checks" 1 "does not match the tree and the ledgers" --check
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "and the committed one, written without it, checks" 0 "PASS: negative control" --check

# Derived states (§8.4).  `stale` is never typed.
awk -F'|' 'BEGIN{OFS="|"} $1=="rocq" && $8=="current"{$8="stale"; $9="typed by hand"} {print}' "$WORK/scope.rows" >"$WORK/typedstale.rows"
RUNS_FILE="$WORK/typedstale.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a row typed stale is refused" 1 "stale is derived from the tree, never typed" --check
# Several rows of one leg typed current: the newest by ancestry stays current,
# and each earlier one is superseded by it, with no reason typed.
awk -F'|' 'BEGIN{OFS="|"} $1=="rocq" && $2=="https://ci.example/run/1"{$8="current"; $9=""} {print}' "$WORK/scope.rows" >"$WORK/multi.rows"
[ "$(awk -F'|' '$1=="rocq" && $8=="current"' "$WORK/multi.rows" | wc -l)" = 2 ] && ok "the fixture types two Rocq rows current" || bad "the fixture has not two current Rocq rows"
RUNS_FILE="$WORK/multi.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "two current rows of one leg write" 0 "WROTE" --write
leg_of T-1 rocq | grep -A6 'run/1"' | grep -q ':reason "replaced by the later run https://ci.example/run/9"' && ok "the earlier run is derived superseded by the later one" || bad "run 1 is not derived superseded: $(leg_of T-1 rocq | grep -A5 'run/1"')"
[ "$(leg_of T-1 rocq | grep -c ':state current')" = 1 ] && ok "and the leg keeps exactly one current receipt" || bad "the Rocq leg has not exactly one current receipt"
cmp -s "$R/verification/receipts/t_praxis.deed" <(git -C "$R" show HEAD:verification/receipts/t_praxis.deed) \
  && bad "the derived reason was expected to differ from the typed one" || ok "only the reason differs from the hand-typed ledger"
# The order of the rows in the ledger does not decide which is newest.
{ grep -v '^rocq|https://ci.example/run/1|' "$WORK/multi.rows"; grep '^rocq|https://ci.example/run/1|' "$WORK/multi.rows"; } >"$WORK/multi-reordered.rows"
RUNS_FILE="$WORK/multi-reordered.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "with the older row last, the newest is still chosen by ancestry" 0 "WROTE" --write
leg_of T-1 rocq | grep -A8 'run/9"' | grep -q ':state current' && ok "the later run stays current" || bad "run 9 is not current after reordering"
# Commits git cannot order are refused.
UNREL=$(gitq -C "$R" commit-tree "HEAD^{tree}" -m "unrelated root")
awk -F'|' -v u="$UNREL" 'BEGIN{OFS="|"} $1=="rocq" && $2=="https://ci.example/run/1"{$3=u} {print}' "$WORK/multi.rows" >"$WORK/unordered.rows"
RUNS_FILE="$WORK/unordered.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "current rows at commits git cannot order are refused" 1 "neither of" --write
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed
RUNS_FILE="$WORK/scope.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "and the committed receipt still checks" 0 "PASS: negative control" --check

# A later run typed regressed outranks an earlier pass: the leg is left with
# no current receipt, and the pass is superseded by the failure.
LATER=$(git -C "$R" rev-parse HEAD)
{ cat "$WORK/scope.rows"; awk -F'|' -v c="$LATER" 'BEGIN{OFS="|"} $1=="rocq" && $8=="current"{print $1,"https://ci.example/run/10",c,$4,$5,$6,"the gate failed","regressed","the Rocq gate failed at this commit",""}' "$WORK/scope.rows"; } >"$WORK/regressed.rows"
RUNS_FILE="$WORK/regressed.rows" SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a later regressed run writes" 0 "WROTE" --write
leg_of T-1 rocq | grep -q ':state current' && bad "the Rocq leg kept a current receipt after a later regression" || ok "after a later regression the leg has no current receipt"
leg_of T-1 rocq | grep -A6 'run/9"' | grep -q ':reason "replaced by the later run https://ci.example/run/10, which regressed"' && ok "and the earlier pass is superseded by the failure" || bad "run 9 is not superseded by the regression"
grep -q '^  (claim :id "T-1" :pwg PWG-1 ' "$R/verification/receipts/t_praxis.deed" && bad "T-1 kept PWG-1 without a current Rocq receipt" || ok "the grade falls with it"
gitq -C "$R" checkout -q -- verification/receipts/t_praxis.deed

# The run ledger as a data file (RECEIPT_LEDGER): the same rows give the same
# receipt, the file is append-only against the default branch, and --record
# is the one call that adds a run.
cp "$WORK/scope.rows" "$R/runs.ledger"
gitq -C "$R" add -A; gitq -C "$R" commit -qm "the run ledger as a data file"
git -C "$R" fetch -q origin
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a ledger file gives the receipt the hook gave" 0 "PASS: negative control" --check
LEDGER=runs.ledger RUNS_FILE=x SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a ledger file and no receipt_runs is accepted" 0 "PASS: negative control" --check
sed -i 's/^\[ -z "\${LEDGER:-}" \] || { RECEIPT_LEDGER="\$LEDGER"; unset -f receipt_runs; }$/[ -z "${LEDGER:-}" ] || RECEIPT_LEDGER="$LEDGER"/' "$R/scripts/grade-receipt.sh"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a ledger file beside receipt_runs is refused" 1 "the run ledger has one source" --check
gitq -C "$R" checkout -q -- scripts/grade-receipt.sh
{ printf '# SPDX-License-Identifier: CC0-1.0\n\n'; cat "$WORK/scope.rows"; } >"$R/runs.ledger"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "comment and empty lines are not rows" 0 "PASS: negative control" --check
sed '1s/|rocq 1|/|rocq 2|/; 1s/|agda 1|/|agda 2|/; 1s/|lean 1|/|lean 2|/' "$WORK/scope.rows" >"$R/runs.ledger"
cmp -s "$WORK/scope.rows" "$R/runs.ledger" && bad "the fixture did not edit a ledger row" || ok "the fixture edits the first ledger row"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "an edited row is refused: the ledger is append-only" 1 "is append-only: row 1 of main was changed, moved or removed" --check
sed '1d' "$WORK/scope.rows" >"$R/runs.ledger"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "a removed row is refused" 1 "is append-only: row 1 of main was changed, moved or removed" --check
sed '1!G;h;$!d' "$WORK/scope.rows" >"$R/runs.ledger"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "reordered rows are refused" 1 "is append-only" --check
gitq -C "$R" checkout -q -- runs.ledger
# --record: a new run of the Rocq leg at the head of main.
HEADC=$(git -C "$R" rev-parse HEAD)
(cd "$R" && LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" bash scripts/grade-receipt.sh --run-row rocq --run "https://ci.example/run/11" --commit "$HEADC" --checker "rocq 1" --reported ok --axioms none --image "$RUN_IMG") >"$WORK/newrun.rows" 2>"$WORK/newrun.err" || bad "--run-row with a ledger file: $(cat "$WORK/newrun.err")"
before=$(grep -c . "$R/runs.ledger")
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "--record writes the receipt and appends the run" 0 "RECORDED 1 row(s) in runs.ledger" --record "$WORK/newrun.rows"
[ "$(grep -c . "$R/runs.ledger")" = $((before + 1)) ] && ok "the ledger file gained exactly one row" || bad "the ledger file has $(grep -c . "$R/runs.ledger") rows, want $((before + 1))"
[ "$(tail -n1 "$R/runs.ledger")" = "$(cat "$WORK/newrun.rows")" ] && ok "and it is the recorded row, at the end" || bad "the last ledger row is not the recorded one"
leg_of T-1 rocq | grep -A6 'run/9"' | grep -q ':reason "replaced by the later run https://ci.example/run/11"' && ok "the run it replaces is derived superseded" || bad "run 9 is not superseded by run 11"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "the recorded receipt checks" 0 "PASS: negative control" --check
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "recording the same run twice is refused" 1 "already holds this run of the rocq leg" --record "$WORK/newrun.rows"
[ "$(grep -c . "$R/runs.ledger")" = $((before + 1)) ] && ok "and a refused --record appends nothing" || bad "a refused --record changed the ledger"
# A run that does not describe the tree is refused, and nothing is written.
sed 's|run/11|run/12|' "$WORK/newrun.rows" >"$WORK/newrun2.rows"
printf '(* moved *)\n' >>"$R/legs/rocq/T.v"
cp "$R/verification/receipts/t_praxis.deed" "$WORK/before-record.deed"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "--record refuses a run that does not describe the tree" 1 "the rocq run being recorded does not describe this tree" --record "$WORK/newrun2.rows"
[ "$(grep -c . "$R/runs.ledger")" = $((before + 1)) ] && cmp -s "$R/verification/receipts/t_praxis.deed" "$WORK/before-record.deed" && ok "and neither the ledger nor the receipt changed" || bad "a refused --record wrote something"
gitq -C "$R" checkout -q -- legs/rocq/T.v
awk -F'|' 'BEGIN{OFS="|"} {$8="superseded"; $9="typed"; print}' "$WORK/newrun2.rows" >"$WORK/newrun3.rows"
LEDGER=runs.ledger SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "--record takes only rows typed current" 1 "a row given to --record must be current" --record "$WORK/newrun3.rows"
SECOND=1 SCOPE="$SC1" PENDING="$P1" expect "--record without a ledger file is refused" 1 "the home script must set RECEIPT_LEDGER" --record "$WORK/newrun2.rows"
gitq -C "$R" checkout -q -- runs.ledger verification/receipts/t_praxis.deed

echo "proof-receipt-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
