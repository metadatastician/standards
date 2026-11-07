K9!
# SPDX-License-Identifier: MPL-2.0
# proof-witness-grades.k9.ncl — the Proof Witness Grade (PWG) ladder as data.
#
# Normative source: 3-practice/PROOF-POLICY.adoc §8 (owner ruling 2026-11-04).
# This file is a machine-readable mirror for bots and gates: when it and the
# prose disagree, the prose governs and this file is the thing to fix, in the
# same change. A gate that reads it pins this repository, this path and a
# full 40-character commit (PROOF-POLICY §7).
#
# Kennel: data only, never evaluated with effects.
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "proof-policy-data",
    security = {
      leash = 'Kennel,
      trust_level = "data-only",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,
      capabilities = [],
    },
    metadata = {
      name = "proof-witness-grades",
      version = "1.0.0",
      description = "Proof Witness Grade ladder (PROOF-POLICY §8): labels, order, counting rules and claim rules for theory theorems.",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
    side_effects = [],
  },

  config = {
    policy = {
      repository = "hyperpolymath/standards",
      repository_aliases = ["metadatastician/standards"],
      path = "3-practice/PROOF-POLICY.adoc",
      section = "8",
      anchor = "proof-witness-grades",
      ruled = "2026-11-04",
      provenance = "hyperpolymath/mathesis docs/proposals/estate-mathematical-architecture.adoc §5-§6 (unratified brief; superseded for grades by this policy)",
    },

    scope = {
      applies_to = "theory",
      not_graded = ["Creusot", "Verus", "SPARK", "Idris2"],
      below_lowest = "ungraded",
    },

    # Strongest first. Lower number is stronger.
    order_strongest_first = ["PWG-1", "PWG-2ii", "PWG-2i", "PWG-3", "ungraded"],

    labels = {
      canonical = ["PWG-3", "PWG-2i", "PWG-2ii", "PWG-1", "ungraded"],
      prose_aliases = [
        { alias = "PWG-2a", means = "PWG-2i" },
        { alias = "PWG-2b", means = "PWG-2ii" },
      ],
      prefix_required = true,
      forbidden_bare_forms = ["Grade 1", "Grade 2", "Grade 2i", "Grade 2ii", "Grade 3"],
    },

    grades = [
      {
        label = "PWG-3",
        requires = [
          "Agda proof PROVEN or PROVEN-WITH-AXIOMS under the §2.1 invocation (or a separately reviewed §2.1 profile)",
          "receipt records Agda version, stdlib pin, flags in force, import cone",
        ],
        counted_legs = 0,
      },
      {
        label = "PWG-2i",
        requires = ["PWG-3", "exactly one counted leg: Rocq or Lean"],
        counted_legs = 1,
      },
      {
        label = "PWG-2ii",
        requires = ["PWG-3", "Rocq leg counted", "Lean leg counted"],
        counted_legs = 2,
        discharges_recheck_obligation = true,
      },
      {
        label = "PWG-1",
        requires = [
          "PWG-2ii",
          "every counted witness (Agda, Rocq, Lean) has a current receipt from a headless, isolated, pinned checker run on the exact source commit",
        ],
        counted_legs = 2,
        receipt_fields = ["checker", "checker_version", "invocation", "input_digest", "result", "axioms", "source_repository", "source_commit_40"],
      },
    ],

    leg_counts_when = {
      status_tokens = ["proven", "proven-with-postulates"],
      correspondence_state = "RECONCILED",
      routes = ["transported", "re-proved"],
    },
    leg_never_counts = ["waived", "unavailable", "BRIDGE-PENDING", "transported-without-statement-comparison"],

    waiver_caps = [
      { waived_legs = 1, max_grade = "PWG-2i" },
      { waived_legs = 2, max_grade = "PWG-3" },
    ],

    tags = [
      {
        name = "+foundation-diverse",
        meaning = "an additional kernel-checked witness in a non-DTT foundation (e.g. Isabelle/HOL, HOL4, HOL Light, Metamath) with recorded statement correspondence",
        substitutes_for_leg = false,
      },
    ],

    rules = {
      grade_is_not_discharge = true,
      derived_not_asserted = true,
      claim_needs_receipts = true,
      regression_drops_grade = true,
      receipt_lineage_states = ["current", "superseded", "regressed"],
      status_vocabulary_closed = true,
      axioms_listed_per_witness = true,
      agda_axiom_mechanism = ["--safe", "comment-aware postulate scan of the import cone", "recorded import cone"],
      lean_axiom_mechanism = "#print axioms",
      rocq_axiom_mechanism = "Print Assumptions",
      census_not_percentage = true,
    },

    # Other estate schemes that also say "grade". None converts into PWG.
    not_to_be_confused_with = [
      { scheme = "CRG", values = "X F E D C B A", measures = "component readiness" },
      { scheme = "TRG", values = "X F E D C B A", measures = "toolchain readiness" },
      { scheme = "ARG", values = "X F E D C B A", measures = "adoption readiness" },
      { scheme = "FRG", values = "X F E D C B A", measures = "foundations readiness" },
      { scheme = "ECHIDNA TrustLevel", values = "1-5, higher is stronger", measures = "confidence in one dispatch result" },
      { scheme = "ECHIDNA EpistemicLevel", values = "Belief < Epi < Sound", measures = "whether fused verdicts denote the same statement" },
    ],
  },
}
