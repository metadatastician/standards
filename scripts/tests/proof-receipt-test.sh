#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Proves scripts/proof-receipt.js writes and checks proof receipts as
# PROOF-POLICY §8.5 says: on a scratch home repository that imports a pinned
# sibling, with a squash merge carried by an echo, the written receipt is
# accepted by the reader at PWG-1 and `check` passes; and each broken source,
# tree or receipt is refused for its own reason.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/scripts/proof-receipt.js"
READER="$ROOT/1-formats/deed/tools/deed_lint.js"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
command -v bun >/dev/null || { echo "cannot run: bun is not installed"; exit 2; }
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
# expect LABEL EXIT FRAGMENT|- ARGS... (runs the tool in the home repository)
expect() {
  local label=$1 want_rc=$2 want_msg=$3; shift 3
  local out rc=0
  out=$(cd "$R" && bun "$TOOL" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ]; then bad "$label (exit $rc, want $want_rc)"; printf '%s\n' "$out" | sed 's/^/        /' | head -20; return; fi
  if [ "$want_msg" != - ] && ! grep -qF -- "$want_msg" <<<"$out"; then bad "$label (no \"$want_msg\")"; printf '%s\n' "$out" | sed 's/^/        /' | head -20; return; fi
  ok "$label"
}
gitinit() { git init -q -b main "$1"; git -C "$1" config user.email t@example.invalid; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }

# ── The sibling: a library the home proofs import at a pin ───────────────────
SIB="$WORK/sib"; gitinit "$SIB"
mkdir -p "$SIB/src/Sib" "$SIB/legs/rocq"
printf 'module Sib.Base where\nopen import Agda.Builtin.Nat\n' >"$SIB/src/Sib/Base.agda"
printf 'module Sib.Unused where\n' >"$SIB/src/Sib/Unused.agda"
printf 'Definition one := 1.\n' >"$SIB/legs/rocq/Sib.v"
git -C "$SIB" add -A; git -C "$SIB" commit -qm sib
P=$(git -C "$SIB" rev-parse HEAD)
# A later sibling commit, which the home pin file does not name.
printf -- "-- later\n" >>"$SIB/src/Sib/Base.agda"; git -C "$SIB" commit -qam later
P2=$(git -C "$SIB" rev-parse HEAD)

# ── The home repository ─────────────────────────────────────────────────────
R="$WORK/home"; gitinit "$R"
mkdir -p "$R/src/H" "$R/legs/rocq" "$R/legs/lean/H" "$R/scripts" "$R/tests/reject" "$R/_build/deps"
git clone -q "$SIB" "$R/_build/deps/sib"
printf '_build/\n' >"$R/.gitignore"
printf 'SIB_COMMIT="${SIB_COMMIT:-%s}"\n' "$P" >"$R/scripts/pin.sh"
cat >"$R/src/H/All.agda" <<'EOF'
module H.All where
-- import H.Ghost   (a comment: not an import)
{- import H.Ghost
   {- nested -} import H.Ghost -}
open import Sib.Base
open import H.Lem using (lem)
EOF
printf 'module H.Lem where\nlem : Set₁\nlem = Set\n' >"$R/src/H/Lem.agda"
printf 'module H.Unused where\n' >"$R/src/H/Unused.agda"
printf 'module Bad where\nopen import H.Lem\nbad : lem\nbad = bad\n' >"$R/tests/reject/Bad.agda"
printf 'Require Sib.\n' >"$R/legs/rocq/Main.v"
printf 'import H.Lemma\n' >"$R/legs/lean/Main.lean"
printf 'theorem t : True := trivial\n' >"$R/legs/lean/H/Lemma.lean"
printf 'name = "h"\n' >"$R/legs/lean/lakefile.toml"
printf 'readme\n' >"$R/README.adoc"
git -C "$R" add -A; git -C "$R" commit -qm base
# A pull request: the runs are earned on S, then a docs commit; a squash makes I.
git -C "$R" checkout -q -b pr
printf -- '-- proof\n' >>"$R/src/H/Lem.agda"; git -C "$R" commit -qam proof
S=$(git -C "$R" rev-parse HEAD)
printf 'docs\n' >>"$R/README.adoc"; git -C "$R" commit -qam docs
git -C "$R" checkout -q main
git -C "$R" merge -q --squash pr >/dev/null 2>&1; git -C "$R" commit -qm squash
I=$(git -C "$R" rev-parse HEAD)

INV='agda --safe --without-K --cubical-compatible -i src -i _build/deps/sib/src src/H/All.agda'
# source FILE [EXTRA-TOML]: the base source, with the lines of EXTRA appended.
source_toml() {
  cat >"$1" <<EOF
repository = "o/home"
receipt = "verification/receipts/proof_praxis.deed"
canonical-name = "home-proof-receipt"
spdx = "CC-BY-SA-4.0"
copyright = "2026 Test"
header = ["A scratch receipt."]

[[trusted-base]]
prover = "agda"
module = "Agda.Primitive"
name = "Level"
binding = "BUILTIN LEVEL"

[inputs.agda]
roots = ["src/H/All.agda"]
include = ["src"]
paths = ["scripts/pin.sh"]

[[inputs.agda.import]]
repository = "o/sib"
commit = "$P"
checkout = "_build/deps/sib"
include = ["src"]
pin = { file = "scripts/pin.sh", pattern = 'SIB_COMMIT:-([0-9a-f]{40})' }

[inputs.rocq]
paths = ["legs/rocq/*.v", "scripts/pin.sh"]

[[inputs.rocq.import]]
repository = "o/sib"
commit = "$P"
checkout = "_build/deps/sib"
paths = ["legs/rocq/Sib.v"]

[inputs.lean]
paths = ["legs/lean/**/*.lean", "legs/lean/lakefile.{lean,toml}"]

[[claim]]
id = "T-1"
token = "proven"
rocq = { route = "re-proved", state = "RECONCILED" }
lean = { route = "re-proved", state = "RECONCILED" }

[[claim]]
id = "T-2"
token = "proven"
rocq = { route = "re-proved", state = "RECONCILED" }
lean = { route = "unavailable", reason = "not re-proved yet" }

[[run]]
prover = "agda"
run = "https://ci.example/runs/2"
commit = "$S"
checker = "agda 2.6.4.3"
invocation = "$INV"
reported = "PASS"
state = "current"

[[run]]
prover = "agda"
run = "https://ci.example/runs/1"
commit = "$S"
checker = "agda 2.6.4.3"
invocation = "agda --safe --without-K src/H/All.agda"
state = "superseded"
reason = "before --cubical-compatible"

[[run]]
prover = "rocq"
run = "https://ci.example/runs/2"
commit = "$S"
checker = "coq 8.18.0"
invocation = "coqc legs/rocq/Main.v"
state = "current"

[[run]]
prover = "lean"
run = "https://ci.example/runs/2"
commit = "$S"
checker = "lean 4.24.0"
invocation = "lake build"
state = "current"

[[echo]]
source = "$S"
image = "$I"
witness = "inputs-sha256"
EOF
  [ -z "${2:-}" ] || printf '%s\n' "$2" >>"$1"
}
SRC="$R/verification/receipts/proof-receipt.toml"
RECEIPT="$R/verification/receipts/proof_praxis.deed"
mkdir -p "$R/verification/receipts"
source_toml "$SRC"

echo "proof-receipt.js: write"
expect "writes a receipt the reader accepts" 0 "T-1  PWG-1" write "$SRC"
json=$(bun "$READER" --proof-receipt-json "$RECEIPT" 2>&1)
if jq -e '.claims[0].pwg == "PWG-1" and .claims[1].pwg == "PWG-2i" and .source_commit == "'"$I"'"' <<<"$json" >/dev/null 2>&1; then
  ok "the reader derives PWG-1 and PWG-2i, and the source-commit is the squash commit"
else bad "the reader's grades or source-commit differ"; printf '%s\n' "$json" | head -5; fi
paths=$(jq -r '[.claims[0].legs[0].receipts[0].inputs_manifest[].path] | join(" ")' <<<"$json")
if [ "$paths" = "scripts/pin.sh src/H/All.agda src/H/Lem.agda" ]; then ok "the Agda manifest is the cone and the pin file, and no commented import"
else bad "the Agda manifest is \"$paths\""; fi
ipaths=$(jq -r '[.claims[0].legs[0].receipts[0].imports[0].files[].path] | join(" ")' <<<"$json")
if [ "$ipaths" = "src/Sib/Base.agda" ]; then ok "the sibling's import lists its cone files only"
else bad "the sibling import lists \"$ipaths\""; fi
if jq -e '.claims[0].legs[1].receipts[0].imports[0].files[0].path == "legs/rocq/Sib.v"' <<<"$json" >/dev/null; then ok "a Rocq leg records its import too"
else bad "the Rocq leg's import is missing"; fi
if jq -e '.echoes[0].inputs | keys == ["agda","lean","rocq"]' <<<"$json" >/dev/null; then ok "the echo carries a digest per prover"
else bad "the echo digests are wrong"; fi
git -C "$R" add -A; git -C "$R" commit -qm receipt

echo "proof-receipt.js: check"
expect "check passes on the written receipt" 0 "every check holds" check "$SRC"
cp "$RECEIPT" "$WORK/good"
sed -i 's/:pwg PWG-2i/:pwg PWG-2ii/' "$RECEIPT"
expect "check refuses a hand-edited receipt" 1 "is not what the source and the tree give" check "$SRC"
cp "$WORK/good" "$RECEIPT"
printf -- '-- edit\n' >>"$R/src/H/Lem.agda"
expect "check refuses an input changed in the working tree" 1 "inputs differ from HEAD in the working tree" check "$SRC"
git -C "$R" commit -qam change
expect "check refuses a receipt whose inputs changed since its run" 1 "the inputs changed since that run" check "$SRC"
git -C "$R" reset -q --hard HEAD~1

echo "proof-receipt.js: row and --runs"
row=$(cd "$R" && bun "$TOOL" row --prover agda --run https://ci.example/runs/3 --commit "$I" --checker "agda 2.6.4.3" --invocation "$INV" "$SRC" 2>&1)
d=$(cd "$R" && bun "$TOOL" digest --commit "$I" "$SRC" agda)
if grep -qxF "inputs-sha256 = \"$d\"" <<<"$row"; then ok "row prints the run with its derived digest"; else bad "row: $row"; fi
printf '%s\n' "$row" >"$WORK/runs.toml"
expect "--runs makes the new run current" 0 - write --runs "$WORK/runs.toml" --out "$WORK/next_praxis.deed" "$SRC"
if grep -qF 'replaced by the later run https://ci.example/runs/3' "$WORK/next_praxis.deed"; then ok "--runs supersedes the earlier current run"; else bad "the earlier run was not superseded"; fi

echo "proof-receipt.js: refusals"
refuse() { # LABEL FRAGMENT EXTRA-TOML [SED]
  source_toml "$WORK/s.toml" "$3"
  [ -z "${4:-}" ] || sed -i "$4" "$WORK/s.toml"
  expect "$1" 1 "$2" write --out "$WORK/x_praxis.deed" "$WORK/s.toml"
}
refuse "an unknown key" 'unknown key "colour"' 'colour = "red"'
refuse "a claim without its lean leg" 'has no lean leg' '' '/^lean = { route = "unavailable"/d'
refuse "two current runs of one leg" 'more than one current run' "$(printf '[[run]]\nprover = "lean"\nrun = "x"\ncommit = "%s"\nchecker = "c"\ninvocation = "i"\nstate = "current"' "$S")"
refuse "a typed digest that is false" 'is not the digest at' '' "/^run = \"https:\/\/ci.example\/runs\/2\"/a inputs-sha256 = \"$(printf '0%.0s' {1..64})\""
refuse "a pin that differs from the pin file" 'but the source says' '' "s/^commit = \"$P\"/commit = \"$P2\"/"
refuse "a pin file outside the input set" 'must be in the agda input set' '' '/^paths = \["scripts\/pin.sh"\]/d'
refuse "a glob that matches nothing" 'matches no file' '' 's#legs/lean/lakefile.{lean,toml}#legs/lean/nothing.toml#'
refuse "a forged echo (inputs differ)" 'the agda inputs differ' '' "s/^image = \"$I\"/image = \"$(git -C "$R" rev-parse "$I~1")\"/"
printf 'module H.All where\nopen import H.Missing\n' >"$R/src/H/All.agda"; git -C "$R" commit -qam missing
expect "a module in no include directory" 1 "is in no include directory" inputs "$SRC" agda
git -C "$R" reset -q --hard HEAD~1

echo "proof-receipt.js: controls and tree echoes"
CTRL=$(printf '[[claim.control]]\npath = "tests/reject/Bad.agda"\nprover = "agda"\n')
source_toml "$WORK/c.toml" ""
# Put the control under T-2 (the last claim) and its run at the end.
awk -v c="$CTRL" '/^\[\[run\]\]/ && !done {print c; print ""; done=1} {print}' "$WORK/c.toml" >"$WORK/c2.toml"
printf '[[run]]\nprover = "agda"\nrun = "https://ci.example/runs/2"\ncommit = "%s"\nchecker = "agda 2.6.4.3"\ninvocation = "agda --safe Bad.agda"\ncontrol = "tests/reject/Bad.agda"\nstate = "current"\n' "$S" >>"$WORK/c2.toml"
expect "a negative control is written" 0 - write --out "$WORK/c_praxis.deed" "$WORK/c2.toml"
if bun "$READER" --proof-receipt-json "$WORK/c_praxis.deed" | jq -e '.claims[1].controls[0].receipts[0].inputs_manifest | map(.path) | index("tests/reject/Bad.agda") != null' >/dev/null; then
  ok "the control's manifest holds the refused file"; else bad "the control's manifest lacks the refused file"; fi
source_toml "$WORK/t.toml" "" ; sed -i 's/^witness = "inputs-sha256"/witness = "tree-sha256"/' "$WORK/t.toml"
expect "a tree echo across a docs change is refused" 1 "the trees differ" write --out "$WORK/t_praxis.deed" "$WORK/t.toml"

echo "proof-receipt.js: usage"
expect "exits 2 on bad usage" 2 usage write
expect "exits 2 on an unknown option" 2 "unknown option" write --nope "$SRC"

echo "proof-receipt: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
