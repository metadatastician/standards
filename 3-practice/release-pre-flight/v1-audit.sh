#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# Stable release gate audit.
# Usage: ./release-pre-flight/v1-audit.sh [repo-path]

set -euo pipefail

REPO_PATH="${1:-.}"

if ! command -v rg >/dev/null 2>&1; then
    echo "v1-audit requires ripgrep (rg)" >&2
    exit 2
fi

TARGET="$(cd "$REPO_PATH" && pwd)"

BLOCKERS=0

MARKER_PATTERN='(^|[^[:alpha:]])(TODO|FIXME|XXX|HACK|STUB|PARTIAL)([^[:alpha:]]|$)|\{\{PROJECT\}\}|\{\{AUTHOR\}\}|\[TODO-[A-Z0-9-]+\]|sha256:placeholder'
PROOF_DEBT_PATTERN='believe_me|assert_total|unsafeCoerce|Obj\.magic|\bsorry\b|\bAdmitted\b|\bpostulate\b'
PLACEHOLDER_EVIDENCE_PATTERN='black_box\(42\)|not configured yet|placeholder test|template placeholder|fake fuzz|copied template'
STABLE_CLAIM_PATTERN='v1\.0\.0|stable release|production-ready|production ready|formally verified|machine-checked|provably|proof of soundness|soundness proof|reversible'

EXCLUDES=(
    --glob '!**/.git/**'
    --glob '!.git/**'
    --glob '!**/target/**'
    --glob '!target/**'
    --glob '!**/dist/**'
    --glob '!dist/**'
    --glob '!**/build/**'
    --glob '!build/**'
    --glob '!**/result/**'
    --glob '!result/**'
    --glob '!**/node_modules/**'
    --glob '!node_modules/**'
    --glob '!**/.direnv/**'
    --glob '!**/.venv/**'
    --glob '!**/__pycache__/**'
    --glob '!**/.cache/**'
    --glob '!**/.jj/**'
    --glob '!**/release-pre-flight/**'
    --glob '!3-practice/release-pre-flight/**'
    --glob '!**/publication-pre-flight/**'
    --glob '!3-practice/publication-pre-flight/**'
    --glob '!**/docs/reports/audit/**'
    --glob '!docs/reports/audit/**'
    --glob '!**/PROOF-NEEDS.md'
    --glob '!PROOF-NEEDS.md'
    --glob '!**/TEST-NEEDS.md'
    --glob '!TEST-NEEDS.md'
    --glob '!**/MAINTENANCE-CHECKLIST*'
    --glob '!MAINTENANCE-CHECKLIST*'
    --glob '!**/SOFTWARE-DEVELOPMENT-APPROACH*'
    --glob '!SOFTWARE-DEVELOPMENT-APPROACH*'
    --glob '!**/v1-audit.sh'
    --glob '!v1-audit.sh'
    --glob '!**/.github/workflows/**'
    --glob '!.github/workflows/**'
)

CODE_GLOBS=(
    --glob '*.rs' --glob '*.zig' --glob '*.res' --glob '*.re' --glob '*.rei'
    --glob '*.ml' --glob '*.mli' --glob '*.hs' --glob '*.idr' --glob '*.agda'
    --glob '*.lean' --glob '*.v' --glob '*.ex' --glob '*.exs' --glob '*.jl'
    --glob '*.scm' --glob '*.ncl' --glob '*.k9.ncl' --glob '*.toml'
    --glob '*.yaml' --glob '*.yml' --glob '*.json' --glob '*.adoc'
    --glob '*.md' --glob '*.tex' --glob 'Containerfile' --glob 'Dockerfile'
    --glob 'Justfile' --glob 'Justfile' --glob 'Mustfile' --glob 'flake.nix'
    --glob 'guix.scm' --glob 'Cargo.toml' --glob 'mix.exs'
)

log_section() {
    printf '\n== %s ==\n' "$1"
}

record_blocker() {
    BLOCKERS=$((BLOCKERS + 1))
    printf 'BLOCKER: %s\n' "$1"
}

show_matches() {
    local pattern="$1"
    shift
    (
        cd "$TARGET"
        rg -n --hidden -S "$pattern" "$@" "${EXCLUDES[@]}" 2>/dev/null | head -n 20 || true
    )
}

rg_repo() {
    (
        cd "$TARGET"
        rg -n --hidden -S "$@" "${EXCLUDES[@]}" 2>/dev/null
    )
}

path_is_support_script() {
    case "$1" in
        */Justfile|*/justfile|*.sh|*.k9.ncl)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

match_is_comment_only() {
    local text="$1"
    [[ "$text" =~ ^[[:space:]]*(#|//|/\*|\*|--|<!--) ]]
}

match_is_marker_support_line() {
    local text="$1"

    [[ "$text" == *'MARKER_PATTERN='* ]] && return 0
    [[ "$text" == *'reject_patterns = ['*'{{PROJECT}}'* ]] && return 0
    [[ "$text" == *'description = "No {{PROJECT}}/ {{PLACEHOLDER}} tokens remain'* ]] && return 0
    [[ "$text" == *'todo|fixme|hack|xxx|stub|partial'* ]] && return 0

    return 1
}

match_is_proof_support_line() {
    local text="$1"

    [[ "$text" == *'PROOF_DEBT_PATTERN='* ]] && return 0
    [[ "$text" == *'idris-unsound-scan = "believe_me/assert_total"'* ]] && return 0

    if [[ "$text" == *'grep '* || "$text" == *'rg '* ]]; then
        [[ "$text" == *'believe_me'* ]] && return 0
        [[ "$text" == *'assert_total'* ]] && return 0
        [[ "$text" == *'unsafeCoerce'* ]] && return 0
        [[ "$text" == *'Obj.magic'* ]] && return 0
        [[ "$text" == *'sorry'* ]] && return 0
        [[ "$text" == *'Admitted'* ]] && return 0
        [[ "$text" == *'postulate'* ]] && return 0
    fi

    return 1
}

match_should_be_suppressed() {
    local kind="$1"
    local path="$2"
    local text="$3"

    case "$kind" in
        marker)
            if path_is_support_script "$path" && match_is_comment_only "$text"; then
                return 0
            fi
            match_is_marker_support_line "$text" && return 0
            ;;
        proof)
            match_is_comment_only "$text" && return 0
            match_is_proof_support_line "$text" && return 0
            ;;
    esac

    return 1
}

filter_matches() {
    local kind="$1"
    local match path rest text
    local -a kept=()

    while IFS= read -r match; do
        [[ -n "$match" ]] || continue

        path="${match%%:*}"
        rest="${match#*:}"
        text="${rest#*:}"

        if match_should_be_suppressed "$kind" "$path" "$text"; then
            continue
        fi

        kept+=("$match")
        [[ ${#kept[@]} -ge 20 ]] && break
    done

    if [[ ${#kept[@]} -gt 0 ]]; then
        printf '%s\n' "${kept[@]}"
    fi
}

path_exists_with_real_files() {
    local path="$1"
    [[ -e "$TARGET/$path" ]] || return 1
    # -print -quit, not a pipe into grep -q: under pipefail a large directory
    # made find die of SIGPIPE (status 141) and read as "no real files".
    [[ -n "$(find "$TARGET/$path" -type f ! -name '.gitkeep' -print -quit)" ]]
}

justfile_path() {
    if [[ -f "$TARGET/justfile" ]]; then
        printf '%s\n' "$TARGET/justfile"
        return 0
    fi
    if [[ -f "$TARGET/Justfile" ]]; then
        printf '%s\n' "$TARGET/Justfile"
        return 0
    fi
    return 1
}

recipe_exists() {
    local file="$1"
    local regex="$2"
    rg -n "^(?:${regex})(?:\\s+[^:]*)?:" "$file" >/dev/null 2>&1
}

check_marker_scan() {
    log_section "Marker Scan"
    local matches
    matches="$(rg_repo "${CODE_GLOBS[@]}" "$MARKER_PATTERN" . | filter_matches marker || true)"
    if [[ -n "$matches" ]]; then
        record_blocker "unfinished markers or placeholders present"
        printf '%s\n' "$matches"
    else
        printf 'PASS: no unfinished markers found in scanned release paths\n'
    fi
}

check_proof_debt() {
    log_section "Proof Debt"
    local matches
    matches="$(rg_repo \
        --glob '*.rs' --glob '*.zig' --glob '*.res' --glob '*.re' --glob '*.rei' \
        --glob '*.ml' --glob '*.mli' --glob '*.hs' --glob '*.idr' --glob '*.agda' \
        --glob '*.lean' --glob '*.v' --glob '*.ex' --glob '*.exs' --glob '*.jl' \
        --glob '*.scm' --glob '*.ncl' --glob '*.k9.ncl' --glob '*.toml' \
        --glob '*.yaml' --glob '*.yml' --glob '*.json' --glob 'Containerfile' \
        --glob 'Dockerfile' --glob 'Justfile' --glob 'Justfile' --glob 'Mustfile' \
        "$PROOF_DEBT_PATTERN" . | filter_matches proof || true)"
    if [[ -n "$matches" ]]; then
        record_blocker "proof escape hatches found in code or proof files"
        printf '%s\n' "$matches"
    else
        printf 'PASS: no proof escape hatches found in scanned code paths\n'
    fi
}

check_fake_evidence() {
    log_section "Evidence Authenticity"

    local fake_matches
    fake_matches="$(rg_repo "${PLACEHOLDER_EVIDENCE_PATTERN}" tests test benches benchmarks fuzz | head -n 20 || true)"
    if [[ -n "$fake_matches" ]]; then
        record_blocker "placeholder or fake test/benchmark evidence detected"
        printf '%s\n' "$fake_matches"
    else
        printf 'PASS: no obvious fake test or benchmark evidence found\n'
    fi

    # Captured once, then tested and listed: piping find into grep -q (and into
    # head) let find die of SIGPIPE on a long listing, status 141 under
    # pipefail, and the placeholders read as absent. A find error with no
    # output still reads as none found, as before.
    local placeholders
    placeholders="$(find "$TARGET" \( -path '*/fuzz/placeholder.txt' -o -path '*/benches/.gitkeep' \) 2>/dev/null)" || true
    if [[ -n "$placeholders" ]]; then
        record_blocker "placeholder fuzz or benchmark artifacts present"
        head -n 20 <<<"$placeholders"
    else
        printf 'PASS: no placeholder fuzz/bench artifact files found\n'
    fi
}

check_audit_surfaces() {
    log_section "Audit Surfaces"

    local jf
    if ! jf="$(Justfile_path)"; then
        record_blocker "missing Justfile/Justfile"
        return
    fi
    printf 'PASS: Justfile present at %s\n' "$jf"

    if rg -n 'not configured yet|TODO: Replace|TODO: Add|placeholder values' "$jf" >/dev/null 2>&1; then
        record_blocker "justfile still contains placeholder or unconfigured recipes"
        rg -n 'not configured yet|TODO: Replace|TODO: Add|placeholder values' "$jf" | head -n 20
    else
        printf 'PASS: Justfile does not advertise unconfigured placeholder recipes\n'
    fi

    if recipe_exists "$jf" 'build'; then
        printf 'PASS: build recipe present\n'
    else
        record_blocker "missing build recipe"
    fi

    if recipe_exists "$jf" 'test|p2p|unit'; then
        printf 'PASS: point-to-point test recipe present\n'
    else
        record_blocker "missing point-to-point test recipe"
    fi

    if recipe_exists "$jf" 'e2e|test-e2e|tests-e2e'; then
        printf 'PASS: end-to-end recipe present\n'
    elif path_exists_with_real_files "tests/e2e" || [[ -f "$TARGET/tests/e2e.sh" ]]; then
        printf 'PASS: end-to-end test path present\n'
    else
        record_blocker "missing end-to-end test surface"
    fi

    if recipe_exists "$jf" 'aspect|test-aspect|aspect-tests'; then
        printf 'PASS: aspect test recipe present\n'
    elif path_exists_with_real_files "tests/aspect" || [[ -f "$TARGET/tests/aspect_tests.sh" ]]; then
        printf 'PASS: aspect test path present\n'
    else
        record_blocker "missing aspect test surface"
    fi

    if recipe_exists "$jf" 'bench|bench-smoke|benchmark'; then
        printf 'PASS: benchmark recipe present\n'
    elif path_exists_with_real_files "benches" || path_exists_with_real_files "benchmarks"; then
        printf 'PASS: benchmark path present\n'
    else
        record_blocker "missing benchmark surface"
    fi

    if recipe_exists "$jf" 'run|smoke|exec-check|run-smoke'; then
        printf 'PASS: execution/smoke recipe present\n'
    elif [[ -f "$TARGET/tests/smoke.sh" ]] || [[ -f "$TARGET/tests/run.sh" ]]; then
        printf 'PASS: execution smoke path present\n'
    else
        record_blocker "missing execution/smoke surface"
    fi
}

check_ci_surface() {
    log_section "CI Surface"
    if [[ -d "$TARGET/.github/workflows" ]] || [[ -f "$TARGET/.gitlab-ci.yml" ]]; then
        printf 'PASS: CI workflow surface present\n'
    else
        record_blocker "missing CI workflow surface"
    fi
}

check_stable_claims() {
    log_section "Stable Claims"
    local claims
    claims="$(rg_repo \
        --glob 'README*' --glob 'CHANGELOG*' --glob 'ROADMAP*' --glob 'SECURITY*' \
        --glob '.machine_readable/**' --glob 'docs/**' --glob '*.adoc' --glob '*.md' --glob '*.tex' \
        "$STABLE_CLAIM_PATTERN" . | head -n 20 || true)"
    if [[ -n "$claims" ]]; then
        printf 'INFO: stable or high-assurance claims detected\n'
        printf '%s\n' "$claims"
    else
        printf 'INFO: no explicit stable/high-assurance claims detected in common release docs\n'
    fi
}

check_state_release_stage() {
    log_section "Release Stage Metadata"
    local state_paths=(
        "$TARGET/.machine_readable/descriptiles/STATE.a2ml"
        "$TARGET/.machine_readable/STATE.a2ml"
        "$TARGET/STATE.a2ml"
    )
    local found=""
    local path
    for path in "${state_paths[@]}"; do
        if [[ -f "$path" ]]; then
            found="$path"
            break
        fi
    done

    if [[ -z "$found" ]]; then
        printf 'INFO: no STATE.a2ml found for release-stage cross-check\n'
        return
    fi

    printf 'INFO: STATE metadata found at %s\n' "$found"
    if rg -n 'stable|release-candidate|beta|alpha|draft' "$found" >/dev/null 2>&1; then
        rg -n 'stable|release-candidate|beta|alpha|draft' "$found" | head -n 10
    fi
}

main() {
    printf 'Stable Release Audit: %s\n' "$TARGET"

    check_marker_scan
    check_proof_debt
    check_fake_evidence
    check_audit_surfaces
    check_ci_surface
    check_stable_claims
    check_state_release_stage

    printf '\nSummary: %d blocker(s)\n' "$BLOCKERS"
    if [[ "$BLOCKERS" -gt 0 ]]; then
        printf 'Result: FAIL\n'
        exit 1
    fi

    printf 'Result: PASS\n'
}

main "$@"
