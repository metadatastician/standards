-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Language facts about the coordination.k9 grammars (spec/abnf/).
|||
||| Three claims made in the grammar changelogs are proved here, for the
||| RFC 5234 meaning of a grammar: the set of byte strings that have a
||| derivation. They are not claims about any parser.
|||
|||   1. v1.1 -> v1.2 (`v11FilesAreV12Files`). When two grammars agree on
|||      every rule except `body`, and v1.2's `body` is v1.1's with optional
|||      elements inserted, every string the v1.1 grammar derives, the
|||      v1.2 grammar derives. (ABNF productions only: the 998-octet line
|||      limit of spec rule 14 is a whole-file constraint not modelled
|||      here, so a v1.1 file with a longer line is not a conforming v1.2
|||      file.) The general
|||      lemma is `extend`; `bodyInterleave` is the concrete `body` step.
|||      That the committed grammars agree on every other rule is the side
|||      condition `validate.js --self-test` re-checks on every run
|||      (`extensionViolations`).
|||   2. deed-filename (`deedFilenameEquiv`). The right-recursive form
|||      written on 2026-11-09 denotes the same strings as
|||      `1*deed-char %s".deed"`.
|||   3. date (`altSwap`). Reordering the alternatives of `date` does not
|||      change its language.
|||
||| Modelling choices, stated so they can be checked against RFC 5234:
|||   * A rule name is a String; a grammar maps names to definitions.
|||   * Bounded repetition is sugar: `nX` is n copies of X concatenated,
|||     `1*X` is `X *X`, and `n*mX` is n copies followed by m-n nested
|||     options. Only `*X` (Star), `[X]` (Opt), concatenation and
|||     alternation are primitive.
|||   * A value range %xNN-MM is the finite alternation of its single-byte
|||     Lits (%xNN / ... / %xMM), which is exactly its RFC 5234 meaning, so it
|||     needs no constructor of its own.
|||   * A quoted string is a fixed byte sequence (Lit); a case-insensitive
|||     "..." is the alternation of its spellings, which no lemma here
|||     needs. `%s".deed"` is the case-sensitive Lit [0x2E,0x64,0x65,0x65,0x64].
|||
||| Trusted base: the Idris2 0.7.0 kernel and its `base` library, including
||| `DecEq String`, which rests on primitive string equality. Nothing else
||| is assumed: the module is total and has no holes, postulates,
||| believe_me or assert_*.
module GrammarExtension

import Data.List
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- RFC 5234 grammars and their derivations
--------------------------------------------------------------------------------

public export
Word : Type
Word = List Bits8

public export
data Expr : Type where
  Eps   : Expr                      -- the empty concatenation
  Lit   : Word -> Expr              -- %s"...", %xNN.NN or %xNN
  Ref   : String -> Expr            -- a rule name
  Cat   : Expr -> Expr -> Expr      -- concatenation
  Alt   : Expr -> Expr -> Expr      -- alternation (unordered, RFC 5234 3.2)
  Opt   : Expr -> Expr              -- [X]
  Star  : Expr -> Expr              -- *X

public export
Grammar : Type
Grammar = String -> Maybe Expr

||| `Derives g e w`: the byte string w has a derivation from e under g.
public export
data Derives : Grammar -> Expr -> Word -> Type where
  DEps   : Derives g Eps []
  DLit   : Derives g (Lit s) s
  DRef   : g n = Just e -> Derives g e w -> Derives g (Ref n) w
  DCat   : Derives g a u -> Derives g b v -> Derives g (Cat a b) (u ++ v)
  DAltL  : Derives g a w -> Derives g (Alt a b) w
  DAltR  : Derives g b w -> Derives g (Alt a b) w
  DNone  : Derives g (Opt e) []
  DSome  : Derives g e w -> Derives g (Opt e) w
  DNil   : Derives g (Star e) []
  DMore  : Derives g e u -> Derives g (Star e) v -> Derives g (Star e) (u ++ v)

||| A grammar accepts w from a start rule.
public export
Accepts : Grammar -> String -> Word -> Type
Accepts g start w = Derives g (Ref start) w

0 justInj : {0 a, b : t} -> Just a = Just b -> a = b
justInj Refl = Refl

--------------------------------------------------------------------------------
-- 1. Inserting optional elements preserves acceptance
--------------------------------------------------------------------------------

||| `Ext e e'`: e' is e with zero or more optional elements inserted into
||| concatenations, anywhere inside it.
public export
data Ext : Expr -> Expr -> Type where
  Same   : Ext e e
  Insert : Ext e e' -> Ext e (Cat (Opt x) e')
  CatE   : Ext a a' -> Ext b b' -> Ext (Cat a b) (Cat a' b')
  AltE   : Ext a a' -> Ext b b' -> Ext (Alt a b) (Alt a' b')
  OptE   : Ext e e' -> Ext (Opt e) (Opt e')
  StarE  : Ext e e' -> Ext (Star e) (Star e')

||| g' extends g: every rule g defines, g' defines as an `Ext` of it. Rules
||| only g' defines are unconstrained (no g derivation can reach them).
public export
GExt : Grammar -> Grammar -> Type
GExt g g' = (n : String) -> (e : Expr) -> g n = Just e ->
            (e' : Expr ** (g' n = Just e', Ext e e'))

mutual
  ||| The general lemma: a derivation under g of e is a derivation under g' of
  ||| any extension of e. `keep` is the `Same` case: g' re-derives e itself,
  ||| following g's rules into their g' extensions.
  export
  0 extend : GExt g g' -> Derives g e w -> Ext e e' -> Derives g' e' w
  extend gx d Same = keep gx d
  extend gx d (Insert x) = DCat DNone (extend gx d x)
  extend gx (DCat a b) (CatE x y) = DCat (extend gx a x) (extend gx b y)
  extend gx (DAltL a) (AltE x y) = DAltL (extend gx a x)
  extend gx (DAltR b) (AltE x y) = DAltR (extend gx b y)
  extend gx DNone (OptE x) = DNone
  extend gx (DSome a) (OptE x) = DSome (extend gx a x)
  extend gx DNil (StarE x) = DNil
  extend gx (DMore a b) (StarE x) = DMore (extend gx a x) (extend gx b (StarE x))

  export
  0 keep : GExt g g' -> Derives g e w -> Derives g' e w
  keep gx DEps = DEps
  keep gx DLit = DLit
  keep gx (DRef {n} {e = body} p d) =
    case gx n body p of
      (body' ** (p', x)) => DRef p' (extend gx d x)
  keep gx (DCat a b) = DCat (keep gx a) (keep gx b)
  keep gx (DAltL a) = DAltL (keep gx a)
  keep gx (DAltR b) = DAltR (keep gx b)
  keep gx DNone = DNone
  keep gx (DSome a) = DSome (keep gx a)
  keep gx DNil = DNil
  keep gx (DMore a b) = DMore (keep gx a) (keep gx b)

||| Every word g accepts from any start rule, an extension g' accepts.
export
0 extensionPreservesAcceptance : GExt g g' -> Accepts g s w -> Accepts g' s w
extensionPreservesAcceptance gx d = keep gx d

||| An ABNF concatenation `x1 x2 ... xn`.
public export
seq : List Expr -> Expr
seq [] = Eps
seq (x :: xs) = Cat x (seq xs)

||| ys is xs with optional elements inserted: the shape validate.js checks
||| for `body` (the v1.1 elements in order, every extra one `[...]`).
public export
data Interleave : List Expr -> List Expr -> Type where
  Done : Interleave [] []
  Keep : Interleave xs ys -> Interleave (x :: xs) (x :: ys)
  Add  : Interleave xs ys -> Interleave xs (Opt y :: ys)

export
0 interleaveExt : Interleave xs ys -> Ext (seq xs) (seq ys)
interleaveExt Done = Same
interleaveExt (Keep r) = CatE Same (interleaveExt r)
interleaveExt (Add r) = Insert (interleaveExt r)

--------------------------------------------------------------------------------
-- The concrete step: v1.1 body -> v1.2 body
--------------------------------------------------------------------------------

gaps : Expr
gaps = Star (Ref "gap")

||| `[name *gap]`
optSection : String -> Expr
optSection name = Opt (seq [Ref name, gaps])

||| coordination-k9-grammar_v1.1.abnf, rule `body`.
public export
bodyV11 : List Expr
bodyV11 =
  [ Ref "metadata-section", gaps
  , Ref "project-section", gaps
  , Ref "invariants-section", gaps
  , optSection "protected-section"
  , optSection "architecture-section"
  , optSection "do-not-create-section"
  , optSection "terminology-section"
  , optSection "ecosystem-section"
  , optSection "coordination-section"
  ]

||| coordination-k9-grammar_v1.2.abnf, rule `body`.
public export
bodyV12 : List Expr
bodyV12 =
  [ Ref "metadata-section", gaps
  , Ref "project-section", gaps
  , optSection "build-commands-section"
  , Ref "invariants-section", gaps
  , optSection "protected-section"
  , optSection "architecture-section"
  , optSection "innervation-section"
  , optSection "do-not-create-section"
  , optSection "terminology-section"
  , optSection "ecosystem-section"
  , optSection "coordination-section"
  ]

||| v1.2's body is v1.1's with [build-commands-section *gap] and
||| [innervation-section *gap] inserted.
export
bodyInterleave : Interleave GrammarExtension.bodyV11 GrammarExtension.bodyV12
bodyInterleave =
  Keep $ Keep $ Keep $ Keep $ Add $ Keep $ Keep $ Keep $ Keep $ Add $
  Keep $ Keep $ Keep $ Keep $ Done

||| Every string the v1.1 grammar derives from `k9-file`, the v1.2 grammar
||| derives (ABNF productions only; see the header), given the side condition validate.js
||| checks on the committed grammars: every rule v1.1 defines other than
||| `body`, v1.2 defines identically.
export
0 v11FilesAreV12Files :
  (g11, g12 : Grammar) ->
  (same : (n : String) -> Not (n = "body") -> (e : Expr) ->
          g11 n = Just e -> g12 n = Just e) ->
  (b11 : g11 "body" = Just (seq GrammarExtension.bodyV11)) ->
  (b12 : g12 "body" = Just (seq GrammarExtension.bodyV12)) ->
  Accepts g11 "k9-file" w -> Accepts g12 "k9-file" w
v11FilesAreV12Files g11 g12 same b11 b12 = extensionPreservesAcceptance gx
  where
    gx : GExt g11 g12
    gx n e p with (decEq n "body")
      -- The name is transported along isBody rather than matched with Refl:
      -- Idris2 0.8 does not count a Refl match on a String literal as
      -- covering `Yes _`.
      gx n e p | Yes isBody =
        ( seq GrammarExtension.bodyV12
        ** ( replace {p = \m => g12 m = Just (seq GrammarExtension.bodyV12)} (sym isBody) b12
           , replace {p = \t => Ext t (seq GrammarExtension.bodyV12)}
                     (justInj (trans (sym (replace {p = \m => g11 m = Just (seq GrammarExtension.bodyV11)} (sym isBody) b11)) p))
                     (interleaveExt bodyInterleave) ) )
      gx n e p | No notBody = (e ** (same n notBody e p, Same))

--------------------------------------------------------------------------------
-- 2. deed-filename: the right-recursive form is 1*deed-char %s".deed"
--------------------------------------------------------------------------------

||| %s".deed"
public export
dotDeed : Word
dotDeed = [0x2E, 0x64, 0x65, 0x65, 0x64]

||| deed-tail = deed-char deed-tail / %s".deed", for deed-char written c.
public export
tailDef : Expr -> Expr
tailDef c = Alt (Cat c (Ref "deed-tail")) (Lit dotDeed)

-- One-level inversions. Idris2 0.7.0's coverage checker does not split
-- nested patterns over `++`-indexed derivations, so each is taken alone.

0 litInv : Derives g (Lit s) w -> w = s
litInv DLit = Refl

0 refInv : g n = Just c0 -> Derives g (Ref n) w -> Derives g c0 w
refInv h (DRef p d) = replace {p = \x => Derives g x w} (justInj (trans (sym p) h)) d

0 starToTail : {c : Expr} -> g "deed-tail" = Just (tailDef c) ->
               Derives g (Star c) u -> Derives g (Ref "deed-tail") (u ++ GrammarExtension.dotDeed)
starToTail h DNil = DRef h (DAltR DLit)
starToTail h (DMore {u = u1} {v = v1} dc r) =
  replace {p = Derives g (Ref "deed-tail")} (appendAssociative u1 v1 dotDeed)
          (DRef h (DAltL (DCat dc (starToTail h r))))

mutual
  0 tailToStar : {c : Expr} -> g "deed-tail" = Just (tailDef c) ->
                 Derives g (Ref "deed-tail") w ->
                 (u : Word ** (Derives g (Star c) u, w = u ++ GrammarExtension.dotDeed))
  tailToStar h (DRef p d) = unfoldTail h (trans (sym h) p) d

  0 unfoldTail : {c, e : Expr} -> g "deed-tail" = Just (tailDef c) ->
                 Just (tailDef c) = Just e -> Derives g e w ->
                 (u : Word ** (Derives g (Star c) u, w = u ++ GrammarExtension.dotDeed))
  unfoldTail h Refl d = tailBody h d

  0 tailBody : {c : Expr} -> g "deed-tail" = Just (tailDef c) ->
               Derives g (Alt (Cat c (Ref "deed-tail")) (Lit GrammarExtension.dotDeed)) w ->
               (u : Word ** (Derives g (Star c) u, w = u ++ GrammarExtension.dotDeed))
  tailBody h (DAltR d) = ([] ** (DNil, litInv d))
  tailBody h (DAltL d) = tailStep h d

  0 tailStep : {c : Expr} -> g "deed-tail" = Just (tailDef c) ->
               Derives g (Cat c (Ref "deed-tail")) w ->
               (u : Word ** (Derives g (Star c) u, w = u ++ GrammarExtension.dotDeed))
  tailStep h (DCat {u = u1} dc dt) =
    case tailToStar h dt of
      (v ** (r, prf)) =>
        ( u1 ++ v
        ** (DMore dc r, trans (cong (u1 ++) prf) (appendAssociative u1 v dotDeed)) )

-- A word-preserving map between element derivations lifts to a star. The
-- inline/refer directions are its instances: Idris2 0.8 does not see a
-- direct match on `Derives g (Star (Ref n)) u` as covering.
0 starMap : ((v : Word) -> Derives g a v -> Derives g b v) ->
            Derives g (Star a) u -> Derives g (Star b) u
starMap f DNil = DNil
starMap f (DMore {u = u1} d r) = DMore (f u1 d) (starMap f r)

0 starInline : g n = Just c0 -> Derives g (Star (Ref n)) u -> Derives g (Star c0) u
starInline h = starMap (\v, d => refInv h d)

0 starRefer : g n = Just c0 -> Derives g (Star c0) u -> Derives g (Star (Ref n)) u
starRefer h = starMap (\v, d => DRef h d)

0 oldTail : Derives g (Cat (Star c0) (Lit GrammarExtension.dotDeed)) w ->
            (u : Word ** (Derives g (Star c0) u, w = u ++ GrammarExtension.dotDeed))
oldTail (DCat {u = u1} r l) = (u1 ** (r, cong (u1 ++) (litInv l)))

||| The form before 2026-11-09: 1*(c0) %s".deed", that is c0 *c0 %s".deed".
public export
deedFilenameOld : Expr -> Expr
deedFilenameOld c0 = Cat c0 (Cat (Star c0) (Lit dotDeed))

||| The form from 2026-11-09: deed-char deed-tail.
public export
deedFilenameNew : Expr
deedFilenameNew = Cat (Ref "deed-char") (Ref "deed-tail")

0 toNew : {c0 : Expr} -> g "deed-char" = Just c0 ->
          g "deed-tail" = Just (tailDef (Ref "deed-char")) ->
          Derives g (deedFilenameOld c0) w -> Derives g GrammarExtension.deedFilenameNew w
toNew hc ht (DCat {u = u1} d0 rest) =
  case oldTail rest of
    (v ** (r, prf)) =>
      replace {p = \t => Derives g GrammarExtension.deedFilenameNew (u1 ++ t)} (sym prf)
              (DCat (DRef hc d0) (starToTail ht (starRefer hc r)))

0 toOld : {c0 : Expr} -> g "deed-char" = Just c0 ->
          g "deed-tail" = Just (tailDef (Ref "deed-char")) ->
          Derives g GrammarExtension.deedFilenameNew w -> Derives g (deedFilenameOld c0) w
toOld hc ht (DCat {u = u1} dc dt) =
  case tailToStar ht dt of
    (v ** (r, prf)) =>
      replace {p = \t => Derives g (deedFilenameOld c0) (u1 ++ t)} (sym prf)
              (DCat (refInv hc dc) (DCat (starInline hc r) DLit))

||| In any grammar where deed-char = c0 and deed-tail = deed-char deed-tail /
||| %s".deed", the two forms derive exactly the same words.
export
0 deedFilenameEquiv :
  {c0 : Expr} ->
  (hc : g "deed-char" = Just c0) ->
  (ht : g "deed-tail" = Just (tailDef (Ref "deed-char"))) ->
  (Derives g (deedFilenameOld c0) w -> Derives g GrammarExtension.deedFilenameNew w,
   Derives g GrammarExtension.deedFilenameNew w -> Derives g (deedFilenameOld c0) w)
deedFilenameEquiv hc ht = (toNew hc ht, toOld hc ht)

--------------------------------------------------------------------------------
-- 3. date: alternation is unordered
--------------------------------------------------------------------------------

||| Swapping two alternatives keeps the language (applied in both
||| directions, it is an equivalence).
export
0 altSwap : Derives g (Alt a b) w -> Derives g (Alt b a) w
altSwap (DAltL d) = DAltR d
altSwap (DAltR d) = DAltL d
