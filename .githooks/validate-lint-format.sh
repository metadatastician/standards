#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Hyperpolymath Estate — ecosystem-scoped lint + format check (pre-commit)
# Source: https://github.com/metadatastician/standards
#
# CONFINEMENT IS THE POINT. Each check runs only when THIS repo has staged
# files of that kind. A Rust check must not fire in a ReScript repo, and a V
# toolchain must never be summoned to lint a Coq development.
#
# READ-ONLY. Every command here reports; none rewrites a tracked file.
# `cargo fmt --check`, `nickel format --check`, `v fmt -verify`. The
# bare/`-w`/`--fix` forms are banned in this file.
#
# TWO FAILURE POLICIES, and the difference is deliberate:
#
#   * TOOLCHAIN MISSING, ecosystem toolchain (cargo, nickel, v, bun) →
#     FAIL CLOSED. You cannot have authored a .rs without cargo, so "cargo not
#     found" means a broken environment, not an exempt one. Skipping there
#     would report success having examined nothing.
#
#   * DENO is neither: no Deno toolchain is summoned. Deno is tier 2
#     (permitted, not gated); its section records what it saw — see below.
#
#   * OPTIONAL LINTER MISSING (hlint, fourmolu) → reported as an explicit
#     SKIP line, not as a pass, and CI remains the authority. These are add-ons
#     rather than the toolchain, so their absence is an ordinary state of a
#     working machine and must not block every commit on every machine.
#
# Override for one commit: git commit --no-verify
# Skip the slow Rust clippy pass: ESTATE_HOOK_SKIP_SLOW=1 (prints a loud
# warning — the gate did NOT run, and that is not the same as passing).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

REPO_ROOT="${INPUT_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

STAGED="${INPUT_STAGED_FILES:-$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)}"

ERRORS=0
LEDGER=()

note()  { echo -e "${BLUE}[lint]${NC} $*"; }
warn()  { echo -e "${YELLOW}[lint] $*${NC}" >&2; }
fail()  { echo -e "${RED}[lint] $*${NC}" >&2; ERRORS=$((ERRORS + 1)); }

# Staged files matching an extended regex, one per line.
staged_matching() {
  [ -z "$STAGED" ] && return 0
  echo "$STAGED" | grep -E "$1" || true
}

# Files ADDED by this commit, as distinct from modified. A language ban is a ban
# on NEW sources: grandfathered files must still lint, but a newly added one is
# exactly the regression the ban exists to stop, so the two populations need
# different verdicts. A warning cannot stop a commit; only `fail` can.
# NOTE: reads git directly — INPUT_STAGED_FILES carries names but not statuses.
added_matching() {
  git diff --cached --name-only --diff-filter=A 2>/dev/null | grep -E "$1" || true
}

# Does this repo TRACK a marker file? Distinct from "is a file staged":
# `v.mod` is what makes a `.v` a V source rather than a Coq proof script.
tracks() {
  git ls-files -- "$@" | grep -q . 2>/dev/null
}

require_tool() {
  local tool="$1" eco="$2" hint="$3"
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "${eco}: '${tool}' is not installed, so the ${eco} gate could not run. Refusing to pass a check that examined nothing. Install: ${hint}"
    return 1
  fi
  return 0
}

# ── Rust ────────────────────────────────────────────────────────────────
RS="$(staged_matching '\.rs$|(^|/)Cargo\.toml$')"
# The ecosystem gate is the MANIFEST, not the extension. A stray `.rs` staged in
# a ReScript tree with no Cargo.toml would otherwise run `cargo fmt --all`, which
# exits non-zero with "error: could not find `Cargo.toml`" — a RED gate for a
# reason that has nothing to do with the code. Confinement means the Rust gate
# does not fire in a non-Rust repo at all.
# `tracks` reads the INDEX, so a Cargo.toml added in THIS commit does count.
if [ -n "$RS" ] && tracks 'Cargo.toml' '*/Cargo.toml'; then
  note "Rust: $(echo "$RS" | grep -c .) staged file(s)"
  if require_tool cargo Rust "https://rustup.rs"; then
    cargo fmt --all --check || fail "Rust: sources are not formatted (cargo fmt --check)"
    if [ "${ESTATE_HOOK_SKIP_SLOW:-0}" = "1" ]; then
      warn "Rust: clippy SKIPPED via ESTATE_HOOK_SKIP_SLOW=1. A skip is not a pass — CI will still run it."
      LEDGER+=("rust-clippy: SKIPPED (ESTATE_HOOK_SKIP_SLOW)")
    else
      cargo clippy --all-targets -- -D warnings || fail "Rust: clippy reported warnings (treated as errors)"
    fi
  fi
else
  LEDGER+=("rust: not staged, or repo tracks no Cargo.toml")
fi

# ── Nickel ──────────────────────────────────────────────────────────────
# `*.k9.ncl` is EXCLUDED here, matching .github/workflows/ci-pipeline.yml,
# which excludes the same pathspec in both its `detect` and `nickel` jobs.
#
# A K9 component opens with the three-octet `K9!` sentinel, which is not
# Nickel: `nickel typecheck` dies at 1:3 on the `!` (the CI comment says so
# verbatim). Running it here anyway was not a strict gate, it was a wrong one
# — it failed on a byte the format requires, on files no edit could fix, which
# is the shape of a hook people learn to bypass with --no-verify.
#
# K9 files are not therefore unchecked. They are checked by the gate that
# knows the format: .githooks/validate-k9.sh, which delegates to
# 1-formats/k9/tools/k9-validate.sh and applies the envelope-strip rule
# (K9-CONTRACT-SPEC §3.6) before it reaches for Nickel at all.
NCL="$(staged_matching '\.ncl$' | grep -v '\.k9\.ncl$' || true)"
if [ -n "$NCL" ]; then
  note "Nickel: $(echo "$NCL" | grep -c .) staged file(s)"
  if require_tool nickel Nickel "https://github.com/tweag/nickel/releases"; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      nickel format --check "$f" || fail "Nickel: $f is not formatted"
      # Only these generated artefacts may be missing at commit time. Matching
      # every "could not find import" instead would let a TYPO in a new import
      # pass the gate as though it were a generated file.
      NCL_GENERATED_IMPORTS='claude-md-data\.json'
      # A Nickel file may `import` a build-time artefact that is GITIGNORED and
      # generated — here machine-readable/arrival-pack/arrival-pack.ncl imports
      # claude-md-data.json, which extract.sh produces during generate.sh. A
      # pre-commit hook cannot run the repo's build, so typechecking such a file
      # is PERMANENTLY red: a gate no edit can satisfy. Report the skip loudly
      # and name the file — a skip is not a pass. Every other typecheck error
      # still fails, so this narrows the gate rather than disabling it.
      if tc_out="$(nickel typecheck "$f" 2>&1)"; then
        :
      elif printf '%s' "$tc_out" | grep -q 'could not find import' \
        && printf '%s' "$tc_out" | grep -qE "$NCL_GENERATED_IMPORTS"; then
        warn "Nickel: $f NOT typechecked — unresolved GENERATED import. A SKIP, not a pass."
      else
        printf '%s\n' "$tc_out" >&2
        fail "Nickel: $f failed typecheck"
      fi
    done <<< "$NCL"
  fi
else
  LEDGER+=("nickel: not staged")
fi

# ── Deno (tier 2 — permitted, not gated) ────────────────────────────────
#
# Owner ruling 2026-10-14: Deno is not banned; the order is Bun, Deno, pnpm,
# npm. From 2026-09-22 to 2026-10-14 this hook refused any commit that added
# or modified a deno.json(c); the ruling retired that refusal along with the
# central ledger. The hook now records what it saw and passes.
DENO_CFG="$(staged_matching '(^|/)deno\.jsonc?$')"
DENO_TRACKED="$(git ls-files -- 'deno.json' '*/deno.json' 'deno.jsonc' '*/deno.jsonc' | grep -c . || true)"
if [ -n "$DENO_CFG" ]; then
  LEDGER+=("deno: $(echo "$DENO_CFG" | grep -c .) Deno config file(s) staged — permitted (tier 2; Bun preferred)")
else
  LEDGER+=("deno: no deno.json(c) staged (repo tracks ${DENO_TRACKED})")
fi

# ⚠ Dropping the Deno lint leaves staged `.js`/`.jsx`/`.mjs`/`.cjs` with NO
# pre-commit gate: the estate has no pinned bun lint/format gate to fall
# through to. Declared here rather than left silent — an unchecked file type
# that nobody names reads as a checked one.
JS_SRC="$(staged_matching '\.(js|jsx|mjs|cjs)$')"
if [ -n "$JS_SRC" ]; then
  LEDGER+=("javascript: $(echo "$JS_SRC" | grep -c .) staged file(s) NOT checked — no pinned bun lint/format gate exists. A skip, not a pass.")
fi

# ── ReScript (BANNED for new code; migrates to AffineScript) ────────────
RES="$(staged_matching '\.resi?$')"
# Same confinement as Rust: `bunx rescript` needs a project manifest to resolve
# sources. Without one it fails for a reason unrelated to the staged file.
if [ -n "$RES" ] && tracks 'rescript.json' '*/rescript.json' 'bsconfig.json' '*/bsconfig.json'; then
  warn "ReScript is BANNED for new code (owner ruling 2026-04-30). Existing .res migrates to .affine — AffineScript, not TypeScript."
  note "ReScript: $(echo "$RES" | grep -c .) staged file(s)"
  RES_ADDED="$(added_matching '\.resi?$')"
  if [ -n "$RES_ADDED" ]; then
    fail "ReScript is BANNED for new code: $(echo "$RES_ADDED" | grep -c .) NEWLY ADDED .res/.resi file(s). Migrate to AffineScript (.affine). Modified grandfathered files are still linted below."
  fi
  if require_tool bunx ReScript "https://bun.sh"; then
    if bunx rescript format --help 2>&1 | grep -q -- '-check'; then
      bunx rescript format -all -check || fail "ReScript: sources are not formatted"
    else
      warn "ReScript: the installed CLI has no 'format -check'; the format gate did NOT run. This is a skip, not a pass."
      LEDGER+=("rescript-format: SKIPPED (CLI lacks -check)")
    fi
  fi
else
  LEDGER+=("rescript: not staged, or repo tracks no rescript.json/bsconfig.json")
fi

# ── V (BANNED; Zig migration completed 2026-05-28) ──────────────────────
V_SRC="$(staged_matching '\.v$')"
if [ -n "$V_SRC" ]; then
  if tracks 'v.mod' '*/v.mod'; then
    warn "V-lang is BANNED (owner ruling 2026-04-10; estate migration to Zig COMPLETED 2026-05-28). A v.mod here means a carve-out or a regression — confirm which."
    note "V: $(echo "$V_SRC" | grep -c .) staged file(s)"
    V_ADDED="$(added_matching '\.v$')"
    if [ -n "$V_ADDED" ]; then
      fail "V is BANNED: $(echo "$V_ADDED" | grep -c .) NEWLY ADDED .v file(s). The estate completed its Zig migration on 2026-05-28. Modified carve-out files are still linted below."
    fi
    if require_tool v V "https://github.com/vlang/v/releases"; then
      # ⚠ MEASURED on v 0.5.2: `v fmt -verify <FILE>` prints its findings and
      # then EXITS 0 — a fake green. Only the DIRECTORY form exits 1. Do not
      # rewrite this as a per-file loop.
      v fmt -verify . || fail "V: sources are not formatted (v fmt -verify)"
      v vet .         || fail "V: v vet reported problems"
    fi
  else
    # `.v` is shared with Coq proof scripts and Verilog. Without a v.mod this
    # is NOT V source, and summoning a V toolchain for it would be wrong.
    note "V: .v staged but no v.mod tracked — treating as Coq/Verilog, not V. No V check run."
    LEDGER+=("v: .v staged without v.mod (Coq/Verilog — correctly not checked)")
  fi
else
  LEDGER+=("v: not staged")
fi

# ── Haskell ─────────────────────────────────────────────────────────────
HS="$(staged_matching '\.hs$')"
if [ -n "$HS" ] && tracks '*.cabal' 'stack.yaml' '*/stack.yaml'; then
  note "Haskell: $(echo "$HS" | grep -c .) staged file(s)"
  RAN_ANY=0
  if command -v fourmolu >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    fourmolu --mode check $HS || fail "Haskell: sources are not formatted (fourmolu --mode check)"
    RAN_ANY=1
  fi
  if command -v hlint >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    hlint $HS || fail "Haskell: hlint reported problems"
    RAN_ANY=1
  fi
  if [ "$RAN_ANY" -eq 0 ]; then
    # Optional linters, not the toolchain — see the header. Reported as a
    # skip so it cannot be mistaken for a clean result.
    warn "Haskell: neither fourmolu nor hlint is installed, so NO Haskell gate ran. This is a skip, not a pass — CI still checks with -Wall -Werror."
    LEDGER+=("haskell: SKIPPED (no fourmolu/hlint installed)")
  fi
else
  LEDGER+=("haskell: not staged or repo has no cabal/stack manifest")
fi

# ── Ledger ──────────────────────────────────────────────────────────────
# Make every non-run legible. An absent check must never read as a satisfied
# one just because the terminal stayed quiet.
if [ "${#LEDGER[@]}" -gt 0 ]; then
  echo ""
  echo -e "${BLUE}[lint] gates that did not run:${NC}"
  for l in "${LEDGER[@]}"; do echo "  - $l"; done
fi

if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}[lint] FAILED with ${ERRORS} error(s).${NC}" >&2
  echo "  Fix locally with the ecosystem's own formatter, then re-stage." >&2
  echo "  Deliberate override for this one commit: git commit --no-verify" >&2
  exit 1
fi

echo -e "${GREEN}[lint] ecosystem lint + format checks passed.${NC}"
exit 0
