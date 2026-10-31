# SPDX-License-Identifier: MPL-2.0
# justfile - Just recipes for this project
# See: https://github.com/hyperpolymath/mustfile
#
# requires: just >= 1.19.0   (import? optional-import support)
# Enforced by the `tooling-version-integrity` must-check, not self-
# enforcing: import? fails at parse time before any recipe can guard it.
# See 3-practice/TOOLING-VERSION-INTEGRITY-POLICY.adoc (root cause: burble#39).

default:
    @just --list

# Dependency setup for the root devcontainer; sub-projects manage their own deps.
deps:
    @echo "No root package dependencies to install (specs only)."

# Run the workflow-staleness gate against a repo (default: this one)
staleness-check path=".":
    @bash scripts/check-workflow-staleness.sh "{{path}}"

# Audit (or --fix) consumer reusable-workflow SHA pins toward a target.
# Read-only by default; pass extra args after the path, e.g.
#   just staleness-propagate ../stapeln --fix --to <sha>
staleness-propagate path="." *args="":
    @bash scripts/propagate-workflow-pins.sh {{args}} "{{path}}"

# Regression tests for the staleness gate + the pin-propagation helper
staleness-test:
    @echo "=== check-workflow-staleness ==="
    @bash scripts/tests/check-workflow-staleness-test.sh
    @echo "=== propagate-workflow-pins ==="
    @bash scripts/tests/propagate-workflow-pins-test.sh

# Check the repository's workflow references and, when a repository slug is
# supplied, its live Actions policy. Example: just check-allowlist hyperpolymath/standards
check-allowlist repository="":
    @bash scripts/check-allowed-actions.sh config/settings/actions-allowlist.json .github/workflows
    @if [ -n "{{repository}}" ]; then bash scripts/check-actions-policy.sh "{{repository}}"; fi

# Apply the estate default from config/settings/repo.json: allowed_actions=selected
# + mandatory SHA pinning, with the canonical allow-list payload. posture=all
# deliberately relaxes ONE repository; it is not the estate default.
set-allowlist repository posture="selected":
    @ACTIONS_POSTURE="{{posture}}" bash scripts/set-allowed-actions.sh "{{repository}}"

actions-policy-test:
    @bash scripts/tests/actions-policy-486-test.sh

# Internal-pointer integrity: every asciidoc link:/image: and markdown
# relative link in the repo must resolve. The September reorg moved files
# without updating relative links (first measured census 2026-09-19: 194
# live-canon findings, incl. inside RSR-SPEC-v2.adoc itself); this makes
# that class a standing check. Usage: just link-rot-guard [ROOT]
link-rot-guard root="." :
    @bash scripts/link-rot-guard.sh "{{root}}"

# Wave-0 anti-false-green regression: proves each fixed validator CAN fail
false-green-test:
    @bash scripts/tests/wave0-false-green-test.sh

# Wave-1 automation regression: Mustfile runner + hook installer
automation-test:
    @bash scripts/tests/wave1-automation-test.sh

# Wave-8 gate-promotion regression: baseline gate + Mustfile PR gate can fail
gates-test:
    @bash scripts/tests/wave8-gates-test.sh

# standards#505 gate-promotion regression: docs + package-policy gates can fail,
# and their grace cutoffs actually flip (tested from both sides of the date)
governance-gates-test:
    @bash scripts/tests/governance-gates-505-test.sh

# Structural validation of the Mustfile contract (severity + run/verification per check)
mustfile-check path=".machine_readable/contractiles/must/Mustfile.a2ml":
    @bash scripts/check-mustfile-structure.sh "{{path}}"

# Execute the Mustfile's `- run:` checks (critical/high failures block)
must-check path=".machine_readable/contractiles/must/Mustfile.a2ml":
    @bash scripts/run-mustfile.sh "{{path}}"

# Structural validation of the Debtfile (probe + ceiling + policy + expiry per entry)
debtfile-check path=".machine_readable/Debtfile.a2ml":
    @bash scripts/check-debtfile-structure.sh "{{path}}"

# Re-measure every Debtfile probe and compare against its ceiling (read-only)
debt-measure path=".machine_readable/Debtfile.a2ml":
    @bash scripts/run-debtfile.sh "{{path}}"

# Re-measure and WRITE BACK: updates count, lowers ceilings that were paid down.
# Never raises a ceiling — that needs a Debt-exception in the commit message.
debt-ratchet-down path=".machine_readable/Debtfile.a2ml":
    @bash scripts/run-debtfile.sh --write "{{path}}"

# Install this repo's git hooks into .git/hooks/ (pre-commit guards)
hooks-install:
    @bash hooks/install.sh

# DYADT: verify a CLAIMS.a2ml against primary evidence (default: root CLAIMS.a2ml)
verify-claims path="CLAIMS.a2ml":
    @bash scripts/verify-claims.sh "{{path}}"

# DYADT: run the conformance vector suite
dyadt-conformance:
    @bash 1-formats/sub-specs/did-you-actually-do-that/spec/conformance/run-conformance.sh

# DYADT regression test (confirm/refute/unverifiable + guards)
dyadt-test:
    @bash scripts/tests/wave4-dyadt-test.sh

# FFP: run the form-fill provenance conformance vectors against the reference probe
# (set FFP_DETECTOR to test a product detector instead)
ffp-conformance:
    @bash 1-formats/sub-specs/form-fill-provenance/spec/conformance/run-conformance.sh

# Structural lint for per-language testing guides (required sections + R1..R9)
language-guides-check:
    @bash scripts/check-language-guide.sh

# Block reintroduction of deprecated names (6a2, agent_instructions) in new diff
canonical-names-check base="origin/main":
    @bash scripts/check-canonical-names.sh "{{base}}"

# Mechanical half of a repository rename: register + allowlist + tree check
# (0-canon/CANONICAL-NAMES.adoc § "What a repository rename mechanically entails")
retired-names-check args="--strict":
    @bash scripts/check-retired-names.sh {{args}}

# Trusted-base scanner regression suite (core + extended tiers, budget, tiers)
trusted-base-test:
    @bash scripts/tests/check-trusted-base-test.sh

# Every normative heading in an opted-in document must declare its enforcement
# status: `Enforced-by: <script>` or `Review-only: <why nothing does>`. Opt-in
# per document with `// doctrine-coverage: on` so a repository that has never
# tagged anything is not red-boarded the day the gate is installed.
doctrine-coverage:
    @bash scripts/check-doctrine-coverage.sh --path docs --path 0-canon

# Measure the trusted-base marker set across governance callers. Writes to
# out/ (gitignored); needs a token with estate-wide read.
trusted-base-survey owner="hyperpolymath":
    @bash scripts/estate-trusted-base-survey.sh --owner {{owner}}

# Aggregate compliance gate. The RSR self-audit is INFORMATIONAL — a monorepo
# is not expected to score Gold — but a *broken* audit (exit 4 / unexpected)
# must fail loudly rather than pass silently under a blanket `|| true`
# (Wave-0 false-green fix).
validate:
    @echo "=== validate: per-language testing guides (structural, HARD GATE) ==="
    @bash scripts/check-language-guide.sh
    @echo "=== validate: canonical-names reintroduction guard (vs origin/main) ==="
    @bash scripts/check-canonical-names.sh origin/main || bash scripts/check-canonical-names.sh HEAD
    @echo "=== validate: doctrine coverage (every invariant names its enforcement) ==="
    @bash scripts/check-doctrine-coverage.sh --path docs --path 0-canon
    @echo "=== validate: RSR self-audit (INFORMATIONAL grade; errors fail loudly) ==="
    @bash scripts/rsr-selfaudit.sh .
    @echo "=== validate: done ==="

# Print role-appropriate LLM warm-up context (machine front door)
llm-context role="dev":
    @echo "# Front door: 0-AI-MANIFEST.a2ml (machine) + README.adoc (human)"
    @cat "llm-warmup-{{role}}.adoc" 2>/dev/null || cat 0-AI-MANIFEST.a2ml

# Build all sub-project artefacts. The canon ships specs, not products: the k9
# Rust binding moved to hyperpolymath/k9-ecosystem (#491) and the groove ipv6t
# reference is not in this tree, so there is nothing to compile here. Kept as a
# recipe so `just build` stays a valid estate entry point (and says so).
build:
    @echo "=== Standards Monorepo Build ==="
    @echo "nothing to build: specs only (k9 binding -> hyperpolymath/k9-ecosystem, #491)"
    @echo "=== Build complete ==="

# Run all sub-project test suites
test:
    @bash scripts/run-shell-test-suite.sh

# Regression test: test aggregation fails for missing prerequisites and test failures.
test-runner-test:
    @bash scripts/tests/run-required-test-suite-test.sh

# standards#496 regression: archived artefacts stay out of live spec homes.
session-detritus-test:
    @bash scripts/tests/wave9-session-detritus-test.sh

# Format sub-project code
fmt:
    @echo "=== Standards Monorepo Format ==="
    @echo "=== Format complete ==="

# Lint. The repo's lint surface is the structural gates, not a per-language
# linter run (there is no root crate; Deno is banned). Delegates to `validate`.
lint: validate

# Clean build artifacts
clean:
    @echo "=== Cleaning ==="
    @rm -rf .cache/stale 2>/dev/null || true
    @echo "=== Clean complete ==="

# Run panic-attacker pre-commit scan
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"

# cicd-squabbler: map this repo's CI dependency chains (exit 4 = cycle or
# dead upstream; the same gate .github/workflows/cicd-squabbler.yml runs)
squabble-chains:
    @if command -v squabble >/dev/null 2>&1; then squabble chains .; else echo "squabble not found — install from https://github.com/hyperpolymath/cicd-squabbler"; fi

# cicd-squabbler: classify a stuck PR's reds (propose-only; never --apply here)
squabble-fight pr:
    @if command -v squabble >/dev/null 2>&1; then squabble fight metadatastician/standards {{pr}} --repo-root .; else echo "squabble not found — install from https://github.com/hyperpolymath/cicd-squabbler"; fi

# Contract test for the squabbler wiring (pin, exit codes, propose-only, lock)
squabble-test:
    @bash scripts/tests/cicd-squabbler-contract-test.sh

# Stable release gate audit
v1-audit path=".":
    @bash 3-practice/release-pre-flight/v1-audit.sh "{{path}}"

# Self-diagnostic — checks dependencies, permissions, paths
doctor:
    @echo "Running diagnostics for standards..."
    @echo "Checking required tools..."
    @command -v just >/dev/null 2>&1 && echo "  [OK] just" || echo "  [FAIL] just not found"
    @command -v git >/dev/null 2>&1 && echo "  [OK] git" || echo "  [FAIL] git not found"
    @echo "Checking for hardcoded paths..."
    @grep -rn '$HOME\|$ECLIPSE_DIR' --include='*.rs' --include='*.ex' --include='*.res' --include='*.gleam' --include='*.sh' . 2>/dev/null | head -5 || echo "  [OK] No hardcoded paths"
    @echo "Checking canonical contractiles source..."
    @test -f .machine_readable/contractiles/dust/Dustfile.a2ml && echo "  [OK] canonical Dustfile present" || echo "  [FAIL] canonical Dustfile missing"
    @echo "Checking git hooks are installed..."
    @test -f "$(git rev-parse --git-dir)/hooks/pre-commit" && echo "  [OK] pre-commit hook installed" || echo "  [INFO] pre-commit hook not installed — run 'just hooks-install'"
    @echo "Diagnostics complete."

# Auto-repair common issues
heal:
    @echo "Attempting auto-repair for standards..."
    @echo "Fixing permissions..."
    @find . -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    @echo "Cleaning stale caches..."
    @rm -rf .cache/stale 2>/dev/null || true
    @echo "Repair complete."

# Guided tour of key features
tour:
    @echo "=== standards Tour ==="
    @echo ""
    @echo "1. Project structure:"
    @ls -la
    @echo ""
    @echo "2. Available commands: just --list"
    @echo ""
    @echo "3. Read README.adoc for full overview"
    @echo "4. Read EXPLAINME.adoc for architecture decisions"
    @echo "5. Run 'just doctor' to check your setup"
    @echo ""
    @echo "Tour complete! Try 'just --list' to see all available commands."

# Open feedback channel with diagnostic context
help-me:
    @echo "=== standards Help ==="
    @echo "Platform: $(uname -s) $(uname -m)"
    @echo "Shell: $SHELL"
    @echo ""
    @echo "To report an issue:"
    @echo "  https://github.com/hyperpolymath/standards/issues/new"
    @echo ""
    @echo "Include the output of 'just doctor' in your report."


# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$grade" ] && grade="X"; \
    echo "$grade"

# Generate a shields.io badge markdown for the current CRG grade
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$grade" ] && grade="X"; \
    case "$grade" in \
      A) color="brightgreen" ;; B) color="green" ;; C) color="yellow" ;; \
      D) color="orange" ;; E) color="red" ;; F) color="critical" ;; \
      *) color="lightgrey" ;; esac; \
    echo "[![CRG $grade](https://img.shields.io/badge/CRG-$grade-$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"
