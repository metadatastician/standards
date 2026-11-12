# SPDX-License-Identifier: MPL-2.0
# pedigree.ncl - The Breed Specification for .k9 SVC (v1.0.0 stable).
#
# Every .k9 component inherits from this pedigree. v1.0.0 restructures the
# pedigree into SEVEN explicit, named sections:
#
#   1. metadata             - identity
#   2. validation_contract  - what must pass before anything else
#   3. policy               - leash level + capability grant + target env
#   4. deploy_recipe        - how to install / validate / deploy / migrate
#   5. recovery_recipe      - how to roll back / recover / verify recovery (NEW)
#   6. signature            - cryptographic provenance
#   7. docs_rationale       - human rationale + the soft A2ML cross-reference (NEW)
#
# NAMING HAZARD — keep these two triads/quads DISTINCT in all prose:
#   * K9's execution triad is  must / just / nickel
#       (environment shim / task runner / validation engine).
#   * The contractiles family is  must / trust / dust / intend
#       (a different estate concept; NOT part of K9).
# "must" appears in both but means different things; never conflate them.
let SecurityLevel = [| 'Kennel, 'Yard, 'Hunt |] in
let Architecture = [| 'Linux, 'Minix, 'MacOS, 'Android, 'PC, 'ASIC, 'Unknown |] in

{
  # ─────────────────────────────────────────────────────────────
  # 1. metadata — Identity (L1: The Snout)
  # ─────────────────────────────────────────────────────────────
  Metadata = {
    name | String,
    version | String | default = "1.0.0",
    breed | String | default = "application/vnd.metadatastician.k9",
    magic_number | String | default = "K9!",
    description | String | optional,
  },

  # ─────────────────────────────────────────────────────────────
  # 2. validation_contract — What must pass first (L2: The Brain)
  # ─────────────────────────────────────────────────────────────
  ValidationContract = {
    # SHA256 of the component payload (canonical hash; see A2ML SPEC Section 9).
    checksum | String,
    # Version of this pedigree schema.
    pedigree_version | String | default = "1.0.0",
    # The Nickel contract files that MUST evaluate cleanly before use.
    contract_files | Array String | default = ["pedigree.ncl", "leash.ncl"],
    # Fail-closed: an invalid component refuses to run rather than degrade.
    must_pass | Bool | default = true,
  },

  # ─────────────────────────────────────────────────────────────
  # 3. policy — Leash + capabilities + target (L3: The Leash)
  # ─────────────────────────────────────────────────────────────
  #
  # 'Kennel: data-only, no eval. 'Yard: contract-eval only, no fs/net.
  # 'Hunt: controlled execution — requires ALL FIVE preconditions, always
  # (see leash.ncl authorize_hunt). Capabilities are DEFAULT-DENY: a component
  # is granted nothing unless listed here (names from capabilities.ncl).
  Target = {
    os | Architecture,
    is_edge | Bool | default = false,
    requires_podman | Bool | default = true,
    min_memory_mb | Number | default = 256,
  },
  Policy = {
    trust_level | SecurityLevel | default = 'Yard,
    # Explicit capability grant (default-deny). Each entry MUST be a core or
    # x- extension capability name from capabilities.ncl.
    capabilities | Array String | default = [],
    target | Target,
  },

  # ─────────────────────────────────────────────────────────────
  # 4. deploy_recipe — How to act (L4: The Muscle / Just)
  # ─────────────────────────────────────────────────────────────
  DeployRecipe = {
    install | String | default = "just install",
    validate | String | default = "just validate",
    deploy | String | default = "just deploy",
    migrate | String | default = "just migrate",
  },

  # ─────────────────────────────────────────────────────────────
  # 5. recovery_recipe — How to undo (NEW in v1.0.0)
  # ─────────────────────────────────────────────────────────────
  #
  # A deploy is only as safe as its rollback. Every Hunt-capable component
  # MUST declare how to undo what it did.
  RecoveryRecipe = {
    rollback | String | default = "just rollback",
    recover | String | default = "just recover",
    verify_recovery | String | default = "just verify-recovery",
    backup | String | optional,
  },

  # ─────────────────────────────────────────────────────────────
  # 6. signature — Cryptographic provenance
  # ─────────────────────────────────────────────────────────────
  Signature = {
    algorithm | String | default = "Ed25519",
    public_key | String | optional,
    signature | String | optional,
    # The payload hash that is signed (A2ML canonical hash form).
    payload_hash | String | optional,
    signed_at | String | optional,
    key_id | String | default = "primary",
  },

  # ─────────────────────────────────────────────────────────────
  # 7. docs_rationale — Human rationale + the soft A2ML bridge (NEW)
  # ─────────────────────────────────────────────────────────────
  DocsRationale = {
    summary | String | optional,
    rationale | String | optional,
    # The SINGLE soft cross-reference from a .k9 pedigree into A2ML. "Soft"
    # means advisory: a dangling reference is a WARNING, never a hard
    # validation failure. Points at an A2ML rationale/runbook artefact (a
    # repo-relative path, URI, or A2ML record id). This is the only A2ML
    # bridge field in the pedigree — K9 stays an independent foundation and
    # does not otherwise depend on A2ML.
    a2ml_ref | String | optional,
  },

  # ─────────────────────────────────────────────────────────────
  # The composed pedigree (seven sections)
  # ─────────────────────────────────────────────────────────────
  K9Pedigree = {
    metadata | Metadata,
    validation_contract | ValidationContract,
    policy | Policy,
    deploy_recipe | DeployRecipe,
    recovery_recipe | RecoveryRecipe,
    signature | Signature,
    docs_rationale | DocsRationale,
  },
}
