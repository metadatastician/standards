||| SPDX-License-Identifier: MPL-2.0
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
|||
||| The K9 Hunt gate, `authorize_hunt` (K9-CONTRACT-SPEC §9.2), as an Idris2
||| model, with its properties proved.
|||
||| Policy: PROOF-POLICY §1 puts this in Idris2. It is an interface property of
||| the K9 contract (what a host must decide from five booleans of evidence),
||| not a property of one implementation's code.
|||
||| What is modelled. `spec/contract/k9_contract.ncl` and `leash.ncl` both
||| define, identically:
|||
|||   unmet = (if signature then [] else ["signature"]) @ (… policy …)
|||         @ (… sandbox …) @ (… dry_run …) @ (… capability_grant …)
|||   permitted = (length unmet == 0)
|||
||| `unmet` below is that definition, constructor for constructor, in the same
||| order.
|||
||| What is proved (kernel-checked by `idris2 --check`):
|||
||| * `permitIffAll`: the gate permits exactly when all five flags are true.
||| * `unmetNamesExactlyTheFalse`: a precondition is listed as unmet exactly
|||   when its flag is false. So a refusal never hides an unmet precondition and
|||   never names a met one.
||| * `signatureAloneInsufficient`: a verified signature with any other flag
|||   false is refused (the owner directive of 2026-06-03).
||| * `refusalIsNonEmpty`: a refusal always names at least one precondition.
|||
||| What is NOT proved here. That the Nickel text computes `unmet` exactly as
||| this model does. That bridge is checked exhaustively instead: all 32
||| evidence combinations are evaluated in BOTH Nickel copies against this
||| rule by `hunt-gate-exhaustive.ncl`, run from `k9-validate.sh --self-test`
||| (policy status TESTED, a complete enumeration of a finite domain).
module HuntGate

import Data.List
import Data.List.Elem

%default total

||| The five Hunt preconditions, in contract order (§9.2).
public export
data Precond = Signature | Policy | Sandbox | DryRun | CapabilityGrant

||| One Bool of evidence per precondition (`HuntEvidence`).
public export
record Evidence where
  constructor MkEvidence
  signature       : Bool
  policy          : Bool
  sandbox         : Bool
  dryRun          : Bool
  capabilityGrant : Bool

||| The evidence flag for one precondition.
public export
flag : Precond -> Evidence -> Bool
flag Signature       = signature
flag Policy          = policy
flag Sandbox         = sandbox
flag DryRun          = dryRun
flag CapabilityGrant = capabilityGrant

||| `[p]` when the flag is false, `[]` when true: the Nickel
||| `if e.x then [] else ["x"]`.
public export
missing : Precond -> Evidence -> List Precond
missing p e = if flag p e then [] else [p]

||| The unmet list, in contract order.
public export
unmet : Evidence -> List Precond
unmet e = missing Signature e ++ missing Policy e ++ missing Sandbox e
       ++ missing DryRun e ++ missing CapabilityGrant e

||| The verdict: `permitted = true` (enforced level Hunt) or a refusal naming
||| the unmet preconditions (enforced level Yard).
public export
data Verdict = Permit | Refuse (List Precond)

||| The verdict for an unmet list: permit only when it is empty.
public export
verdictOf : List Precond -> Verdict
verdictOf [] = Permit
verdictOf (u :: us) = Refuse (u :: us)

public export
authorize : Evidence -> Verdict
authorize e = verdictOf (unmet e)

export
Uninhabited (Refuse us = Permit) where
  uninhabited Refl impossible

export
Uninhabited (Permit = Refuse us) where
  uninhabited Refl impossible

||| All five flags hold.
public export
data AllFive : Evidence -> Type where
  MkAllFive : signature e = True -> policy e = True -> sandbox e = True
           -> dryRun e = True -> capabilityGrant e = True -> AllFive e

-- ── Lemmas ──────────────────────────────────────────────────────────────────

appendNilLeft : (xs, ys : List a) -> xs ++ ys = [] -> xs = []
appendNilLeft [] _ _ = Refl
appendNilLeft (_ :: _) _ prf = absurd prf

appendNilRight : (xs, ys : List a) -> xs ++ ys = [] -> ys = []
appendNilRight [] _ prf = prf
appendNilRight (_ :: _) _ prf = absurd prf

missingNil : (p : Precond) -> (e : Evidence) -> missing p e = [] -> flag p e = True
missingNil p e prf with (flag p e)
  _ | True  = Refl
  _ | False = absurd prf

flagMissingNil : (p : Precond) -> (e : Evidence) -> flag p e = True -> missing p e = []
flagMissingNil p e prf = rewrite prf in Refl

-- ── Theorems ────────────────────────────────────────────────────────────────

||| Permit exactly when all five hold (forward direction).
export
permitSound : (e : Evidence) -> authorize e = Permit -> AllFive e
permitSound e prf with (unmet e) proof u
  _ | [] =
    let s  = appendNilLeft  _ _ u
        r1 = appendNilRight _ _ u
        p  = appendNilLeft  _ _ r1
        r2 = appendNilRight _ _ r1
        b  = appendNilLeft  _ _ r2
        r3 = appendNilRight _ _ r2
        d  = appendNilLeft  _ _ r3
        c  = appendNilRight _ _ r3
    in MkAllFive (missingNil Signature e s) (missingNil Policy e p)
                 (missingNil Sandbox e b) (missingNil DryRun e d)
                 (missingNil CapabilityGrant e c)
  _ | (_ :: _) = absurd prf

||| Permit exactly when all five hold (backward direction).
export
permitComplete : (e : Evidence) -> AllFive e -> authorize e = Permit
permitComplete e (MkAllFive s p b d c) =
  rewrite flagMissingNil Signature e s in
  rewrite flagMissingNil Policy e p in
  rewrite flagMissingNil Sandbox e b in
  rewrite flagMissingNil DryRun e d in
  rewrite flagMissingNil CapabilityGrant e c in Refl

||| The gate permits exactly when all five flags are true.
export
permitIffAll : (e : Evidence) -> (authorize e = Permit -> AllFive e, AllFive e -> authorize e = Permit)
permitIffAll e = (permitSound e, permitComplete e)

elemMissing : (q, p : Precond) -> (e : Evidence) -> Elem q (missing p e) -> flag q e = False
elemMissing q p e el with (flag p e) proof f
  elemMissing p p e Here      | False = f
  elemMissing q p e (There x) | False = absurd x
  elemMissing q p e el        | True  = absurd el

missingElem : (p : Precond) -> (e : Evidence) -> flag p e = False -> Elem p (missing p e)
missingElem p e prf = rewrite prf in Here

elemAppend : (x : a) -> (xs, ys : List a) -> Elem x (xs ++ ys) -> Either (Elem x xs) (Elem x ys)
elemAppend x [] ys el = Right el
elemAppend x (x :: zs) ys Here = Left Here
elemAppend x (z :: zs) ys (There el) = case elemAppend x zs ys el of
  Left l  => Left (There l)
  Right r => Right r

appendLeft : (x : a) -> (xs, ys : List a) -> Elem x xs -> Elem x (xs ++ ys)
appendLeft x (x :: zs) ys Here = Here
appendLeft x (z :: zs) ys (There el) = There (appendLeft x zs ys el)

appendRight : (x : a) -> (xs, ys : List a) -> Elem x ys -> Elem x (xs ++ ys)
appendRight x [] ys el = el
appendRight x (z :: zs) ys el = There (appendRight x zs ys el)

||| A precondition is listed as unmet only if its flag is false.
export
unmetSound : (q : Precond) -> (e : Evidence) -> Elem q (unmet e) -> flag q e = False
unmetSound q e el =
  case elemAppend q (missing Signature e) _ el of
    Left l => elemMissing q Signature e l
    Right r1 => case elemAppend q (missing Policy e) _ r1 of
      Left l => elemMissing q Policy e l
      Right r2 => case elemAppend q (missing Sandbox e) _ r2 of
        Left l => elemMissing q Sandbox e l
        Right r3 => case elemAppend q (missing DryRun e) _ r3 of
          Left l => elemMissing q DryRun e l
          Right r4 => elemMissing q CapabilityGrant e r4

||| Every precondition whose flag is false is listed as unmet.
export
unmetComplete : (q : Precond) -> (e : Evidence) -> flag q e = False -> Elem q (unmet e)
unmetComplete Signature e prf =
  appendLeft _ _ _ (missingElem Signature e prf)
unmetComplete Policy e prf =
  appendRight _ (missing Signature e) _ (appendLeft _ _ _ (missingElem Policy e prf))
unmetComplete Sandbox e prf =
  appendRight _ (missing Signature e) _ (appendRight _ (missing Policy e) _
    (appendLeft _ _ _ (missingElem Sandbox e prf)))
unmetComplete DryRun e prf =
  appendRight _ (missing Signature e) _ (appendRight _ (missing Policy e) _
    (appendRight _ (missing Sandbox e) _ (appendLeft _ _ _ (missingElem DryRun e prf))))
unmetComplete CapabilityGrant e prf =
  appendRight _ (missing Signature e) _ (appendRight _ (missing Policy e) _
    (appendRight _ (missing Sandbox e) _ (appendRight _ (missing DryRun e) _
      (missingElem CapabilityGrant e prf))))

||| A precondition is named as unmet exactly when its flag is false.
export
unmetNamesExactlyTheFalse : (q : Precond) -> (e : Evidence)
                         -> (Elem q (unmet e) -> flag q e = False, flag q e = False -> Elem q (unmet e))
unmetNamesExactlyTheFalse q e = (unmetSound q e, unmetComplete q e)

||| A refusal always names at least one precondition.
export
refusalIsNonEmpty : (e : Evidence) -> authorize e = Refuse us -> NonEmpty us
refusalIsNonEmpty e prf with (unmet e)
  _ | [] = absurd prf
  _ | (x :: xs) = case prf of Refl => IsNonEmpty

||| A verified signature is not enough on its own: if any other flag is
||| false, Hunt is refused.
export
signatureAloneInsufficient : (e : Evidence) -> signature e = True
                          -> Either (policy e = False)
                               (Either (sandbox e = False)
                                 (Either (dryRun e = False) (capabilityGrant e = False)))
                          -> Not (authorize e = Permit)
signatureAloneInsufficient e _ others permit =
  let MkAllFive _ p b d c = permitSound e permit in
  case others of
    Left f => absurd (trans (sym p) f)
    Right (Left f) => absurd (trans (sym b) f)
    Right (Right (Left f)) => absurd (trans (sym d) f)
    Right (Right (Right f)) => absurd (trans (sym c) f)
