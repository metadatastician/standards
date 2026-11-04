#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-package-policy.sh — gate on the Guix-primary packaging policy, applied
# only where the repo's rsr-profile declares reproducible-build or container.
#
# Replaces the echo-only "Enforce Guix primary / Nix fallback" step in
# governance-reusable.yml, whose every branch echoed and which terminated with
# an unconditional `✅ Package policy check passed` (standards#505). It could
# not detect a violation, and it claimed a pass over any input.
#
# POLICY — canonical source is `0-canon/rsr/
# 3-practice/LANGUAGE-POLICY.adoc` §Package Management, NOT CLAUDE.md:
#
#   RULED 2026-05-18 (estate-wide): Guix primary + sealed-container escape;
#   NO Nix mirror. One packager per repo. A `flake.nix` that only mirrors a
#   Guix manifest is drift to remove, not a fallback. A second packager is
#   permitted only where it is the *sole* source of a *specific named*
#   dependency, and that dependency is documented as the reason.
#   **Supersedes the prior "Nix fallback everywhere" rule.**
#
# Tiers: Guix (guix.scm/manifest.scm) is PRIMARY; a sealed container
# (Containerfile, Podman/Svalinn-sealed) is the ESCAPE HATCH for the
# not-in-Guix / non-free tail. Nix is NOT a tier.
#
# This script previously cited CLAUDE.md and printed
# `✅ Nix package management detected (fallback)`. CLAUDE.md's packaging
# section is STALE — it still describes Nix as a fallback, in 472 copies
# estate-wide — and CLAUDE.md itself defers to 3-practice/LANGUAGE-POLICY.adoc as
# canonical, so the .adoc wins. Blessing a flake as compliant is what let the
# 2026-07-21 remediation sweep ship `flake.nix` to 59 repos that should have
# received Guix or a container.
#
# It also had NO sealed-container detection at all, so the policy's own escape
# hatch could not satisfy the policy — a repo doing exactly the right thing for
# the not-in-Guix tail was reported as having no packaging.
#
# PREDICATE — deliberately tightened. The previous step accepted *any* `*.scm`
# anywhere in the tree as proof of "Guix package management detected", which a
# stray Guile source file satisfies without any packaging existing. This script
# requires a genuine packaging artefact (guix.scm / manifest.scm / channels.scm
# / .guix-channel) and prunes vendored trees so a dependency's file cannot
# satisfy the policy on the repo's behalf. Measured 2026-07-21 over the 412 real
# repo-root callers, tightening moved only 13 repos (57 -> 70 failing), so the
# honest predicate is nearly free.
#
# GRACE WINDOW: 70/412 callers (17%) currently satisfy neither. They warn until
# the cutoff, then fail. The cutoff is a real date that flips itself with no
# further edit to this file.
#
# NOTE ON LOCKFILES: the replaced step also grepped `git diff HEAD~1` for
# package-lock.json / yarn.lock / Gemfile.lock / Pipfile.lock / poetry.lock.
# That branch was inert — governance checks out at `ref: github.sha` without
# `fetch-depth: 0`, so `HEAD~1` does not resolve and the command was swallowed
# by `2>/dev/null` / `|| true`. It is dropped here rather than kept as a stub:
# the blocking rule for lockfiles is hypatia `cicd_rules/nodejs_detected`.
# Broadening that rule beyond package-lock.json is tracked as follow-up.
#
# Usage: check-package-policy.sh [repo-root]
#
# Environment (test seams — the shipped policy is the default in each case):
#   ENFORCE_PACKAGE_POLICY_FROM  YYYY-MM-DD; enforcement begins ON this date.
#   ENFORCE_NIX_RETIREMENT_FROM  YYYY-MM-DD; date Nix-only stops warning and
#                                starts failing. Owner-set: 2026-06-01.
#   PKG_TODAY                    YYYY-MM-DD; overrides "now" so the pre-cutoff
#                                and post-cutoff branches are both testable.
#
# Exit: 0 = pass (or in-grace warning), 1 = policy failure or bad configuration.

set -euo pipefail

ROOT="${1:-.}"

ENFORCE_PACKAGE_POLICY_FROM="${ENFORCE_PACKAGE_POLICY_FROM:-2026-08-21}"
TODAY="${PKG_TODAY:-$(date -u +%Y-%m-%d)}"

# An unparseable cutoff would make the comparison below pick the grace branch
# forever, restoring the fake gate this script replaces. Refuse to run.
valid_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}
require_date() {
  local name="$1" value="$2"
  if ! valid_date "$value"; then
    echo "::error::check-package-policy: $name='$value' is not YYYY-MM-DD."
    echo "Refusing to run: an unparseable cutoff would silently disarm this gate."
    exit 1
  fi
}
require_date ENFORCE_PACKAGE_POLICY_FROM "$ENFORCE_PACKAGE_POLICY_FROM"
require_date PKG_TODAY "$TODAY"

if [ ! -d "$ROOT" ]; then
  echo "::error::check-package-policy: '$ROOT' is not a directory."
  exit 1
fi

# Vendored trees cannot satisfy the policy on the repo's behalf.
PRUNE=( -name .git -o -name node_modules -o -name deps -o -name .lake -o -name vendor )

# NB: `find … | head -1` under `set -o pipefail` is a SIGPIPE race — head exits
# after the first line, find keeps writing, takes SIGPIPE, and pipefail
# propagates the non-zero status, aborting the script under `set -e`. It only
# manifests on trees large enough that find is still running when head exits, so
# small fixtures never catch it (it red two real estate repos intermittently
# while every unit fixture passed). `|| true` neutralises the pipeline status;
# the guix/nix decision is made from the captured value, not the exit code.
find_first() {
  local out
  out="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \( "$@" \) -print 2>/dev/null | head -1 || true)"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# APPLICABILITY (2026-10-01, owner decision "only repos that need it").
# Packaging is NOT a universal criterion. rsr-criteria-v2.a2ml gates 1.2.1
# guix-primary and 8.1.4 no-scaffold-stub on `reproducible-build`, and 1.2.3
# container-rootless on `container`; a criterion applies iff its gate is
# `universal` OR the repo's rsr-profile declares the gating capability. This
# script previously demanded packaging of every repo, contradicting the canon
# for docs, proof and Julia libraries — 86/325 governance callers red, every
# one of them with no rsr-profile at all.
#
# Capabilities are resolved by scripts/check-rsr-profile.sh, the reference
# implementation of preset + capabilities + add - remove, not re-derived here.
# No profile ⇒ no declared capability ⇒ not applicable (a notice names the file
# to add). The Nix ban is a removal ruling, not a capability, so it still fails
# whatever the profile says.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSR_PROFILE_CHECKER="${RSR_PROFILE_CHECKER:-$SCRIPT_DIR/check-rsr-profile.sh}"

# deed_has_profile <file>: exit 0 when the deed carries an "(rsr-profile"
# head outside comments and strings, else 1. Awk reads the file itself, with
# no pipe: a pipe into "grep -q" lets the producer die of SIGPIPE on a large
# deed, which pipefail turns into a false "no profile". A ";" outside a string
# starts a comment, and string state is per line, both as in the resolver's
# deed_strip. A head at the end of a line ends at whitespace there too.
deed_has_profile() {
  awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) }
  { n = length($0); q = 0
    for (i = 1; i <= n; i++) { c = substr($0, i, 1)
      if (q) { if (c == bs) i++; else if (c == dq) q = 0; continue }
      if (c == dq) { q = 1; continue }
      if (c == ";") break
      if (c == "(" && substr($0, i, 12) == "(rsr-profile" && (i + 12 > n || substr($0, i + 12, 1) ~ /[[:space:]);]/)) { found = 1; exit } } }
  END { exit !found }' "$1"
}

# Print the repo's effective capabilities, one per line; nothing if it has no
# profile. A profile the reference checker cannot resolve declares nothing it
# can read, so it counts as undeclared but is NAMED in a warning (e.g. an
# explicit `capabilities = []`, which check-rsr-profile.sh rejects). A missing
# resolver is handled the same way, also with a named warning.
effective_capabilities() {
  local f found="" out
  for f in "$ROOT"/.machine_readable/rsr-profile.a2ml "$ROOT"/machine-readable/rsr-profile.a2ml; do
    [ -f "$f" ] && found="$f" && break
  done
  # Deed-era profile: an (rsr-profile …) clause of the repo's <repo>_chora.deed
  # (the worked model, rsr-template-repo, has carried its profile there since
  # it retired its last .a2ml). The resolver parses it; this is only discovery,
  # so a clause token outside a ";" comment is enough to hand the deed over.
  # estate_chora.deed is the estate-deed, never a repo deed.
  if [ -z "$found" ]; then
    # ".*_chora.deed" too: the deed grammar allows a dot-led stem (.github).
    # One of the two patterns normally has no match, so failglob must be off;
    # dotglob would make the first match the dot-led deed as well.
    shopt -u dotglob failglob
    for f in "$ROOT"/*_chora.deed "$ROOT"/.*_chora.deed; do
      [ -f "$f" ] || continue
      [ "$(basename "$f")" = estate_chora.deed ] && continue
      if deed_has_profile "$f"; then found="$f"; break; fi
    done
  fi
  [ -n "$found" ] || return 0
  if [ ! -f "$RSR_PROFILE_CHECKER" ]; then
    # Callers pinned to a governance-reusable from before 2026-10-01 copy this
    # script alone, so the resolver is absent there by construction. Reddening
    # them would turn a deployment-shape gap into a policy failure.
    echo "::warning::check-package-policy: capability resolver missing at $RSR_PROFILE_CHECKER (caller pin predates it); ${found#"$ROOT"/} not read, treating it as declaring no packaging capability." >&2
    return 0
  fi
  out="$(bash "$RSR_PROFILE_CHECKER" "$ROOT" 2>&1 || true)"
  if ! printf '%s\n' "$out" | grep -q '^effective capabilities:'; then
    echo "::warning::check-package-policy: ${found#"$ROOT"/} could not be resolved ($(printf '%s\n' "$out" | grep -m1 ERROR || echo "no effective capabilities line")); treating it as declaring no packaging capability." >&2
    return 0
  fi
  printf '%s\n' "$out" | sed -n 's/^effective capabilities: //p' | tr ' ' '\n' | sed '/^$/d'
}

# Every match, not the first: a repo's real build/container/Containerfile must
# not be shadowed by an earlier-sorting fuzzing image (.clusterfuzzlite/ ships
# a deliberately minimal OSS-Fuzz Containerfile that is not packaging).
find_all() {
  find "$ROOT" \( "${PRUNE[@]}" -o -path "$ROOT/.clusterfuzzlite" \) -prune -o \( "$@" \) -print 2>/dev/null | sort || true
}

# A scaffold stub per criterion 8.1.4: an unfilled placeholder or `(source #f)`.
is_stub_guix() { grep -qE '\(source #f\)|\{\{[A-Z_]+\}\}' "$1"; }

GUIX_ALL="$(find_all -name guix.scm -o -name manifest.scm -o -name channels.scm -o -name .guix-channel)"
GUIX="" GUIX_STUB=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ "$(basename "$f")" = guix.scm ] && is_stub_guix "$f"; then
    GUIX_STUB="${GUIX_STUB:-$f}"
  else
    GUIX="$f"; break
  fi
done <<< "$GUIX_ALL"
NIX="$(find_first -name flake.nix -o -name default.nix -o -name shell.nix)"
# Sealed container — the policy's named escape hatch. `Containerfile*` and
# `Dockerfile*` both count.
CONTAINERS="$(find_all -name 'Containerfile*' -o -name 'Dockerfile*')"

if [ -n "$GUIX" ]; then
  echo "✅ Guix package management detected (primary): ${GUIX#"$ROOT"/}"
  exit 0
fi

# A Containerfile only counts if it BUILDS something: at least one ACTIVE
# RUN / ENTRYPOINT / CMD instruction. The estate scaffold ships a template whose
# every install/build line is a commented `# TODO:` example (17/60 measured
# 2026-07-27); presence alone would reproduce the fault of standards#505.
# Every Containerfile is tried; any one with active instructions satisfies.
CONTAINER="" CONTAINER_STUB=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qiE '^[[:space:]]*(RUN|ENTRYPOINT|CMD)[[:space:]]' "$f"; then
    CONTAINER="$f"; break
  fi
  CONTAINER_STUB="${CONTAINER_STUB:-$f}"
done <<< "$CONTAINERS"

if [ -n "$CONTAINER" ]; then
  echo "✅ Sealed-container packaging detected (escape hatch): ${CONTAINER#"$ROOT"/}"
  echo "::notice::Guix is the estate primary; a sealed container is the" \
       "accepted escape hatch for the not-in-Guix / non-free tail."
  exit 0
fi
if [ -n "$CONTAINER_STUB" ]; then
  echo "::warning::${CONTAINER_STUB#"$ROOT"/} is the UNFILLED scaffold template —" \
       "every install/build step is a commented '# TODO:' example, so it" \
       "provides no environment and does not satisfy the policy."
fi

# Applicability is resolved only now: a repo with real packaging passed above
# whatever its profile says, so a profile defect can never redden it.
CAPS="$(effective_capabilities)" || exit 1
REQUIRED=""
if printf '%s
' "$CAPS" | grep -qxE 'reproducible-build|container'; then
  REQUIRED="$(printf '%s
' "$CAPS" | grep -xE 'reproducible-build|container' | paste -sd ' ' -)"
fi

# Nix-only. Under the 2026-05-18 ruling this is NOT compliance — Nix is not a
# tier — and the 2026-07-28 ruling removes it from the estate outright. That is
# a ban, not a capability, so it applies whatever the profile declares.
#
# ⚠ SEQUENCING — read before changing ENFORCE_NIX_RETIREMENT_FROM.
# Nix retirement must TRAIL per-repo Guix functionality: for a repo whose
# guix.scm is a stub, "delete the flake" means "have no working packaging".
if [ -n "$NIX" ]; then
  ENFORCE_NIX_RETIREMENT_FROM="${ENFORCE_NIX_RETIREMENT_FROM:-2026-06-01}"
  require_date ENFORCE_NIX_RETIREMENT_FROM "$ENFORCE_NIX_RETIREMENT_FROM"

  if [[ "$TODAY" < "$ENFORCE_NIX_RETIREMENT_FROM" ]]; then
    echo "::warning::Nix-only packaging (${NIX#"$ROOT"/}). Nix is NOT an estate" \
         "tier — Guix is primary, sealed container is the escape hatch. This" \
         "becomes a BLOCKING failure on $ENFORCE_NIX_RETIREMENT_FROM (today is $TODAY)."
    echo "NOT YET ENFORCED: Nix-only packaging inside the retirement grace window."
    exit 0
  fi

  echo "::error::Nix-only packaging is not compliant: ${NIX#"$ROOT"/}"
  echo
  echo "Estate policy (3-practice/LANGUAGE-POLICY.adoc, RULED 2026-05-18) is Guix primary"
  echo "+ sealed-container escape; NO Nix mirror. HARDENED 2026-07-28: Nix is REMOVED."
  if [ -z "$REQUIRED" ]; then
    echo "This repo declares no packaging capability, so deleting the flake is the whole fix."
  else
    echo "This repo declares: $REQUIRED — replace the flake with a real guix.scm or"
    echo "an active Containerfile IN THE SAME CHANGE (spec/scaffold-stub-debt.adoc, step 3)."
  fi
  exit 1
fi

# Only a stub guix.scm. Before capability gating this passed on presence, and
# ~90 repos rely on that; 8.1.4 is gated on reproducible-build, so the stub
# only fails where that capability (or container) is declared.
if [ -n "$GUIX_STUB" ]; then
  if [ -z "$REQUIRED" ]; then
    echo "::notice::${GUIX_STUB#"$ROOT"/} is a scaffold stub (criterion 8.1.4)." \
         "Not enforced: this repo declares neither reproducible-build nor container."
    echo "✅ Packaging not applicable (no packaging capability declared)."
    exit 0
  fi
  echo "::error::${GUIX_STUB#"$ROOT"/} is a scaffold stub (placeholder or (source #f))," \
       "and this repo declares: $REQUIRED. A stub builds nothing (criterion 8.1.4)."
  echo "Make the guix.scm real, or add a Containerfile with active RUN/CMD steps."
  exit 1
fi

if [ -z "$REQUIRED" ]; then
  echo "::notice::No packaging, and none required: the repo's rsr-profile declares" \
       "neither reproducible-build nor container." \
       "A repo that ships a build should declare one in its repo deed's (rsr-profile …) clause" \
       "(or the legacy .machine_readable/rsr-profile.a2ml)."
  echo "✅ Packaging not applicable (no packaging capability declared)."
  exit 0
fi

# Violation: packaging declared, none present.
if [[ "$TODAY" < "$ENFORCE_PACKAGE_POLICY_FROM" ]]; then
  echo "::warning::No packaging found but the profile declares: $REQUIRED — this" \
       "becomes a BLOCKING failure on $ENFORCE_PACKAGE_POLICY_FROM (today is $TODAY)."
  echo "NOT YET ENFORCED: package policy unmet but inside the grace window."
  exit 0
fi

echo "::error::Package policy violation: the profile declares $REQUIRED, but no packaging was found."
echo
echo "Add one of:"
echo "  guix.scm | manifest.scm | channels.scm | .guix-channel   (primary; not a stub)"
echo "  Containerfile with active RUN/CMD/ENTRYPOINT            (escape hatch)"
echo "or remove the capability from the repo deed's (rsr-profile …) clause (or the legacy"
echo ".machine_readable/rsr-profile.a2ml) if it is not real."
echo
echo "Files inside .git/ node_modules/ deps/ .lake/ vendor/ .clusterfuzzlite/ do not count."
exit 1
