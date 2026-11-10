#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# check-licence-consistency.sh
#
# Verifies that a repo's licensing story is internally consistent:
#   (1) A LICENSE / LICENCE / COPYING file is present at repo root.
#   (2) The LICENSE body text classifies to a known licence template.
#   (3) The licence identity is established by EITHER an SPDX-License-Identifier
#       header on the LICENSE file's first few lines, OR — for a verbatim,
#       header-less licence file — the body-text classification itself. The
#       estate template ships LICENSE as plain, unmodified MPL-2.0 text with no
#       SPDX header (SPDX identifiers belong in *source* files, not in the
#       canonical upstream licence text), so a header-less verbatim MPL-2.0
#       LICENSE is consistent — not a finding.
#   (4) If a build manifest declares a licence, it matches that identity.
#   (5) When an SPDX header IS present, the body text must agree with it (loose
#       check — catches the common drift of SPDX=MPL-2.0 but body=PMPL).
#
# Exit codes:
#   0 — all checks pass.
#   1 — at least one check failed.
#   2 — invocation / environment error.
#
# Wired into governance-reusable.yml as the `licence-consistency` job.
#
# Estate policy reference: MPL-1.0 / PMPL-1.0 → MPL-2.0 migration target.

set -u

repo_root="${1:-.}"
cd "$repo_root" || { echo "ERROR: cannot cd to $repo_root" >&2; exit 2; }

failed=0
emit() {
  # 1=level (ERROR/WARN/OK), 2=message
  printf '[%s] %s\n' "$1" "$2"
}

# ─────────────────────────────────────────────────────────────────────────────
# (1) LICENSE file presence
# ─────────────────────────────────────────────────────────────────────────────
lic_file=""
for cand in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING; do
  if [ -f "$cand" ]; then
    lic_file="$cand"
    break
  fi
done

if [ -z "$lic_file" ]; then
  emit ERROR "No LICENSE / LICENCE / COPYING file at repo root."
  emit ERROR "Estate default is MPL-2.0 — see docs/audits/2026-05-26-estate-licence-debt.md."
  # Cannot proceed with remaining checks without a file.
  exit 1
fi
emit OK "LICENSE file found: $lic_file"

# ─────────────────────────────────────────────────────────────────────────────
# (2) Classify LICENSE body text
#     Computed first because a verbatim, header-less licence file establishes
#     its identity from the body alone (see (3)).
# ─────────────────────────────────────────────────────────────────────────────
# Use a helper because `grep -c` exits non-zero on zero-matches AND prints "0"
# to stdout, so `|| echo 0` concatenates to "0\n0". Pipe through wc -l which
# always returns a single integer.
count_in()   { grep -E  "$1" "$lic_file" 2>/dev/null | wc -l; }
count_in_i() { grep -iE "$1" "$lic_file" 2>/dev/null | wc -l; }
has_mpl2_text=$(count_in 'Mozilla Public License Version 2\.0|Mozilla Public License, version 2\.0')
has_pmpl_text=$(count_in_i 'PMPL-1\.0-or-later|Palimpsest License \(PMPL')
has_apache=$(count_in 'Apache License.*Version 2\.0')
has_mit=$(count_in 'MIT License')
has_agpl=$(count_in 'GNU AFFERO GENERAL PUBLIC LICENSE')
has_gpl3=$(count_in 'GNU GENERAL PUBLIC LICENSE.*Version 3')
has_bsd3=$(count_in 'BSD.*3-Clause')
has_proprietary=$(count_in_i 'All Rights Reserved')

body_class="UNKNOWN"
# Order matters: the legally-binding text dominates classification.
if [ "$has_proprietary" -gt 0 ] && [ "$has_mpl2_text" -eq 0 ]; then
  body_class="PROPRIETARY"
elif [ "$has_mpl2_text" -gt 0 ]; then
  # MPL-2.0 text is present in the body — this is binding even when wrapped
  # in a Palimpsest preamble.
  body_class="MPL-2.0"
elif [ "$has_pmpl_text" -gt 0 ]; then
  body_class="PMPL-1.0"
elif [ "$has_apache" -gt 0 ]; then
  body_class="Apache-2.0"
elif [ "$has_mit" -gt 0 ]; then
  body_class="MIT"
elif [ "$has_agpl" -gt 0 ]; then
  # AGPL before plain GPL-3.0: the AGPL body carries "GNU AFFERO GENERAL PUBLIC
  # LICENSE". These are deliberate co-developed-project exceptions to the estate
  # MPL-2.0 policy (e.g. the games airborne-submarine-squadron, the-nash-equilibrium)
  # and must be recognised so their full-text LICENSE files (which GitHub then
  # detects as AGPL, unlike an SPDX-stub) pass this check.
  body_class="AGPL-3.0"
elif [ "$has_gpl3" -gt 0 ]; then
  body_class="GPL-3.0"
elif [ "$has_bsd3" -gt 0 ]; then
  body_class="BSD-3-Clause"
fi

# Normalize for loose, case-insensitive licence comparison.
normalize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/-or-later$//;s/^[[:space:]]+|[[:space:]]+$//g'
}

# ─────────────────────────────────────────────────────────────────────────────
# (3) Establish licence identity: SPDX header if present, else verbatim body.
#     `effective_lic` is the canonical identity used by the manifest check (4).
# ─────────────────────────────────────────────────────────────────────────────
spdx_header=$(grep -m1 -E '^[[:space:]]*SPDX-License-Identifier:' "$lic_file" 2>/dev/null \
  | sed -E 's/^[[:space:]]*SPDX-License-Identifier:[[:space:]]*//' \
  | head -c 80 | tr -d '[:space:]')

effective_lic=""
if [ -n "$spdx_header" ]; then
  emit OK "SPDX header: $spdx_header"
  effective_lic="$spdx_header"
elif [ "$body_class" != "UNKNOWN" ]; then
  # No SPDX header, but the body is a recognised verbatim licence. This is the
  # estate template's canonical shape (plain MPL-2.0 text, no header) and is
  # internally consistent — accept it and use the body classification as the
  # licence identity for the manifest cross-check below.
  emit OK "LICENSE has no SPDX header, but its body is verbatim $body_class text — accepted as a canonical licence file."
  effective_lic="$body_class"
else
  emit ERROR "LICENSE file has no 'SPDX-License-Identifier:' header and its body matches no known licence template."
  emit ERROR "Add an SPDX header, or use a recognised verbatim licence text, so downstream scanners (REUSE, cargo-license, etc.) can identify the licence."
  failed=1
fi

# ─────────────────────────────────────────────────────────────────────────────
# (4) Manifest declared licence vs the established identity
# ─────────────────────────────────────────────────────────────────────────────
manifest_path=""
manifest_decl=""

if [ -f "Cargo.toml" ]; then
  manifest_path="Cargo.toml"
  manifest_decl=$(grep -m1 -E '^license[[:space:]]*=' "$manifest_path" 2>/dev/null \
    | sed -E 's/^license[[:space:]]*=[[:space:]]*//' \
    | tr -d '"' | head -c 80 | sed -E 's/[[:space:]]+$//')
elif [ -f "package.json" ]; then
  manifest_path="package.json"
  manifest_decl=$(grep -m1 -E '"license"[[:space:]]*:' "$manifest_path" 2>/dev/null \
    | sed -E 's/.*"license"[[:space:]]*:[[:space:]]*//' \
    | tr -d '",' | head -c 80 | sed -E 's/[[:space:]]+$//')
elif [ -f "pyproject.toml" ]; then
  manifest_path="pyproject.toml"
  manifest_decl=$(grep -m1 -E '^license[[:space:]]*=' "$manifest_path" 2>/dev/null \
    | sed -E 's/^license[[:space:]]*=[[:space:]]*//' \
    | tr -d '"{}' | head -c 80 | sed -E 's/[[:space:]]+$//;s/text[[:space:]]*=[[:space:]]*//')
elif [ -f "mix.exs" ]; then
  manifest_path="mix.exs"
  # mix.exs uses `licenses: ["MPL-2.0"]`
  manifest_decl=$(grep -m1 -E 'licenses[[:space:]]*:' "$manifest_path" 2>/dev/null \
    | sed -E 's/.*licenses[[:space:]]*:[[:space:]]*\[//' \
    | sed -E 's/\].*//' | tr -d '" ' | head -c 80)
elif [ -f "Project.toml" ]; then
  manifest_path="Project.toml"
  manifest_decl=$(grep -m1 -iE '^license[[:space:]]*=' "$manifest_path" 2>/dev/null \
    | sed -E 's/^[Ll]icense[[:space:]]*=[[:space:]]*//' \
    | tr -d '"' | head -c 80 | sed -E 's/[[:space:]]+$//')
elif ls ./*.ipkg >/dev/null 2>&1; then
  manifest_path="$(ls -1 ./*.ipkg | head -1)"
  # ipkg files carry SPDX header in a comment line
  manifest_decl=$(grep -hm1 -iE '^[[:space:]]*--[[:space:]]*SPDX-License-Identifier' "$manifest_path" 2>/dev/null \
    | sed -E 's/.*SPDX-License-Identifier[[:space:]]*:[[:space:]]*//' \
    | head -c 80 | sed -E 's/[[:space:]]+$//')
elif ls ./*.cabal >/dev/null 2>&1; then
  manifest_path="$(ls -1 ./*.cabal | head -1)"
  manifest_decl=$(grep -hm1 -iE '^license[[:space:]]*:' "$manifest_path" 2>/dev/null \
    | sed -E 's/^[lL]icense[[:space:]]*:[[:space:]]*//' \
    | head -c 80 | sed -E 's/[[:space:]]+$//')
fi

if [ -n "$manifest_path" ] && [ -z "$manifest_decl" ]; then
  emit WARN "Manifest $manifest_path present but no licence field detected."
elif [ -n "$manifest_decl" ]; then
  emit OK "Manifest licence ($manifest_path): $manifest_decl"
fi

if [ -n "$effective_lic" ] && [ -n "$manifest_decl" ]; then
  el_norm=$(normalize "$effective_lic")
  mh_norm=$(normalize "$manifest_decl")
  # mh may contain `MIT OR Apache-2.0` — accept if the licence identity is one of them.
  if echo "$mh_norm" | grep -qE "(^|\W)$el_norm(\W|$)"; then
    emit OK "Licence identity matches manifest declaration."
  else
    emit ERROR "Licence-vs-manifest mismatch: licence='$effective_lic' manifest='$manifest_decl' ($manifest_path)."
    failed=1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (5) When an SPDX header is present, the body text must agree with it.
#     Header-less files already derived their identity from the body in (3),
#     so there is nothing to cross-check here for them.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$spdx_header" ]; then
  spdx_norm=$(normalize "$spdx_header")
  body_norm=$(echo "$body_class" | tr '[:upper:]' '[:lower:]')

  if [ "$body_class" = "UNKNOWN" ]; then
    emit WARN "LICENSE body did not match any known licence template. Manual review recommended."
  elif [ "$body_class" = "PROPRIETARY" ] && [ "$spdx_norm" != "licenseref-proprietary" ]; then
    emit ERROR "LICENSE body says 'All Rights Reserved' (proprietary) but SPDX header says '$spdx_header'."
    emit ERROR "Either flip LICENSE body to the SPDX-declared licence text, or set the SPDX header to LicenseRef-Proprietary."
    failed=1
  elif [ "$spdx_norm" = "mpl-2.0" ] && [ "$body_class" = "PMPL-1.0" ]; then
    emit ERROR "SPDX header says MPL-2.0 but LICENSE body text is still PMPL-1.0-or-later."
    emit ERROR "Migrate body to canonical MPL-2.0 text (see metadatastician/standards docs/audits/2026-05-26-estate-licence-debt.md)."
    failed=1
  elif [ "$body_norm" = "$spdx_norm" ]; then
    emit OK "LICENSE body text matches SPDX header."
  else
    emit WARN "LICENSE body classification ($body_class) doesn't obviously match SPDX header ($spdx_header). Spot-check."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (6) Tree-wide ADVISORY for retired estate licence identifiers in SPDX
#     headers. The manifest check in (4) only sees the first build manifest;
#     stray identifiers in ordinary source files are invisible to it — that is
#     how ipfs-overlay#134 hid: one .ipkg plus three .idr files carried
#     PMPL-1.0-or-later while the repo's identity is MPL-2.0.
#
#     WARN-level by design, per docs/migrations/pmpl-to-mpl-sweep-runbook.adoc:
#     licence edits are per-file and owner-approval-gated, NEVER a bulk sweep,
#     so this gate surfaces drift for filing — it never blocks.
#
#     False-positive control:
#       - grep is anchored: a hit must be a comment-line SPDX *header*
#         (^ optional comment marker, then SPDX-License-Identifier:).
#         Prose, badges and test fixtures that merely quote the string in
#         mid-line cannot match.
#       - estate carve-out repos (palimpsest-license, palimpsest-plasma, 007)
#         are skipped entirely: PMPL/ARR is correct there (runbook §1, §3).
#       - licence-exhibit text (LICENSES/, legal/, exhibits/, PMPL-SPEC*) is
#         excluded (runbook §3).
# ─────────────────────────────────────────────────────────────────────────────
repo_id="${GITHUB_REPOSITORY:-}"
if [ -z "$repo_id" ]; then
  repo_id=$(git remote get-url origin 2>/dev/null \
    | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')
fi
case "$repo_id" in
  hyperpolymath/palimpsest-license|hyperpolymath/palimpsest-plasma|hyperpolymath/007)
    emit OK "Carve-out repo ($repo_id): retired-estate SPDX advisory skipped (sweep runbook §1/§3)."
    ;;
  *)
    # Anchored header pattern: line starts with an optional comment marker.
    retired_hdr_re='^[[:space:]]*(#[#!]?|--|//|/\*|\(\*|;+|%+|\*+)?[[:space:]]*SPDX-License-Identifier:[[:space:]]*(PMPL-1\.0|MPL-1\.0|MPL-1\.1)'
    stray=$(grep -rIlE "$retired_hdr_re" . \
      --exclude-dir=.git --exclude-dir=LICENSES --exclude-dir=legal \
      --exclude-dir=exhibits --exclude='PMPL-SPEC*' 2>/dev/null | sort)
    if [ -n "$stray" ]; then
      emit WARN "Stray retired-estate SPDX header(s) found (PMPL-1.0*/MPL-1.0*/MPL-1.1). Not a gate failure: per-file, owner-approval-gated edits only — see docs/migrations/pmpl-to-mpl-sweep-runbook.adoc. File an issue with acceptance criteria; do NOT bulk-sweep."
      while IFS= read -r f; do
        hit=$(grep -m1 -E "$retired_hdr_re" "$f" 2>/dev/null | sed 's/^[[:space:]]*//')
        emit WARN "  $f: $hit"
      done <<EOF_STRAY
$stray
EOF_STRAY
    else
      emit OK "No stray retired-estate SPDX headers (PMPL-1.0*/MPL-1.0*/MPL-1.1) in the tree."
    fi
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$failed" -eq 0 ]; then
  emit OK "Licence consistency check passed."
  exit 0
else
  emit ERROR "Licence consistency check failed. See messages above."
  exit 1
fi
