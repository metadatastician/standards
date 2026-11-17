-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ReportBack: the gitbot-fleet rows of the Hypatia verdict grid, as an
-- interface contract (PROOF-POLICY section 1: an engineering property of a
-- wire format several languages share, so Idris2).
--
-- What is modelled. A fleet member's row is decided by two inputs: the
-- report-back envelope the `fleet-report-backs` artifact supplied for it (if
-- any) and its entry in `.gitbot-fleet/enrolment.json`. The renderer
-- (`scripts/verdict-grid.sh` with `scripts/lib/verdict-grid.jq`, functions
-- `reporter`, `reportback`, `build` and `state`) turns them into a status and
-- a colour. `Envelope` is the envelope as the renderer classifies it,
-- `reportback`, `row` and `state` are those functions, and the theorems below
-- are the properties docs/VERDICT-GRID-SPEC.adoc claims for fleet rows.
--
-- What is not modelled. JSON parsing, path normalisation, the scope
-- computation (`bucket`) and the gating flag are inputs here, not proved:
-- a finding arrives already placed as Graded, Standing or Excluded. The tie
-- between this model and the jq text is the exhaustive differential test
-- scripts/tests/report-back-model-test.sh, over the cases `main` prints
-- (report-back-cases.tsv beside this file). That tie is TESTED, with bounds,
-- not proved; 3-practice/PROOF-NEEDS.adoc records both rows.
--
-- Check: idris2 --check --total ReportBack.idr, from this directory.
-- Cases: idris2 ReportBack.idr --exec main > report-back-cases.tsv
module ReportBack

import Data.List
import Data.List.Elem
import Data.Nat

%default total

-- ── Severity ──────────────────────────────────────────────────────────────

||| The severity spellings `norm_sev` reads, after `ascii_downcase`.
||| `ROther` stands for every other string, and for a missing severity.
public export
data RawSev = RCritical | RHigh | RError | RMedium | RWarn | RWarning
            | RLow | RInfo | RInformational | RNote | RSuggestion | ROther

||| `norm_sev`'s result.
public export
data Sev = Critical | High | Medium | Low | Info | Unknown

public export
normSev : RawSev -> Sev
normSev RCritical      = Critical
normSev RHigh          = High
normSev RError         = High
normSev RMedium        = Medium
normSev RWarn          = Medium
normSev RWarning       = Medium
normSev RLow           = Low
normSev RInfo          = Info
normSev RInformational = Info
normSev RNote          = Info
normSev RSuggestion    = Info
normSev ROther         = Unknown

||| `rank`: an unknown severity ranks 0, the same as no finding at all. That
||| is why `reporter` must turn a ran row carrying one into an error.
public export
rank : Sev -> Nat
rank Critical = 5
rank High     = 4
rank Medium   = 3
rank Low      = 2
rank Info     = 1
rank Unknown  = 0

||| The fleet's own words map as REPORT-BACK.adoc section 3 and the spec say.
export
fleetWords : (normSev RError = High, normSev RWarning = Medium, normSev RSuggestion = Info)
fleetWords = (Refl, Refl, Refl)

public export
isUnknownRaw : RawSev -> Bool
isUnknownRaw ROther = True
isUnknownRaw _      = False

||| A severity is unknown exactly when its spelling is not one `norm_sev` knows.
export
unknownExactly : (r : RawSev) -> (normSev r = Unknown) -> isUnknownRaw r = True
unknownExactly ROther Refl = Refl

||| Every known spelling ranks at least 1, so it can never pass as clean.
export
knownRanks : (r : RawSev) -> isUnknownRaw r = False -> (k : Nat ** rank (normSev r) = S k)
knownRanks RCritical      Refl = (4 ** Refl)
knownRanks RHigh          Refl = (3 ** Refl)
knownRanks RError         Refl = (3 ** Refl)
knownRanks RMedium        Refl = (2 ** Refl)
knownRanks RWarn          Refl = (2 ** Refl)
knownRanks RWarning       Refl = (2 ** Refl)
knownRanks RLow           Refl = (1 ** Refl)
knownRanks RInfo          Refl = (0 ** Refl)
knownRanks RInformational Refl = (0 ** Refl)
knownRanks RNote          Refl = (0 ** Refl)
knownRanks RSuggestion    Refl = (0 ** Refl)
knownRanks ROther         prf  = absurd prf

-- ── Findings and envelopes ────────────────────────────────────────────────

||| `bucket`'s result for a finding: graded findings set the colour; standing
||| and excluded ones are counted in the accordion only.
public export
data Bucket = Graded | Standing | Excluded

public export
record Finding where
  constructor MkFinding
  raw    : RawSev
  bucket : Bucket

||| A report-back envelope, as `reportback` classifies it.
public export
data Envelope
  = NotJson          -- not valid JSON
  | NotObject        -- JSON, but not an object
  | BadIdentity      -- `reporter` or `title` present but not a nonempty string
  | RanUnreadable    -- status ran, findings not an array of objects
  | Ran (List Finding)
  | NotRun           -- status not_run
  | Failed           -- status error
  | NotApplicable    -- status not_applicable
  | OtherStatus      -- any other status, or none

public export
data Status = SRan (List Finding) | SNotRun | SError | SNotApplicable

public export
anyUnknown : List Finding -> Bool
anyUnknown []        = False
anyUnknown (f :: fs) = isUnknownRaw f.raw || anyUnknown fs

||| `reportback` followed by `reporter`'s unknown-severity rule.
public export
reportback : Envelope -> Status
reportback NotJson       = SError
reportback NotObject     = SError
reportback BadIdentity   = SError
reportback RanUnreadable = SError
reportback (Ran fs)      = if anyUnknown fs then SError else SRan fs
reportback NotRun        = SNotRun
reportback Failed        = SError
reportback NotApplicable = SNotApplicable
reportback OtherStatus   = SError

||| An entry in the enrolment manifest: `enrolled == true`, present with any
||| other value, or absent.
public export
data Enrol = Enrolled | NotEnrolled | Unlisted

||| `build`: an envelope decides the row whatever the manifest says; without
||| one, the manifest does; an unlisted member with no envelope has no row.
public export
row : Maybe Envelope -> Enrol -> Maybe Status
row (Just e) _          = Just (reportback e)
row Nothing Enrolled    = Just SNotRun
row Nothing NotEnrolled = Just SNotApplicable
row Nothing Unlisted    = Nothing

-- ── Colour ────────────────────────────────────────────────────────────────

public export
data Colour = Purple | Red | Orange | Yellow | Blue | Green | Grey

public export
mx : Nat -> Nat -> Nat
mx Z     n     = n
mx (S m) Z     = S m
mx (S m) (S n) = S (mx m n)

||| The worst rank among GRADED findings (0 when there are none).
public export
worst : List Finding -> Nat
worst [] = 0
worst (MkFinding r Graded :: fs)   = mx (rank (normSev r)) (worst fs)
worst (MkFinding _ Standing :: fs) = worst fs
worst (MkFinding _ Excluded :: fs) = worst fs

public export
colourOf : Nat -> Colour
colourOf 0 = Green
colourOf 1 = Blue
colourOf 2 = Blue
colourOf 3 = Yellow
colourOf 4 = Red
colourOf (S (S (S (S (S _))))) = Purple

||| `state`.
public export
state : Status -> Colour
state SNotApplicable = Grey
state SNotRun        = Orange
state SError         = Orange
state (SRan fs)      = colourOf (worst fs)

public export
graded : List Finding -> List Finding
graded [] = []
graded (MkFinding r Graded :: fs)   = MkFinding r Graded :: graded fs
graded (MkFinding _ Standing :: fs) = graded fs
graded (MkFinding _ Excluded :: fs) = graded fs

-- ── Lemmas on mx ──────────────────────────────────────────────────────────

mxZeroLeft : (a, b : Nat) -> mx a b = 0 -> a = 0
mxZeroLeft Z _ _ = Refl
mxZeroLeft (S _) Z prf = absurd prf
mxZeroLeft (S _) (S _) prf = absurd prf

mxZeroRight : (a, b : Nat) -> mx a b = 0 -> b = 0
mxZeroRight Z _ prf = prf
mxZeroRight (S _) Z _ = Refl
mxZeroRight (S _) (S _) prf = absurd prf

mxUpperLeft : (a, b : Nat) -> LTE a (mx a b)
mxUpperLeft Z _ = LTEZero
mxUpperLeft (S a) Z = reflexive
mxUpperLeft (S a) (S b) = LTESucc (mxUpperLeft a b)

mxUpperRight : (a, b : Nat) -> LTE b (mx a b)
mxUpperRight Z b = reflexive
mxUpperRight (S a) Z = LTEZero
mxUpperRight (S a) (S b) = LTESucc (mxUpperRight a b)

-- ── Theorems ──────────────────────────────────────────────────────────────

||| Missing evidence is never clean: a member with no envelope is orange
||| when enrolled, grey with its reason when not, and absent otherwise.
export
noEnvelopeNeverGreen : (en : Enrol) -> (s : Status) -> row Nothing en = Just s -> Not (state s = Green)
noEnvelopeNeverGreen Enrolled    SNotRun        Refl Refl impossible
noEnvelopeNeverGreen NotEnrolled SNotApplicable Refl Refl impossible
noEnvelopeNeverGreen Unlisted    _              Refl _   impossible

||| "enrolled, but no report-back was received" is orange.
export
enrolledMissingIsOrange : map ReportBack.state (row Nothing Enrolled) = Just Orange
enrolledMissingIsOrange = Refl

||| An envelope decides its own row, whatever the manifest says about it.
export
envelopeDecides : (e : Envelope) -> (en, en' : Enrol) -> row (Just e) en = row (Just e) en'
envelopeDecides _ _ _ = Refl

||| A not_run, error, malformed or unrecognised envelope is orange.
export
notRanIsOrange : (state (reportback NotJson) = Orange, state (reportback NotObject) = Orange,
                  state (reportback BadIdentity) = Orange, state (reportback RanUnreadable) = Orange,
                  state (reportback NotRun) = Orange, state (reportback Failed) = Orange,
                  state (reportback OtherStatus) = Orange)
notRanIsOrange = (Refl, Refl, Refl, Refl, Refl, Refl, Refl)

||| A ran envelope carrying a severity the grid does not know is orange,
||| never green: unknown ranks 0, the same as no finding.
export
unknownIsOrange : (fs : List Finding) -> anyUnknown fs = True -> state (reportback (Ran fs)) = Orange
unknownIsOrange fs prf = rewrite prf in Refl

||| With no unknown severity, a graded finding forces a nonzero worst rank.
zeroWorstNoGraded : (fs : List Finding) -> anyUnknown fs = False -> worst fs = 0 -> graded fs = []
zeroWorstNoGraded [] _ _ = Refl
zeroWorstNoGraded (MkFinding r Graded :: fs) nu w with (isUnknownRaw r) proof pr
  zeroWorstNoGraded (MkFinding r Graded :: fs) nu w | True = absurd nu
  zeroWorstNoGraded (MkFinding r Graded :: fs) nu w | False =
    let (k ** rk) = knownRanks r pr
        z = mxZeroLeft (rank (normSev r)) (worst fs) w
    in absurd (trans (sym rk) z)
zeroWorstNoGraded (MkFinding r Standing :: fs) nu w with (isUnknownRaw r)
  zeroWorstNoGraded (MkFinding r Standing :: fs) nu w | True = absurd nu
  zeroWorstNoGraded (MkFinding r Standing :: fs) nu w | False = zeroWorstNoGraded fs nu w
zeroWorstNoGraded (MkFinding r Excluded :: fs) nu w with (isUnknownRaw r)
  zeroWorstNoGraded (MkFinding r Excluded :: fs) nu w | True = absurd nu
  zeroWorstNoGraded (MkFinding r Excluded :: fs) nu w | False = zeroWorstNoGraded fs nu w

greenIsZero : (n : Nat) -> colourOf n = Green -> n = 0
greenIsZero 0 _ = Refl
greenIsZero 1 Refl impossible
greenIsZero 2 Refl impossible
greenIsZero 3 Refl impossible
greenIsZero 4 Refl impossible
greenIsZero (S (S (S (S (S _))))) Refl impossible

||| Green means exactly this: the envelope said ran, its findings were
||| readable, and none of them is graded against this change.
export
greenOnlyFromCleanRan : (e : Envelope) -> state (reportback e) = Green
                     -> (fs : List Finding ** (e = Ran fs, graded fs = []))
greenOnlyFromCleanRan NotJson       Refl impossible
greenOnlyFromCleanRan NotObject     Refl impossible
greenOnlyFromCleanRan BadIdentity   Refl impossible
greenOnlyFromCleanRan RanUnreadable Refl impossible
greenOnlyFromCleanRan NotRun        Refl impossible
greenOnlyFromCleanRan Failed        Refl impossible
greenOnlyFromCleanRan NotApplicable Refl impossible
greenOnlyFromCleanRan OtherStatus   Refl impossible
greenOnlyFromCleanRan (Ran fs) prf with (anyUnknown fs) proof pu
  greenOnlyFromCleanRan (Ran fs) Refl | True impossible
  greenOnlyFromCleanRan (Ran fs) prf | False =
    (fs ** (Refl, zeroWorstNoGraded fs pu (greenIsZero (worst fs) prf)))

colourNeverGrey : (n : Nat) -> Not (colourOf n = Grey)
colourNeverGrey 0 Refl impossible
colourNeverGrey 1 Refl impossible
colourNeverGrey 2 Refl impossible
colourNeverGrey 3 Refl impossible
colourNeverGrey 4 Refl impossible
colourNeverGrey (S (S (S (S (S _))))) Refl impossible

||| Grey never masks a finding: it comes only from not_applicable.
export
greyOnlyFromNotApplicable : (e : Envelope) -> state (reportback e) = Grey -> e = NotApplicable
greyOnlyFromNotApplicable NotJson       Refl impossible
greyOnlyFromNotApplicable NotObject     Refl impossible
greyOnlyFromNotApplicable BadIdentity   Refl impossible
greyOnlyFromNotApplicable RanUnreadable Refl impossible
greyOnlyFromNotApplicable NotRun        Refl impossible
greyOnlyFromNotApplicable Failed        Refl impossible
greyOnlyFromNotApplicable NotApplicable _   = Refl
greyOnlyFromNotApplicable OtherStatus   Refl impossible
greyOnlyFromNotApplicable (Ran fs) prf with (anyUnknown fs)
  greyOnlyFromNotApplicable (Ran fs) Refl | True impossible
  greyOnlyFromNotApplicable (Ran fs) prf | False = void (colourNeverGrey (worst fs) prf)

||| Standing and excluded findings never change a row's colour.
export
onlyGradedCount : (fs : List Finding) -> worst fs = worst (graded fs)
onlyGradedCount [] = Refl
onlyGradedCount (MkFinding r Graded :: fs)   = cong (mx (rank (normSev r))) (onlyGradedCount fs)
onlyGradedCount (MkFinding _ Standing :: fs) = onlyGradedCount fs
onlyGradedCount (MkFinding _ Excluded :: fs) = onlyGradedCount fs

||| Adding a finding never lowers the worst rank: a row cannot get cleaner
||| by reporting more.
export
worstMonotone : (f : Finding) -> (fs : List Finding) -> LTE (worst fs) (worst (f :: fs))
worstMonotone (MkFinding r Graded) fs   = mxUpperRight (rank (normSev r)) (worst fs)
worstMonotone (MkFinding _ Standing) fs = reflexive
worstMonotone (MkFinding _ Excluded) fs = reflexive

||| Every graded finding's rank is bounded by the row's worst rank.
export
gradedBounded : (r : RawSev) -> (fs : List Finding) -> Elem (MkFinding r Graded) fs
             -> LTE (rank (normSev r)) (worst fs)
gradedBounded r (MkFinding r Graded :: fs) Here = mxUpperLeft (rank (normSev r)) (worst fs)
gradedBounded r (MkFinding r' b :: fs) (There later) =
  transitive (gradedBounded r fs later) (worstMonotone (MkFinding r' b) fs)

purpleFromFive : (n : Nat) -> LTE 5 n -> colourOf n = Purple
purpleFromFive 0 lte = absurd lte
purpleFromFive 1 (LTESucc lte) = absurd lte
purpleFromFive 2 (LTESucc (LTESucc lte)) = absurd lte
purpleFromFive 3 (LTESucc (LTESucc (LTESucc lte))) = absurd lte
purpleFromFive 4 (LTESucc (LTESucc (LTESucc (LTESucc lte)))) = absurd lte
purpleFromFive (S (S (S (S (S _))))) _ = Refl

||| A graded critical cannot be masked by anything else in the envelope.
export
gradedCriticalIsPurple : (fs : List Finding) -> anyUnknown fs = False
                      -> Elem (MkFinding RCritical Graded) fs
                      -> state (reportback (Ran fs)) = Purple
gradedCriticalIsPurple fs nu el =
  rewrite nu in purpleFromFive (worst fs) (gradedBounded RCritical fs el)

-- ── The case table for the differential test ─────────────────────────────

rawWord : RawSev -> String
rawWord RCritical      = "critical"
rawWord RHigh          = "high"
rawWord RError         = "error"
rawWord RMedium        = "medium"
rawWord RWarn          = "warn"
rawWord RWarning       = "warning"
rawWord RLow           = "low"
rawWord RInfo          = "info"
rawWord RInformational = "informational"
rawWord RNote          = "note"
rawWord RSuggestion    = "suggestion"
rawWord ROther         = "catastrophic"

bucketWord : Bucket -> String
bucketWord Graded   = "graded"
bucketWord Standing = "standing"
bucketWord Excluded = "excluded"

colourWord : Colour -> String
colourWord Purple = "purple"
colourWord Red    = "red"
colourWord Orange = "orange"
colourWord Yellow = "yellow"
colourWord Blue   = "blue"
colourWord Green  = "green"
colourWord Grey   = "grey"

envelopeWord : Envelope -> String
envelopeWord NotJson       = "not_json"
envelopeWord NotObject     = "not_object"
envelopeWord BadIdentity   = "bad_identity"
envelopeWord RanUnreadable = "ran_unreadable"
envelopeWord (Ran _)       = "ran"
envelopeWord NotRun        = "not_run"
envelopeWord Failed        = "error"
envelopeWord NotApplicable = "not_applicable"
envelopeWord OtherStatus   = "other_status"

findingsWord : List Finding -> String
findingsWord [] = "-"
findingsWord [f] = rawWord f.raw ++ ":" ++ bucketWord f.bucket
findingsWord (f :: fs) = rawWord f.raw ++ ":" ++ bucketWord f.bucket ++ "," ++ findingsWord fs

allRaw : List RawSev
allRaw = [RCritical, RHigh, RError, RMedium, RWarn, RWarning, RLow, RInfo,
          RInformational, RNote, RSuggestion, ROther]

allFindings : List Finding
allFindings = [MkFinding r b | r <- allRaw, b <- [Graded, Standing, Excluded]]

||| Every finding list of length 0, 1 or 2 (1 + 36 + 1296 lists).
findingLists : List (List Finding)
findingLists = [[]] ++ [[f] | f <- allFindings] ++ [[f, g] | f <- allFindings, g <- allFindings]

envelopes : List Envelope
envelopes = [NotJson, NotObject, BadIdentity, RanUnreadable, NotRun, Failed,
             NotApplicable, OtherStatus] ++ map Ran findingLists

caseLine : Envelope -> String
caseLine e@(Ran fs) = envelopeWord e ++ "\t" ++ findingsWord fs ++ "\t" ++ colourWord (state (reportback e))
caseLine e          = envelopeWord e ++ "\t-\t" ++ colourWord (state (reportback e))

missingLine : Enrol -> String
missingLine Enrolled    = "missing\tenrolled\t" ++ maybe "none" (colourWord . state) (row Nothing Enrolled)
missingLine NotEnrolled = "missing\tnot_enrolled\t" ++ maybe "none" (colourWord . state) (row Nothing NotEnrolled)
missingLine Unlisted    = "missing\tunlisted\t" ++ maybe "none" (colourWord . state) (row Nothing Unlisted)

||| Prints the model's expected colour for every case, one per line:
||| envelope, findings (severity:bucket, comma-separated, "-" for none),
||| colour. The missing-envelope lines put the enrolment in column 2.
export
main : IO ()
main = do
  traverse_ (putStrLn . caseLine) envelopes
  traverse_ (putStrLn . missingLine) [Enrolled, NotEnrolled, Unlisted]
