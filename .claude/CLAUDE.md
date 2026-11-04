# CLAUDE.md - AI Assistant Instructions

## Fork governance (read before changing a workflow)

Every pull request in this repository gets one generated comment, marked
`<!-- fork-governance-verdict: regenerated on every run -->`. It reports three
lanes in a fixed order: summary, **K9-DEED conformance**, **Hypatia verdict
grid**. The comment is produced by `.github/workflows/fork-governance.yml`
(lanes) and `.github/workflows/fork-governance-reusable.yml` (posting).

Documentation, in AsciiDoc, lives in `3-practice/fork-governance/` — `SPEC.adoc`
is normative for the comment's markers and order. Machine-readable route:
`:governance` in the `routing` clause of `standards_chora.deed`.

The fleet rows in the Hypatia grid are fed by the `fleet` job of
`fork-governance.yml` (gitbot-fleet `scripts/fleet-report-back.sh`, pinned by
`FLEET_REF`), which uploads the `fleet-report-backs` artifact that
`hypatia-scan-reusable.yml` downloads before rendering. `.gitbot-fleet/enrolment.json`
says which members apply; `.gitbot-fleet/report-backs/` stays empty in git.

Never hand-edit the comment, and never reorder the sections.

## License Policy — Manual Only (highest-priority guardrail)

**Owner directive 2026-06-02 (verbatim):**

> "mpl-2.0 (code) and CC-SA-BY-4.0 (prose) is for my sole repos, 
> exceptions for those shared with my son (follow his scheme), and leave other
> people's forked stuff alone … only palimpsest license for obvious
> reasons should be talking about palipsest and palimpsest plasma, and
> metadatastician/consent-aware-web, but in that case prospectively"

### Five-way classification (mutually exclusive, exhaustive)

| Category | License | Applies to |
|---|---|---|
| **1. Sole owner repos (default)** | `MPL-2.0` | Every repo the owner authored alone. ~all of `hyperpolymath/*` unless one of the other categories applies. |
| **2. The 007 repo** | All Rights Reserved (ARR) | `hyperpolymath/007` specifically. Out-of-scope for any normalisation, scanning, or labelling. Surface to owner only. |
| **3. Shared with son (Joshua)** | `AGPL-3.0-or-later` | Repos with son as co-author/maintainer. Examples: `idaptik`, `paint-type`. Permanent. |
| **4. Third-party / forks** | DO NOT TOUCH | Whatever upstream chose. Never sweep, never normalise. Flag as out-of-scope if it surfaces in an audit. |
| **5. Palimpsest register** | `PMPL-1.0-or-later` | **Only repos named in the register** in `3-practice/LICENCE-POLICY.adoc` Rule 2 — currently five: `palimpsest-license`, `palimpsest-plasma`, `metadatastician/consent-aware-web` (prospectively only — don't flip existing content), `insolvency-tycoon`, `sim-public-relations`. The cap of three was lifted 2026-08-26 as the Palimpsest family develops; the register is a growing **allowlist**, so PMPL in an unlisted repo is still drift. `3-practice/LICENCE-POLICY.adoc` is authoritative — do not duplicate the list's contents here. |

### Hard rules for agents

- **NEVER generate licence-change PRs without prior owner approval.** Manual,
  per-file, restricted to registered codeowner-admins. Triggered by neurophone#99 (auto-PR reverting PMPL →
  MPL-2.0 across ~140 files; closed by owner 2026-06-02).
- **NEVER sweep SPDX headers in bulk.** Every prior LLM sweep has scrambled
  identifiers, mis-licensed third-party code, or reverted owner decisions.
- **NEVER touch third-party / vendored / forked licence text or headers.**
  Flag only — never edit.
- **Findings about licence drift are FLAG-ONLY.** Hypatia / gitbot-fleet emit
  these as `:review` strategy, not `:auto_execute`. Downstream pipelines MUST
  honour the cap.
- **New files an agent creates may carry the correct SPDX from birth** (that
  is authoring, not relicensing) — but the SPDX choice must match the repo's
  classification above, not a hard-coded default.

### Canonical sources

- `~/.claude/projects/.../memory/feedback_estate_license_policy_umbrella.md` —
  canonical estate-level policy (supersedes the earlier `reference_estate_licensing_policy`).
- `~/.claude/projects/.../memory/feedback_no_automated_licence_edits.md` —
  no-sweep mandate.
- `hyperpolymath/hypatia` `lib/rules/cicd_rules.ex` — `license_finding_strategy/0`
  + `license_finding_severity_cap/1` + `license_related_finding?/1` +
  `owner_license_classification/0`: the canonical Elixir-side cap.
- `hyperpolymath/gitbot-fleet` `scripts/dispatch-runner.sh` — `execute_entry()`
  early-exit refusal gate for any licence/SPDX recipe or category.
- `hyperpolymath/gitbot-fleet` `scripts/fix-license-{hygiene,file}.sh` +
  `fix-missing-spdx.sh` — all three carry `exit 1` refusal banners at the top.

---

## Machine-Readable Artefacts

**A2ML is retired** (owner rulings D99, D269c, D312, D313). Never create,
restore, regenerate or extend a `.a2ml` file, and never write a "new" A2ML
file in a different shape. Machine-readable repo metadata has three forms.
Each has a normative grammar in this repository:

| What | File | Grammar (normative) | Check |
|---|---|---|---|
| Repo facts: identity, state, meta, ecosystem, agentic, neurosym, playbook, and the `(bot-directives …)` and `(contractiles …)` clauses | `<repo>_chora.deed` at the repo root, one per repo (D312) | `1-formats/deed/spec/abnf/deed.abnf` (D308; prose: `1-formats/deed/spec/DEED-GRAMMAR-SPEC.adoc`) | `bun 1-formats/deed/tools/deed_lint.js FILE.deed` |
| Contracts | `*.k9.ncl` | `1-formats/k9/spec/K9-CONTRACT-SPEC.adoc` | `1-formats/k9/tools/k9-validate.sh --strict FILE` |
| Agent coordination | `coordination.k9` at the repo root: first line `K9!`, `schema_version: 1.2.0` | `2-protocols/k9-coordination/spec/abnf/coordination-k9-grammar_v1.2.abnf` (prose: `2-protocols/k9-coordination/spec/COORDINATION-K9-SPEC.adoc`) | No validator script exists yet, and a generic YAML parser does not conform. The generator is `2-protocols/k9-coordination/tools/k9-init/`. |

- **Translating old content.** The mapping specs in `1-formats/deed/mappings/`,
  one per former A2ML family, decide where its content goes. Anything a
  mapping spec does not list does not translate.
- **The worked model** is `rsr-template-repo_chora.deed` in
  `hyperpolymath/rsr-template-repo`.
- **No bulk conversion.** Do not hand-convert A2ML in bulk, and do not use the
  Python converters in `1-formats/deed/tools/`. Conversion becomes kyX's first
  front end (D313), and Python is banned.
- **A deed is not TOML.** A file containing `key = value` or `[section]` is not
  a deed. `(` is the only bracket. Booleans are `#t`/`#f`. Enums are symbols
  (`:primary fv`, not `:primary "fv"`). UUIDs are `#u5"…"` literals.
  `:schema-version` appears exactly once at the top level.
- **Existing `.a2ml` files**, here and in other repos, are legacy awaiting
  migration. You may delete content from one; never add a fact to one.

`.machine_readable/descriptiles/` stays the directory for descriptive anchors
that are not yet folded into the chora deed. The `.a2ml` files still in it are
legacy. Anything new written there is a `.deed`, such as
`provisioning_praxis.deed`, never a `.a2ml`.

---

## Language Policy (Hyperpolymath Standard)

### Proofs — which prover for which obligation

Owner ruling 2026-10-26 (settles standards#692). Normative source:
`3-practice/PROOF-POLICY.adoc`; read it, not a paraphrase.

| Code or obligation | Verifier |
|---|---|
| Rust code | **Creusot** |
| Ada code | **SPARK** |
| APIs, ABIs, engineering properties | **Idris2** |
| Theory | **Agda**, rechecked in **Rocq** and **Lean** (Dedukti transport first, hand re-proof as fallback; no Mathlib) |

Another tool (Isabelle/HOL, F*, TLA+, ...) only where it is plainly the right
one, with the reason recorded beside the artefact (policy §4).

Standing Rust exceptions, alongside Creusot and never instead of it (§4.1):
**Kani** for `unsafe` and FFI seams (reported `TESTED` with bounds), **Aeneas**
where Rust implements an Agda-proved theorem (no Aeneas backend qualifies
yet, so its results are `ASSUMED`). Verus is not adopted.

Third-party code (crates such as Bevy, libraries, forks) is **not** converted
or re-proved (§1.1): state what a proof relies on as an `ASSUMED` boundary
spec, and when choosing between equally fitting dependencies, prefer one that
carries its own verification. A preference, not a gate.

The 2026-04-10 note "Rust always means Rust/SPARK" is **withdrawn**: Rust
means Rust, verified with Creusot; SPARK belongs to Ada code.

### ALLOWED Languages & Tools

| Language/Tool | Use Case | Notes |
|---------------|----------|-------|
| **AffineScript** | Primary application code | Compiles to typed-wasm; affine/linear types. Replaces ReScript across the estate (RS/TS/JS → AffineScript → typed-wasm). |
| **Bun** | JS runtime & package management (tier 1) | Default for all new work. Runs compiled ESM/JS directly — no bundler step. Uses an npm-compatible `package.json` plus `bun.lock` — both are expected, not anti-patterns. |
| **Deno** | JS runtime (tier 2) | Permitted, not gated (owner ruling 2026-10-14; order Bun > Deno > pnpm > npm). Reads the same `package.json`; every package carries a generated `deno.lock` (`tools/js-runtimes regen`, `3-practice/LANGUAGE-POLICY.adoc` §1.4). |
| **Rust** | Performance-critical, systems, WASM, CLI tools, safety-critical | Verified with Creusot (`3-practice/PROOF-POLICY.adoc`). Preferred over Ada where reachable. |
| **Zig** | **APIs, FFIs, gateways, client SDKs (estate default 2026-05-28)**, memory-safe systems where Rust is overkill | Zig is the estate-wide default for all API/FFI/gateway/client-SDK work unless explicitly special-cased; Idris2 owns ABIs. Completed V-lang→Zig migration 2026-05-28. |
| **Idris2** | Proofs about APIs, ABIs and engineering properties | Per `3-practice/PROOF-POLICY.adoc`. ATS2 rejected. Proven-library status in `proven` repo. |
| **Agda** | Theory proofs (source of truth; rechecked in Rocq and Lean) | Per `3-practice/PROOF-POLICY.adoc`. Used by `hyperpolymath/echo-types` (loss-with-residue / proof-relevant fibers) and other foundational formalisations. Constructive only — no postulates in load-bearing tracks. |
| **echo-types library** | Loss-with-residue formalism (Agda) | `hyperpolymath/echo-types` — canonical formalisation of `Echo f y := Σ (x : A) , (f x ≡ y)`. Cite from this lib rather than reinventing in downstream code. |
| **Tauri 2.0+** | Mobile apps (iOS/Android) | Rust backend + web UI |
| **Dioxus** | Mobile apps (native UI) | Pure Rust, React-like |
| **Gleam** | Backend services | Runs on BEAM or compiles to JS |
| **Elixir** | Backend services, distributed systems | BEAM, Phoenix, OTP |
| **Haskell** | Type-heavy tools, registry validation | Scaffoldia CLI |
| **Bash/POSIX Shell** | Scripts, automation | Keep minimal |
| **JavaScript** | Only where AffineScript cannot | MCP protocol glue, runtime APIs (transitional; prefer .affine where possible) |
| **Nickel** | Configuration language | For complex configs |
| **deed** | Repo metadata (`<repo>_chora.deed`) | S-expression format; grammar `1-formats/deed/spec/abnf/deed.abnf`. Replaces A2ML, which is retired. See Machine-Readable Artefacts above. |
| **k9** | Contracts (`*.k9.ncl`) and agent coordination (`coordination.k9`) | Grammars and validators in `1-formats/k9/` and `2-protocols/k9-coordination/`. |
| **Julia** | Batch scripts, data processing | Per RSR |
| **OCaml** | AffineScript compiler | Language-specific |
| **Ada** (legacy) | Safety-critical systems where Rust is not yet reachable | Verified with SPARK. Rust is absorbing most Ada work over time. Do not start new pure-Ada projects unless Rust cannot reach. |

> **Corrected 2026-08-07.** This section previously listed **Bun** as banned
> with **Deno** as its replacement, and described Deno as "replaces Node/npm/bun".
> That inverted `3-practice/LANGUAGE-POLICY.adoc` §1, which has ruled Bun > Deno > pnpm > npm
> since 2026-07-29. Because this file is what agents read first, the recorded
> ruling and agent behaviour had diverged: agents were being instructed to migrate
> *away* from the estate's first-choice runtime.
>
> **RESOLVED 2026-08-25 — this file governs.** The contradiction previously
> flagged here (this table bans TypeScript in favour of AffineScript, while
> `3-practice/LANGUAGE-POLICY.adoc` §1.2 stated "TypeScript is *permitted under Bun*") has
> been ruled by the owner: **AffineScript governs.** `3-practice/LANGUAGE-POLICY.adoc` §1.2
> was the error and has been rewritten to match.
>
> The distinction that keeps both documents coherent: **Bun is the runtime, tier 1
> and unchanged; AffineScript is the language for new application code.** Those
> were run together in the withdrawn text.
>
> ⚠ **TIGHTENED 2026-08-27 — owner ruling.** Asked about the Bun row advertising direct
> `.ts` execution, the owner ruled: *"no typescript … that should not exist at all."*
> The previous sentence here read "TypeScript is permitted only where AffineScript cannot
> reach". That is now **too permissive**: TypeScript is not a fallback tier, and no tool
> description in this file may advertise TypeScript support. Every `.ts` reference has been
> removed from the Bun row, including "JS/TS" in its label.
>
> ⚠ **This collides with the "TypeScript Exemptions (Approved)" table below**, which
> documents real technical carve-outs — `.d.ts` declaration files, the VS Code extension
> host (npm/Node-native, `@vscode/test-electron` has no alternative), and MCP/LSP protocol
> glue. Those are **not** stylistic preferences and cannot simply be deleted. They are left
> standing and flagged for an explicit owner decision: either retire each carve-out with a
> migration path, or restate the rule as "no new TypeScript, these listed exemptions
> excepted". **Not resolved unilaterally.**
>
> ReScript's ban is uncontested, and its migration destination is **AffineScript**.

> **RULED 2026-10-14 — Deno is permitted again (tier 2).** The owner: *"deno does not need to be absolutely banned"*; the order is **Bun > Deno > pnpm > npm**, npm only as the last resort. The 2026-08-26 and 2026-09-22 rulings quoted below are **superseded**: Deno is back in ALLOWED, its refusal gate and the `deno-allow.txt` ledger are retired, and every package carries all the runtimes' locks through `tools/js-runtimes` (`3-practice/LANGUAGE-POLICY.adoc` §1.3–§1.4). Bun stays first everywhere, and each repository's environment (mise, containers, Guix) provisions it (`js-runtimes provision`).
>
> **SUPERSEDED 2026-08-26 — Deno is no longer tier 2.** The owner ruled:
> *"deno is to go and bun is the way we are going, put it first everywhere unless not
> possible and explain why if not."* The "Bun > Deno > pnpm > npm" ordering above described
> a **preference**; it is now a **removal**. Deno has been **moved out of ALLOWED into BANNED** accordingly - a struck-through row in an ALLOWED table is ambiguous to the agents that read this file (codacy raised exactly that on #655).
>
> This matters because this file is what agents read first. While it said Deno was
> "grandfathered … need not migrate", agents correctly declined to migrate — and the
> dependency rules below compounded it: *"No package.json for runtime deps — use deno.json
> imports"* left repos with **no manifest at all**. `hyperpolymath/ubicity` could not build
> under any toolchain for exactly this reason (see ubicity#107). Both rules are corrected.

### BANNED - Do Not Use

| Banned | Replacement | Notes |
|--------|-------------|-------|
| TypeScript | AffineScript | RS/TS/JS → AffineScript → typed-wasm. |
| ReScript | AffineScript | RS/TS/JS → AffineScript → typed-wasm. |
| **ReScript** | AffineScript | Banned in new code as of 2026-04-30. Existing `.res` files migrate to `.affine` directly (do not pass through ReScript). |
| Node.js | Bun | Bun is Node-compatible; run the code, drop the runtime. |
| npm | Bun | npm is tier 4 — the last resort: *permitted, never preferred*, not banned. `package-lock.json` must still not be tracked (standards#67). |
| yarn | Bun | yarn is not in the tier list at all. |
| Go | Rust | |
| **Python** | AffineScript/Rust/Julia | Fully banned, no exceptions (SaltStack exception removed 2026-01-03) |
| Java/Kotlin | Rust, Tauri, Dioxus | |
| Swift | Tauri/Dioxus | |
| React Native | Tauri/Dioxus | |
| Flutter/Dart | Tauri/Dioxus | Google lock-in |
| **V-lang** | Zig | Banned 2026-04-10; migration **COMPLETED 2026-05-28** across 16 PRs. Detected via hypatia `cicd_rules/vlang_detected` (`*.v` files) + `cicd_rules/vmod_detected` (`v.mod` manifest) with `path_allow_prefixes` mechanism for: v-ecosystem R&D carve-out, asdf-vlang toolchain installers, Coq proof scripts (`.v` shared with Coq + Verilog), interop targets (`/v-cartridge`, `/v-adapter`, `/v-bindings`, `/v-client` — where we expose work to V consumers without writing V), archived repos (`polystack/`). |
| **ATS2** | Idris2 (formal), Rust (safety-critical operational) | Rejected in favour of Idris2 and Rust. |
| **Makefiles** | Mustfile/justfile | |

**NOTE:** Python is fully banned. V-lang is fully banned (2026-04-10). ATS2 is
fully banned in favour of Idris2 + Rust. ReScript is fully banned in new
code as of 2026-04-30 (use AffineScript). All four bans are enforced by
`.github/workflows/language-policy.yml`.

### Build System

All repositories use Mustfile/justfile instead of Makefiles:

- `Mustfile` - Mandatory checks definition
- `justfile` - Build recipes (https://just.systems)
- `mustfile.toml` - Configuration (optional)

See: https://github.com/hyperpolymath/mustfile

### Mobile Development

**No exceptions for Kotlin/Swift** - use Rust-first approach:

1. **Tauri 2.0+** - Web UI (AffineScript → typed-wasm) + Rust backend, MIT/Apache-2.0
2. **Dioxus** - Pure Rust native UI, MIT/Apache-2.0

Both are FOSS with independent governance (no Big Tech).

### Enforcement Rules

1. **No new TypeScript or ReScript files** - Convert existing TS/RS to AffineScript directly (`.affine`); ReScript is no longer the destination.
   **Convert proactively at the earliest opportunity** — treat any `.ts`/`.res`
   (or otherwise-banned front-end language) as standing background work to port,
   not a one-off, subject to two guardrails:
   - **Portable-now only.** The `js-to-affinescript` doctrine
     (`docs/migrations/js-to-affinescript`) carves out MCP/LSP protocol glue and
     VSCode-host code (*"MCP glue … Should NOT appear in `portable now`"*). Those
     stay until the AffineScript MCP/LSP/VSCode bindings ship (affinescript#446).
     Genuinely-portable Deno CLI scripts are the convert-now bucket; anything not yet portable to AffineScript moves to **Bun**, not left on Deno.
   - **Compile-verify, wire-first.** A port is not done until the `.affine` builds
     green (`just check`) and the compiled output is wired as the live entry with
     the original removed *in the same PR*. Never ship an unbuilt `.affine` or
     delete a working `.ts`/`.res` for one that has not compiled.
2. **Use `package.json` + `bun.lock` for JS runtime deps** - Bun is npm-compatible; a manifest is REQUIRED. (This line previously said "No package.json - use deno.json imports", which left repos with undeclared dependencies that could not build under any toolchain.)
3. **`bun install --production` for production deps** - Bun resolves from `package.json` and pins via `bun.lock`
4. **No Go code** - Use Rust instead
5. **No Python** - All Python must be rewritten
6. **No Kotlin/Swift for mobile** - Use Tauri 2.0+ or Dioxus
7. **No Makefiles** - Use Mustfile/justfile instead

### Package Management

- **Primary**: Guix (guix.scm)
- **Nix**: retired — `flake.nix` is not accepted by Governance / Guix packaging policy; a repo with no `guix.scm` packages through a working Containerfile instead
- **JS deps**: **Bun** (`package.json` + `bun.lock`); `bunx <tool>` to run one-off tooling. `tools/js-runtimes regen` keeps `package.json` JCS and regenerates `bun.lock`, `deno.lock` and `pnpm-lock.yaml` together.

### Documentation Format

- All docs must be `.adoc` (AsciiDoc), **including `README.adoc`** — this is the estate default. GitHub renders AsciiDoc natively on the repo page, so the README, its community-health view, and the file-list tab bar all display correctly.
- GitHub-required `.md` (must be Markdown): 3-practice/SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md. (README is **not** in this list — see the README rule below.)
- **README is `.adoc` by default, with exactly two `.md` exceptions:**
  * `hyperpolymath/hyperpolymath` — the GitHub **profile** repo; profile READMEs render *only* `README.md`, never `.adoc`.
  * `hyperpolymath/boj-server` — surfaced in external MCP directories (Glama), which show AsciiDoc as raw markup.
  Everywhere else keep `README.adoc` and do **not** add a `README.md` alongside it. (This supersedes the short-lived 2026-06 "README must be `.md`" reversal, which was wrong: estate tooling — e.g. `rhodibot` — already treats `.adoc` as primary and deletes any stub `README.md`.)
- No duplicate formats for the `.adoc`-primary docs (if `ARCHITECTURE.adoc` etc. exists, don't also have `.md`)

### Security Requirements

- No MD5/SHA1 for security (use SHA256+)
- HTTPS only (no HTTP URLs)
- No hardcoded secrets
- SHA-pinned dependencies
- SPDX license headers on all files

### TypeScript Exemptions (Approved)

The hyperpolymath "no new TypeScript" policy has the following approved exemptions, encoded as `path_allow_prefixes` on the hypatia rule `cicd_rules/typescript_detected` (matches `*.ts`). These are *not* policy violations — they are documented carve-outs.

Existing pre-2026-04-30 `.ts`/`.tsx` outside these carve-outs is grandfathered while in-flight migration proceeds (~288 estate-authored files across ~40 repos as of 2026-05-28; see project tracker `project_estate_ts_to_affinescript_2026_05_28.md`). New TS files in non-carve-out paths are blocked.

| Path / Pattern | Class | Rationale | Unblock condition |
|---|---|---|---|
| `**/*.d.ts` | declaration | FFI/library type definitions (headers, not implementation). | Never — declaration files are the boundary, not the code. |
| `**/bindings/deno/**`, `**/bindings/typescript/**`, `**/bindings/ts/**` | interop target | We expose work to TS/Deno consumers without authoring TS as primary code path. Exemplar: `proven/bindings/deno/` (72 files — Idris2 ABI exposed as Deno-native module). Parallel to V-lang `v-cartridge`/`v-adapter`/`v-bindings`/`v-client` carve-out. | Never — these are consumer-facing bindings. |
| `**/vite.config.ts`, `**/vitest.config.ts`, `**/tsup.config.ts` | tooling | Build orchestration, not application code. | When AffineScript ships native equivalents. |
| `rescript/**`, `servers/**`, `repos-monorepo/**`, `linguist/**` | upstream fork | Not estate-authored — vendored upstream code (ReScript compiler, third-party MCP servers, mass aggregator, GitHub linguist with `samples/TypeScript/*.ts` as ML training fixtures). | Never — upstream fork. |
| `hyperpolymath-archive/**` | archived | GitHub-archived repos cannot accept PRs; TS is dormant. | Never — archived. |
| `**/deps/**` | vendored package-manager dep | Elixir Mix vendored-dep directory (also adopted by other tools). Exemplar: `tma-mark2/deps/phoenix_live_view/assets/js/phoenix_live_view/*.ts` ships Phoenix LiveView's authored TS. | Never — vendored upstream. |
| `**/vscode/**` (covers `editors/vscode/`, `extensions/vscode/`, `clients/vscode/`) | editor-host extension | VSCode extension entry points target the `vscode` extension-host API. Five estate repos (`universal-language-server-plugin`, `reposystem`, `proof-burrower`, `phronesis`, `bofj-kitt`) have a single `vscode/extension.ts`. | **Capability SHIPPED, verified 2026-08-28** — `affinescript/stdlib/Vscode.affine` (58 `extern fn`), `VscodeLanguageClient.affine` (4), the JS host shim `packages/affine-vscode/mod.js`, and `affine-vscode-publish.yml`. The remaining blocker is migration effort, not capability. Track under campaign #239; retire this row when the five VSCode extensions are ported. |

Retired 2026-08-31: the `2-protocols/avow/telegram-bot/**` carve-out (the bot was rewritten in AffineScript — zero `.ts` on main, so the "PERMANENT" rationale no longer described reality); the `affinescript-deno-test/**` + `affinescript-cli/**` bootstrap-shim row (the test harness self-hosted to 100% `.affine` via affinescript#735/#736, and the cli is JS-only — see the npm/JavaScript tables below for its surviving front-door carve-out); and the `**/tsconfig.json` pattern (dead entry — the rule matches `*.ts`, so a `.json` path could never reach the allowlist).

Adding to this list requires explicit user approval and an unblock condition (except the structural classes above, which are estate-wide policy). The detection rule and its `path_allow_prefixes` field are the single source of truth; this table mirrors that for human readability.

### ReScript Exemptions (Approved)

The hyperpolymath "no new ReScript" policy (banned 2026-05-25) has the following approved exemptions, encoded as `path_allow_prefixes` on the hypatia rules `cicd_rules/rescript_detected` (matches `*.res`) and `cicd_rules/rescript_interface_detected` (matches `*.resi`).

Existing pre-2026-05-25 `.res`/`.resi` outside these carve-outs is grandfathered while in-flight migration proceeds (~3,996 files across ~80 repos as of 2026-05-30; see project tracker `project_estate_rescript_to_affinescript_2026_05_28.md` and umbrella `hyperpolymath/standards#252`). New `.res`/`.resi` files in non-carve-out paths are blocked.

| Path / Pattern | Class | Rationale | Unblock condition |
|---|---|---|---|
| `**/bsconfig.json`, `**/*.config.res` | tooling | Build orchestration, not application code. | When AffineScript ships native equivalents. |
| `rescript/**`, `servers/**`, `repos-monorepo/**`, `linguist/**` | upstream fork | Not estate-authored — vendored upstream code (ReScript compiler, third-party MCP servers, mass aggregator, GitHub linguist samples). | Never — upstream fork. |
| `zotpress/**` | upstream fork | Upstream WordPress plugin fork (`hyperpolymath/hyperpolymath/zotpress`); not estate-authored, kept in tree as a vendored fork. Mirrors the per-repo `.hypatia-ignore` entry in hyperpolymath/hyperpolymath#20. | Never — upstream fork. |
| `hyperpolymath-archive/**` | archived | GitHub-archived repos cannot accept PRs; ReScript is dormant. | Never — archived. |
| `**/deps/**`, `**/node_modules/**` | vendored package-manager dep | Mix-style vendored deps and Node-style node_modules. | Never — vendored upstream. |
| `**/vscode/**` (covers `editors/vscode/`, `extensions/vscode/`, `clients/vscode/`) | editor-host extension | VSCode extension entry points target the `vscode` extension-host API. | When AffineScript ships the VSCode-extension API binding (top-50 roadmap, unshipped). |
| `**/lib/js/**`, `**/lib/es6/**`, `**/lib/bs/**` | compiled output | bsc (the ReScript compiler) emits to these paths. They are not source. | Never — compiler output, not source. |

Retired 2026-08-31: the bootstrap-shim row (`affinescript-deno-test/**`, `affinescript-cli/**`) and the telegram-bot mirror row — both directories are 100% AffineScript on main and neither ever tracked a `.res` file, so removal changes no scan outcome.

### npm Exemptions (Approved)

The hyperpolymath "npm banned" policy (2026-05-25) has the following approved exemptions on the hypatia rule `cicd_rules/nodejs_detected` (matches `package-lock.json`).

Migration substantially complete 2026-05-31 under umbrella `hyperpolymath/standards#253` (172 manifests at campaign start; all seven STEP issues #261/#262/#265/#268/#270/#273/#275 closed; ~22 physical-migration PRs landed plus three named-bucket audits closed `SUBSTANTIALLY DONE`; per-repo follow-up trackers cover the residual longtail). See `project_estate_npm_to_deno_2026_05_28.md`.

| Path / Pattern | Class | Rationale | Unblock condition |
|---|---|---|---|
| `**/vscode/**` | VSCode extension host-required (segment) | VSCode extension toolchain runs under Node; lockfile is contractually required by the host. | When AffineScript ships the VSCode-extension API binding. |
| `vscode-` substring (`vscode-extension/`, `editors/vscode-007/`, `vscode-a2ml`, `vscode-k9`, …) | VSCode-* extension repos / subdirs | Same VSCode host-required toolchain rationale; different path-segment shape than `/vscode/`. | When AffineScript ships the VSCode-extension API binding. |
| `tree-sitter-` substring (`tree-sitter-a2ml`, `tree-sitter-k9`, `editors/tree-sitter-ephapax`, `tree-sitter-affinescript/`, …) | tree-sitter grammar npm-publish target | Class C consumer artifact — tree-sitter grammars ship via npm with `node-gyp` native binding because every consumer (Atom/Neovim/VSCode TextMate) links the native addon. | Never — npm-publishable consumer artifact with native binding. |
| `affinescript-cli/**` | npm front door | Permanent npm distribution shim for the AffineScript toolchain (downloads the pinned native binary, SHA-256-verifies, caches, execs). Deliberately runtime-agnostic JS; reframed 2026-08-31 from "bootstrap shim" — the shim is the front door, not scaffolding awaiting self-hosting. (`affinescript-deno-test/**` dropped the same day: the harness self-hosted to 100% `.affine`.) | Never — distribution boundary; an npm shim cannot be `.affine`. |
| `rescript/**`, `servers/**`, `repos-monorepo/**`, `linguist/**` | upstream fork | Not estate-authored — vendored upstream code. | Never — upstream fork. |
| `hyperpolymath-archive/**` | archived | Archived repos cannot accept PRs. | Never — archived. |
| `**/deps/**`, `**/node_modules/**` | vendored package-manager dep | Vendored deps. | Never — vendored upstream. |
| `**/.lake/**` | Lean4 vendored package | Lean4's package manager directory, parallel to `/deps/`. | Never — vendored. |
| `**/office-addin/**` | Office.js add-in host-required | Office host loads `.js` from a Node-packaged manifest, parallel to VSCode extension carve-out. | When AffineScript ships an Office.js binding. |
| `**/bindings/javascript/**`, `**/bindings/typescript/**` | consumer-facing estate export | Proven JS/TS bindings published to npm consumers, parallel to `/bindings/deno/` under `:typescript_detected`. | Never — consumer-facing bindings. |
| `**/example/**`, `**/examples/**`, `**/test-fixtures/**`, `**/fixtures/**` | example/test fixture | Demonstrates an npm consumer (e.g., showing how a library is used from a Node project) without making the repo itself an npm consumer. | Never — fixture, not own toolchain. |

### JavaScript Exemptions (Approved)

The hyperpolymath "Unnecessarily-JavaScript banned" policy (2026-05-25) has the following approved exemptions on the hypatia rules `cicd_rules/javascript_detected` (matches `*.js`) and `cicd_rules/javascript_jsx_detected` (matches `*.jsx`).

Distinct from TS/RS policy: JavaScript is *allowed* where AffineScript cannot reach. The rule targets the gap between current AS bindings and current JS usage — JS that COULD be AS today but isn't. In-flight migration tracked under `hyperpolymath/standards#254` (1,609 files across the estate; see `project_estate_unnecessary_js_2026_05_28.md`). Ship mode: HARD-BLOCK + extensive carve-outs (umbrella#254 STEP 1 design question resolved 2026-05-30). Per-PR exemption via inline pragma `// hypatia: allow cicd_rules/javascript_detected -- <reason>`.

| Path / Pattern | Class | Rationale | Unblock condition |
|---|---|---|---|
| `mcp-bridge/**`, `**/plugins/**` | host-required by ecosystem | MCP servers and plugin entry points where JS is the host contract (the host loads .js, not .affine). | When AS plugin-host bindings ship (top-50 roadmap). |
| `**/*.config.js`, `**/*.config.cjs`, `**/*.config.mjs` | tooling configs | Build orchestration. | When AS ships native equivalents. |
| `affinescript-cli/**` | npm front door | Permanent npm distribution shim for the AffineScript toolchain — same row as the npm table above; the cli's 4 JS files are the shim itself. (`affinescript-deno-test/**` dropped 2026-08-31: harness self-hosted to 100% `.affine`.) | Never — distribution boundary. |
| `rescript/**`, `servers/**`, `repos-monorepo/**`, `linguist/**` | upstream fork | Not estate-authored — vendored upstream code (linguist samples are ML training data). | Never — upstream fork. |
| `hyperpolymath-archive/**` | archived | Archived repos cannot accept PRs. | Never — archived. |
| `**/deps/**`, `**/node_modules/**` | vendored package-manager dep | Vendored deps. | Never — vendored upstream. |
| `**/out/**`, `**/lib/js/**`, `**/.deno/**` | compiled output | AS / RS / Deno-cache compile output. | Never — compiler output, not source. |
| `**/vscode/**`, `**/extensions/vscode/**` | editor-host extension entry | VSCode extension entry points (often shipped as compiled `.js` even when authored as `.ts`). | When AS VSCode-extension API binding ships (top-50 roadmap). |

---

## Commit Signing in Agent Environments — "Unverified" is not an action item

**Do not chase "Unverified" / "no signature" on agent commits, and do not put
signing keys into containers or repos to fix it.** In the managed Claude-Code
execution environment, commit signing is **platform-mediated and already wired
once, globally** — there is no per-repo or per-container key chore, and no
estate-wide key rollout to do.

How it actually works (ground-truthed 2026-06-26):

- The container's global git config already sets, for *every* repo:
  `commit.gpgsign = true`, `gpg.format = ssh`,
  `gpg.ssh.program = /tmp/code-sign` (→ Anthropic's `environment-manager`
  binary), and `user.signingkey = …/commit_signing_key.pub`.
- On every commit, git invokes that platform shim
  (`/tmp/code-sign -Y sign -n git -f <key> <buffer>`). The shim — **not**
  OpenSSH — is the signer. `ssh-keygen` is not even installed.
- When a session's managed signing identity is inactive, the shim is a no-op:
  the commit succeeds but carries no signature (`git log --format='%G?'` → `N`),
  and the `commit_signing_key.pub` is an empty placeholder.

Consequences for agents:

- **It is non-blocking.** Unverified commits push and merge normally. The
  `stop-hook-git-check.sh` "Unverified" warning is *advisory*; `--amend
  --reset-author` only churns SHAs and cannot add a signature (no key/identity
  to sign with). Do not loop on it.
- **The only real lever is platform-side**: enabling managed commit-signing for
  the environment/account (Anthropic support / Claude-Code settings), which makes
  the shim emit real signatures automatically and estate-wide. Alternatively,
  merging via the GitHub UI re-signs the merge commit with GitHub's web-flow key,
  so `main` shows Verified regardless.
- Doctrine "always sign" remains the aspiration; the *mechanism* is this managed
  shim, configured once by the platform — never a manual per-repo/per-container
  key edit by an agent.
