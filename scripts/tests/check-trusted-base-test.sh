#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# Regression test for scripts/check-trusted-base.sh — exercises the
# `.trusted-base-ignore` path-fragment exemption mechanism plus the
# existing inline-annotation and proof-debt enumeration paths.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-trusted-base.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FATAL: cannot locate $SCRIPT" >&2
  exit 2
fi

PASS=0
FAIL=0

run_case() {
  local name="$1"; shift
  local expected_exit="$1"; shift
  local expected_substr="$1"; shift
  local setup_fn="$1"; shift

  local tmp
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    "$setup_fn"
  )
  set +e
  local out
  out="$(cd "$tmp" && bash "$SCRIPT" . 2>&1)"
  local actual_exit=$?
  set -e

  local ok=true
  if [[ "$actual_exit" -ne "$expected_exit" ]]; then ok=false; fi
  if [[ -n "$expected_substr" && "$out" != *"$expected_substr"* ]]; then ok=false; fi

  if $ok; then
    echo "ok   $name"
    PASS=$((PASS+1))
  else
    echo "FAIL $name (exit=$actual_exit, expected=$expected_exit)"
    echo "---- output ----"
    echo "$out"
    echo "----------------"
    FAIL=$((FAIL+1))
  fi
  rm -rf "$tmp"
}

# run_case_env <name> <expected-exit> <expected-substr> <setup-fn> <env-assignment>
# Same as run_case, with one environment assignment applied to the checker
# invocation (used to exercise the extended-tier modes).
run_case_env() {
  local name="$1"; shift
  local expected_exit="$1"; shift
  local expected_substr="$1"; shift
  local setup_fn="$1"; shift
  local env_assign="$1"; shift

  local tmp
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    "$setup_fn"
  )
  set +e
  local out
  out="$(cd "$tmp" && env "$env_assign" bash "$SCRIPT" . 2>&1)"
  local actual_exit=$?
  set -e

  local ok=true
  if [[ "$actual_exit" -ne "$expected_exit" ]]; then ok=false; fi
  if [[ -n "$expected_substr" && "$out" != *"$expected_substr"* ]]; then ok=false; fi

  if $ok; then
    echo "ok   $name"
    PASS=$((PASS+1))
  else
    echo "FAIL $name (exit=$actual_exit, expected=$expected_exit)"
    echo "---- output ----"
    echo "$out"
    echo "----------------"
    FAIL=$((FAIL+1))
  fi
  rm -rf "$tmp"
}

# Each setup creates a fresh fixture tree at $PWD (the tmpdir).

setup_marker_no_docs() {
  mkdir -p src
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
partial
foo : Int -> Int
foo x = x
EOF
}

setup_marker_with_inline_trusted() {
  mkdir -p src docs
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
-- TRUSTED: documented exception per local policy.
partial
foo : Int -> Int
foo x = x
EOF
  # Inline annotations still require a proof-debt index per the original
  # script's contract; the empty doc satisfies that.
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Inline annotations only.)
EOF
}

setup_marker_with_proof_debt() {
  mkdir -p src docs
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
partial
foo : Int -> Int
foo x = x
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
See src/Foo.idr:3 — documented partial marker.
EOF
}

setup_marker_with_ignore_exact() {
  mkdir -p test/fixtures
  cat > test/fixtures/admitted.v <<'EOF'
Theorem foo : True.
Admitted.
EOF
  cat > .trusted-base-ignore <<'EOF'
# Test fixtures: deliberately contain the patterns under test.
test/fixtures/
EOF
}

setup_marker_with_ignore_substring() {
  mkdir -p test/soundness/fixtures/code_safety
  cat > test/soundness/fixtures/code_safety/admitted.v <<'EOF'
Theorem foo : True.
Admitted.
EOF
  cat > .trusted-base-ignore <<'EOF'
# Scanner fixtures - intentional.
fixtures/code_safety
EOF
}

setup_ignore_comments_only_still_fails() {
  mkdir -p src docs
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
partial
foo : Int -> Int
foo x = x
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Empty.)
EOF
  cat > .trusted-base-ignore <<'EOF'
# only comments here
# nothing real
EOF
}

setup_ignore_does_not_match() {
  mkdir -p src docs
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
partial
foo : Int -> Int
foo x = x
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Empty.)
EOF
  cat > .trusted-base-ignore <<'EOF'
# Pattern that does not match.
test/fixtures/
EOF
}

setup_mixed_exempt_and_documented() {
  mkdir -p src test/fixtures docs
  cat > src/Foo.idr <<'EOF'
module Foo
%default total
partial
foo : Int -> Int
foo x = x
EOF
  cat > test/fixtures/bar.v <<'EOF'
Theorem bar : True.
Admitted.
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
src/Foo.idr:3 — documented.
EOF
  cat > .trusted-base-ignore <<'EOF'
# Exempt fixtures.
test/fixtures/
EOF
}

setup_coq_multiline_comments_only() {
  mkdir -p formal
  cat > formal/Commentary.v <<'EOF'
(** A documentation block may discuss old proof state.
    Admitted markers in prior revisions are not executable here.
    (* Nested comments may also mention:
       admit.
    *)
    Axiom references in prose are not declarations. *)
Theorem closed : True.
Proof. exact I. Qed.
EOF
}

setup_coq_comment_then_real_admitted() {
  mkdir -p formal docs
  cat > formal/ActualDebt.v <<'EOF'
(* Admitted. inside a comment must not count. *)
Theorem open_obligation : True.
Admitted.
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Intentionally empty: the real marker must fail this positive control.)
EOF
}

setup_coq_string_delimiters_then_real_marker() {
  mkdir -p formal docs
  cat > formal/StringDelimiter.v <<'EOF'
From Coq Require Import Strings.String.
Definition opening_delimiter : string := "(* not a comment".
Definition escaped_quote : string := "text "" (* still a string".
Definition multiline_delimiters : string := "first line
(* neither opens a comment
nor does this close one *)
last line".
(* A quoted delimiter inside a real comment must not change its depth:
   "(*"
*)
Axiom string_delimiters_do_not_hide_this : True.
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Intentionally empty: a string delimiter must not hide the real axiom.)
EOF
}

setup_coq_unterminated_string() {
  mkdir -p formal docs
  cat > formal/UnterminatedString.v <<'EOF'
From Coq Require Import Strings.String.
Definition malformed : string := "this never closes
Admitted.
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Intentionally empty: malformed input must fail closed.)
EOF
}

setup_coq_leading_comment_then_real_marker() {
  mkdir -p formal docs
  cat > formal/LeadingComment.v <<'EOF'
(* explanatory prefix *) Admitted.
EOF
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Intentionally empty: a leading comment must not hide the real marker.)
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 2026-10-30 widening — extended-tier fixtures.
#
# The governing constraint for every case below: a repository whose proofs are
# fine must NOT be red-boarded by the act of widening the detector. So there are
# two families of test here — "detected" and "deliberately not detected" — and
# the second family is as load-bearing as the first.
# ─────────────────────────────────────────────────────────────────────────────

setup_agda_terminating_undocumented() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
}

setup_agda_terminating_justified() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where

-- JUSTIFIED: the recursion is structurally decreasing on the third argument;
-- Agda's checker cannot see through the `with` abstraction, but every call
-- passes a smaller fuel value (see the argument below).
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
}

setup_agda_terminating_in_block_comment() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where

{- A note about proof state:
   {-# TERMINATING #-}
   was used here until 2026-05; the current definition passes the checker. -}
total : Nat -> Nat
total n = n
EOF
}

setup_agda_unsound_flags() {
  mkdir -p proofs
  cat > proofs/Bad.agda <<'EOF'
module Bad where
{-# OPTIONS --type-in-type #-}
{-# OPTIONS --allow-unsolved-metas #-}
EOF
}

setup_agda_hole() {
  mkdir -p proofs
  cat > proofs/Hole.agda <<'EOF'
module Hole where
answer : Nat
answer = {!!}
EOF
}

setup_agda_multiline_pragma() {
  mkdir -p proofs
  cat > proofs/Bad.agda <<'EOF'
module Bad where
{-# OPTIONS
  --without-K
  --type-in-type
#-} -- {!!} is a comment
EOF
}

setup_lean_implemented_by() {
  mkdir -p formal
  cat > formal/Fast.lean <<'EOF'
@[implemented_by fastAdd] def add (a b : Nat) : Nat := a + b
EOF
}

setup_lean_native_decide_in_comment() {
  mkdir -p formal
  cat > formal/Doc.lean <<'EOF'
/- This module explains why `native_decide` is a trust expansion:
   it makes the kernel accept a computation performed by the compiler. -/
theorem t : True := by trivial
EOF
}

setup_lean_native_decide_real() {
  mkdir -p formal
  cat > formal/Ev.lean <<'EOF'
theorem big : (10 ^ 10) > 1 := by native_decide
EOF
}

setup_agda_pragma_then_comment() {
  # The pragma copier must stop AT `#-}`. When it only compared two characters
  # against the three-character delimiter it never matched, ran to end of line,
  # and copied the trailing `-- ... {!!}` comment back in as code.
  mkdir -p proofs
  cat > proofs/P.agda <<'EOF'
module P where
{-# OPTIONS --without-K #-}  -- never write {!!} in this module
f : Nat -> Nat
f n = n
EOF
}

setup_agda_hole_after_pragma() {
  mkdir -p proofs
  cat > proofs/P.agda <<'EOF'
module P where
{-# OPTIONS --without-K #-}
f : Nat -> Nat
f n = {!!}
EOF
}

setup_idris_hole_in_doc_comment() {
  # `|||` documentation comments survive the shared Haskell stripper (it knows
  # `--` and `{- -}`), so this pass routes through emit_marker's guard.
  mkdir -p proofs
  cat > proofs/D.idr <<'EOF'
module D

||| The ?goal hole that used to live here is discharged by the totality checker.
total
f : Nat -> Nat
f n = n
EOF
}

setup_idris_real_hole() {
  mkdir -p proofs
  cat > proofs/H.idr <<'EOF'
module H

f : Nat -> Nat
f n = ?goal
EOF
}

setup_dafny_axiom_in_comment() {
  # Dafny has OCaml-style comments, not Haskell's: `//` and nested `/* */`.
  # A prose mention of the attribute is not an axiom.
  mkdir -p proofs
  cat > proofs/L.dfy <<'EOF'
method M(x: int) returns (y: int)
  // Do not use {:axiom} in this module; the postcondition is proved below.
  /* Nor here: {:axiom} would defeat the point. */
{
  y := x;
}
EOF
}

setup_dafny_real_axiom() {
  mkdir -p proofs
  cat > proofs/A.dfy <<'EOF'
lemma {:axiom} bogus()
  ensures false
{
}
EOF
}

setup_fstar_admit_in_comment() {
  # F* comments are `//` and nested `(* *)`; the Haskell stripper left them
  # intact, so a comment saying "the admit() was removed" counted as an admit.
  mkdir -p proofs
  cat > proofs/M.fst <<'EOF'
module M
(* We removed the admit() call here in 2026-05; the lemma is now proved. *)
let f (x:int) : int = x
EOF
}

setup_fstar_real_admit() {
  mkdir -p proofs
  cat > proofs/M.fst <<'EOF'
module M
let f (x:int) : int = admit()
EOF
}

setup_mixed_tiers() {
  # One core marker (`Axiom`) and one extended marker (`Parameter`) in the same
  # file, so a tier filter can be observed removing exactly one of them.
  mkdir -p formal
  cat > formal/M.v <<'EOF'
Axiom cheat : False.
Parameter cheat2 : nat.
EOF
}

setup_idris_partial_trailing_comment() {
  # `partial -- why` strips to `partial ` (trailing space, because the stripper
  # leaves the whitespace before `--`). `^partial$` missed it.
  mkdir -p proofs
  cat > proofs/P.idr <<'EOF'
module P

partial -- the termination checker cannot see the decreasing argument
loop : Nat -> Nat
loop n = loop n
EOF
}

setup_fstar_admit_with_space() {
  mkdir -p proofs
  cat > proofs/S.fst <<'EOF'
module S
let f (x:int) : int = admit ()
EOF
}

setup_coq_parameter() {
  mkdir -p formal
  cat > formal/P.v <<'EOF'
Parameter cheat : forall P : Prop, P.
EOF
}

setup_coq_hypothesis_in_section() {
  mkdir -p formal
  cat > formal/S.v <<'EOF'
Section S.
  Hypothesis H : forall n : nat, n = n.
  Variable A : Type.

  Theorem trivial_use : forall n : nat, n = n.
  Proof. exact H. Qed.
End S.
EOF
}

setup_idris_hole() {
  mkdir -p src
  cat > src/H.idr <<'EOF'
module H
f : Int -> Int
f x = ?need_to_think
EOF
}

setup_idris_default_total_not_a_hole() {
  # `%default total` is the STRICT setting. Treating it as a marker would
  # red-board every well-disciplined Idris2 repository in the estate.
  mkdir -p src
  cat > src/Good.idr <<'EOF'
module Good
%default total
add : Nat -> Nat -> Nat
add x y = x + y
EOF
}

setup_idris_owed_annotation() {
  mkdir -p src docs
  # The proof-debt index is mandatory for a repo carrying core markers; the
  # OWED: annotation is what discharges the individual marker.
  cat > docs/proof-debt.md <<'EOF'
# Proof Debt
(Inline OWED: annotations only; see the source.)
EOF
  cat > src/Ax.idr <<'EOF'
module Ax
||| OWED: function extensionality; necessary; see docs/proof-debt.md §(c).
||| Citation: Mathlib4 Function.funext_iff.
0 funExt : (f, g : a -> b) -> ((x : a) -> f x = g x) -> f = g
-- OWED: erased axiom at the typed-wasm boundary; see §(c) entry "funExt".
funExt f g p = believe_me ()
EOF
}

setup_dafny_axiom() {
  mkdir -p dafny
  cat > dafny/D.dfy <<'EOF'
lemma {:axiom} cheat()
  ensures false
EOF
}

setup_fstar_bare_assume() {
  mkdir -p fstar
  cat > fstar/A.fst <<'EOF'
let bad : Lemma True = admit()
EOF
}

setup_fstar_mixed_forms() {
  mkdir -p fstar docs
  printf '# Proof debt\n' > docs/proof-debt.md
  cat > fstar/A.fst <<'EOF'
let x = admit_p (); let y = admit (); let z = assume True
EOF
}

setup_fstar_core_and_bare_assume() {
  mkdir -p fstar docs
  printf '# Proof debt\n' > docs/proof-debt.md
  cat > fstar/A.fst <<'EOF'
// TRUSTED: documented core escape.
assume val x : Type; assume True
EOF
}

setup_fstar_core_only() {
  mkdir -p fstar docs
  printf '# Proof debt\n' > docs/proof-debt.md
  cat > fstar/A.fst <<'EOF'
// TRUSTED: documented core escape.
assume val x : Type
EOF
}

setup_fstar_multiline_assume() {
  mkdir -p fstar docs
  cat > fstar/A.fst <<'EOF'
module A
assume val first : True
assume // declaration continues after comments
(* nested (* comment *) *)
  val second : True
let a = assume (True)
assume
let b = True
let c = assume (True); assume val third : True
let d = admit ()
EOF
  echo '# Proof debt' > docs/proof-debt.md
}

setup_extended_with_budget_file() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
  cat > .trusted-base-budget <<'EOF'
# Measured by scripts/estate-trusted-base-survey.sh on 2026-10-30.
mode: budget
extended-undocumented: 1
EOF
}

setup_extended_with_budget_too_small() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
  cat > .trusted-base-budget <<'EOF'
mode: budget
extended-undocumented: 0
EOF
}

setup_extended_malformed_budget() {
  mkdir -p proofs
  cat > proofs/Term.agda <<'EOF'
module Term where
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
  cat > .trusted-base-budget <<'EOF'
mode: sometimes
EOF
}

setup_extended_ignored_path() {
  mkdir -p test/fixtures
  cat > test/fixtures/term.agda <<'EOF'
module term where
{-# TERMINATING #-}
loop : Nat -> Nat
loop n = loop n
EOF
  cat > .trusted-base-ignore <<'EOF'
# Negative-control fixtures: exist to be detected.
test/fixtures/
EOF
}

# Existing behaviour must still work.
run_case "marker with no docs and no ignore fails (early exit)" \
  1 "No docs/proof-debt.md (or equivalent) found" setup_marker_no_docs

run_case "inline TRUSTED comment passes (regression)" \
  0 "All 1 escape hatch(es) are documented" setup_marker_with_inline_trusted

run_case "entry in proof-debt.md passes (regression)" \
  0 "All 1 escape hatch(es) are documented" setup_marker_with_proof_debt

# New .trusted-base-ignore behaviour.
run_case "single path-fragment exempts marker (no proof-debt doc)" \
  0 "1 marker(s) exempted via .trusted-base-ignore" setup_marker_with_ignore_exact

run_case "substring-match exemption picks up deeper paths" \
  0 "1 marker(s) exempted via .trusted-base-ignore" setup_marker_with_ignore_substring

run_case "ignore file with only comments behaves as no exemptions" \
  1 "1/1 escape hatch(es) are undocumented" setup_ignore_comments_only_still_fails

run_case "ignore pattern that does not match still fails" \
  1 "1/1 escape hatch(es) are undocumented" setup_ignore_does_not_match

run_case "mixed: one marker exempted, one documented in proof-debt" \
  0 "1 marker(s) exempted via .trusted-base-ignore" setup_mixed_exempt_and_documented

run_case "Coq nested multiline comment prose is not executable debt" \
  0 "No soundness-relevant escape hatches detected" setup_coq_multiline_comments_only

run_case "real Coq Admitted after a comment still fails" \
  1 "1/1 escape hatch(es) are undocumented" setup_coq_comment_then_real_admitted

run_case "Coq comment delimiters inside strings cannot hide a later axiom" \
  1 "1/1 escape hatch(es) are undocumented" setup_coq_string_delimiters_then_real_marker

run_case "real Coq marker after a same-line leading comment still fails" \
  1 "1/1 escape hatch(es) are undocumented" setup_coq_leading_comment_then_real_marker

run_case "unterminated Coq string fails closed instead of hiding the file" \
  1 "1/1 escape hatch(es) are undocumented" setup_coq_unterminated_string

# ─────────────────────────────────────────────────────────────────────────────
# Extended tier — detected, and reported rather than failed by default
# ─────────────────────────────────────────────────────────────────────────────
run_case "Agda {-# TERMINATING #-} is detected" \
  0 "agda-terminating-pragma" setup_agda_terminating_undocumented

run_case "extended marker alone does NOT fail the repo (mode=report default)" \
  0 "extended_mode=report" setup_agda_terminating_undocumented

run_case "Agda unsound OPTIONS flags are detected" \
  0 "agda-unsound-flag" setup_agda_unsound_flags

run_case_env "Agda multiline OPTIONS flags fail strict mode" \
  1 "mode=strict permits none" setup_agda_multiline_pragma TRUSTED_BASE_EXTENDED_MODE=strict
run_case "Agda multiline pragma closes before trailing comments" \
  0 "extended_total=1" setup_agda_multiline_pragma

run_case "Agda {!!} hole is detected" \
  0 "agda-hole" setup_agda_hole

run_case "Lean @[implemented_by] is detected" \
  0 "lean-implemented-by" setup_lean_implemented_by

run_case "Lean native_decide is detected" \
  0 "lean-native-decide" setup_lean_native_decide_real

run_case "Coq Parameter is detected" \
  0 "coq-parameter-or-conjecture" setup_coq_parameter

run_case "Idris2 ?hole is detected" \
  0 "idris-hole" setup_idris_hole

run_case "Dafny {:axiom} is detected" \
  0 "dafny-axiom" setup_dafny_axiom

run_case "F* bare admit() is detected" \
  0 "fstar-assume-or-admit-bare" setup_fstar_bare_assume

run_case_env "F* bare markers alongside admit_p fail strict mode" \
  1 "mode=strict permits none" setup_fstar_mixed_forms TRUSTED_BASE_EXTENDED_MODE=strict
run_case "F* bare assume alongside assume val is detected" \
  0 "extended_total=1" setup_fstar_core_and_bare_assume
run_case "F* assume val alone adds no extended marker" \
  0 "extended_total=0" setup_fstar_core_only

# Core declarations on one or multiple lines must not be counted as bare;
# genuine standalone assumes (including one next to a declaration) still are.
run_case "F* multiline assume val is core and standalone assumes remain extended" \
  1 "core_total=3 core_undocumented=3 core_documented=0 core_exempted=0 extended_total=4" setup_fstar_multiline_assume

# ─────────────────────────────────────────────────────────────────────────────
# Extended tier — deliberately NOT detected (the anti-red-board family).
# Each of these would flag healthy code; a failure here is a regression that
# costs a real repository its green board.
# ─────────────────────────────────────────────────────────────────────────────
run_case "Idris2 %default total is NOT a marker (it is the strict setting)" \
  0 "No soundness-relevant escape hatches detected" setup_idris_default_total_not_a_hole

run_case "Coq Hypothesis inside a Section is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_coq_hypothesis_in_section

run_case "Agda {-# TERMINATING #-} inside a block comment is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_agda_terminating_in_block_comment

run_case "Lean native_decide mentioned in a doc comment is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_lean_native_decide_in_comment

run_case "Agda: a comment AFTER a closed pragma is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_agda_pragma_then_comment

run_case "Idris2: a ?hole mentioned in a ||| doc comment is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_idris_hole_in_doc_comment

run_case "Dafny: {:axiom} mentioned in // and /* */ comments is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_dafny_axiom_in_comment

run_case "F*: admit() mentioned in a (* *) comment is NOT a marker" \
  0 "No soundness-relevant escape hatches detected" setup_fstar_admit_in_comment

# …and the same constructs in real code still ARE markers. Without these the
# four cases above could pass by detecting nothing at all.
run_case "Agda: a real {!!} after a pragma line is still a marker" \
  0 "extended_total=1" setup_agda_hole_after_pragma

run_case "Idris2: a real ?goal is still a marker" \
  0 "extended_total=1" setup_idris_real_hole

run_case "Dafny: a real {:axiom} is still a marker" \
  0 "extended_total=1" setup_dafny_real_axiom

run_case "F*: a real admit() is still a marker" \
  0 "extended_total=1" setup_fstar_real_admit

run_case "Idris2: a top-level partial with a trailing comment is a core marker" \
  1 "Found 1 core-tier and 0 extended-tier marker(s)" setup_idris_partial_trailing_comment

run_case "F*: admit () with a space is still an extended marker" \
  0 "extended_total=1" setup_fstar_admit_with_space

# ─────────────────────────────────────────────────────────────────────────────
# Discharge routes apply to the extended tier identically.
# ─────────────────────────────────────────────────────────────────────────────
run_case "JUSTIFIED: leading comment discharges an extended marker" \
  0 "extended_documented=1" setup_agda_terminating_justified

run_case_env "JUSTIFIED: annotation passes mode=strict" \
  0 "no undocumented markers (mode=strict)" setup_agda_terminating_justified TRUSTED_BASE_EXTENDED_MODE=strict

run_case "OWED: annotation discharges an Idris2 believe_me (policy claimed this since #203)" \
  0 "core_undocumented=0" setup_idris_owed_annotation

run_case ".trusted-base-ignore exempts an extended marker" \
  0 "1 extended-tier marker(s) exempted" setup_extended_ignored_path

# ─────────────────────────────────────────────────────────────────────────────
# Budget mechanism.
# ─────────────────────────────────────────────────────────────────────────────
run_case "budget file: measured number passes" \
  0 "1/1 budgeted marker(s) undocumented" setup_extended_with_budget_file

run_case "budget file: exceeding the budget fails" \
  1 "exceed the declared budget of 0" setup_extended_with_budget_too_small

run_case "budget file: malformed mode fails closed with exit 2" \
  2 "mode must be report|budget|strict" setup_extended_malformed_budget

run_case_env "mode=strict fails on an undocumented extended marker" \
  1 "mode=strict permits none" setup_agda_terminating_undocumented TRUSTED_BASE_EXTENDED_MODE=strict

run_case_env "CLI/environment override beats the budget file" \
  0 "extended_mode=report" setup_extended_with_budget_too_small TRUSTED_BASE_EXTENDED_MODE=report

# ─────────────────────────────────────────────────────────────────────────────
# The marker catalogue is a contract: the survey script and the docs both read
# it, so both tiers must appear and nothing may silently vanish.
# ─────────────────────────────────────────────────────────────────────────────
catalogue="$(bash "$SCRIPT" --list-markers 2>&1)"
for need in agda-terminating-pragma agda-unsound-flag lean-implemented-by \
            lean-native-decide coq-parameter-or-conjecture idris-hole dafny-axiom; do
  if printf '%s' "$catalogue" | grep -q "$need"; then
    echo "ok   catalogue lists $need"
    PASS=$((PASS+1))
  else
    echo "FAIL catalogue is missing $need"
    FAIL=$((FAIL+1))
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# --tier narrows the scan. It is the triage mode: a maintainer looks at the new
# tier alone without inheriting the core tier's exit code, and vice versa.
# ─────────────────────────────────────────────────────────────────────────────
# The old tier tests were vacuous: the "extended ignores core" case used a
# fixture that contained no core marker at all, so core_total=0 proved nothing
# about the filter. Both cases now run against ONE fixture carrying a core and
# an extended marker, and assert the other tier's total is zero while its own is
# not — which is the only way a filter can be shown to work.
run_case_env "tier=extended: core marker filtered OUT, extended marker counted" \
  0 "Found 0 core-tier and 1 extended-tier marker(s)" setup_mixed_tiers TRUSTED_BASE_TIER=extended

run_case_env "tier=core: extended marker filtered OUT, core marker still fails" \
  1 "Found 1 core-tier and 0 extended-tier marker(s)" setup_mixed_tiers TRUSTED_BASE_TIER=core

run_case_env "tier=extended ignores an undocumented CORE marker" \
  0 "core_total=0" setup_coq_parameter TRUSTED_BASE_TIER=extended

run_case_env "tier=core ignores an undocumented EXTENDED marker" \
  0 "No soundness-relevant escape hatches detected" setup_agda_terminating_undocumented TRUSTED_BASE_TIER=core

echo
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
