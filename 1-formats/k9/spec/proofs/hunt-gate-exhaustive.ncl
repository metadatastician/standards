# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# hunt-gate-exhaustive.ncl — the bridge between HuntGate.idr and the Nickel
# text of `authorize_hunt` (K9-CONTRACT-SPEC §9.2).
#
# HuntGate.idr proves the gate's properties for a model of `authorize_hunt`.
# This file checks that both Nickel copies — spec/contract/k9_contract.ncl and
# leash.ncl — compute that model, on every one of the 32 evidence
# combinations. The domain is finite, so this is a complete enumeration
# (PROOF-POLICY §5: TESTED, bound = all 2^5 inputs).
#
# The expected verdict for each input is the model's rule, written once:
#   unmet     = the names of the false flags, in contract order
#   permitted = unmet is empty;  enforced_level = 'Hunt if permitted else 'Yard
#
# `nickel export` fails (std.fail_with) on the first mismatch, naming it.
# Run from `k9-validate.sh --self-test`; it prints the number of cases checked.
let contract = import "../contract/k9_contract.ncl" in
let leash = import "../../leash.ncl" in
let names = ["signature", "policy", "sandbox", "dry_run", "capability_grant"] in
let bit = fun n i => std.number.truncate (n / (std.number.pow 2 i)) % 2 == 1 in
let evidence_of = fun n =>
  {
    signature = bit n 0,
    policy = bit n 1,
    sandbox = bit n 2,
    dry_run = bit n 3,
    capability_grant = bit n 4,
  }
in
let expected_unmet = fun e =>
  std.array.filter (fun k => !(std.record.get k e)) names
in
let check_one = fun label gate n =>
  let e = evidence_of n in
  let got = gate e in
  let want_unmet = expected_unmet e in
  let want_permit = std.array.length want_unmet == 0 in
  let want_level = if want_permit then 'Hunt else 'Yard in
  if got.permitted == want_permit
  && got.enforced_level == want_level
  && got.unmet_preconditions == want_unmet then
    true
  else
    std.fail_with "%{label}: authorize_hunt disagrees with the HuntGate.idr model on evidence case %{std.to_string n}"
in
let cases = std.array.generate (fun n => n) 32 in
let checked =
  std.array.length (std.array.filter (fun n => check_one "k9_contract.ncl" contract.authorize_hunt n) cases)
  + std.array.length (std.array.filter (fun n => check_one "leash.ncl" leash.authorize_hunt n) cases)
in
{ cases_checked = checked }
