#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-launcher-standard-currency.sh -- fail if a repo claims compliance with a
# launcher standard filename or version that no longer exists upstream.
#
# standards#960 acceptance criterion 4.
#
# WHY THIS EXISTS
# ---------------
# `launcher/launcher-standard.a2ml` was DELETED from `standards` on 2026-09-22
# (#952, be6c9580) and replaced by `launcher/launcher-standard_praxis.deed`.
# Nothing told the downstream repos. A census on 2026-09-22 found 21 distinct
# `*.launcher.a2ml` descriptors, plus `trigger/scripts/trigger-launcher.sh`,
# still declaring "Compliant with launcher-standard.a2ml v0.3.0" -- a filename
# that is gone and a version that no longer exists. Both claims read as
# compliance and neither is checkable, which is the vacuous-gate pattern the
# estate rules against.
#
# THE TWO DEFECTS ARE INDEPENDENT
# -------------------------------
# A reference fails on the FILENAME or on the VERSION, separately:
#
#   launcher-standard.a2ml           any version  -> FAIL (retired filename)
#   launcher-standard_praxis.deed    v0.5.0       -> FAIL (stale version)
#   launcher-standard.a2ml           v0.6.0       -> FAIL (filename only)
#   launcher-standard_praxis.deed    v0.6.0       -> PASS
#
# A reference carrying no version token is checked on the filename alone; that
# is not a defect in itself, because plenty of prose names the standard without
# pinning it.
#
# `launcher-standard.adoc` is a DIFFERENT document (the human-readable UX
# standard) and is deliberately NOT checked here. It declares no version of its
# own, so a version claim against it is a separate defect and belongs in its
# own gate rather than being smuggled into this one.
#
# ANTI-DRIFT: THE EXPECTED VERSION IS NOT A MAGIC NUMBER
# ------------------------------------------------------
# CURRENT_VERSION below is a default for consumer repos, which do not carry the
# standard. It is NOT the authority. `scripts/tests/` asserts that this default
# equals `:standard-version` in the real deed, so bumping the standard without
# updating this script turns `standards`' own CI red. A checker whose expected
# value can silently drift from the thing it checks is worse than no checker.
# Consumers that DO vendor the deed should pass `--standard <path>` and read the
# version from the artefact instead of trusting this default.
#
# HISTORICAL RECORDS ARE ALLOWLISTED BY PATH, NEVER BY CONTENT
# ------------------------------------------------------------
# standards#960 AC1 exempts "a dated historical record". That exemption is a
# PATH allowlist (see ALLOWLIST below), not a content heuristic: a heuristic
# that spares any line mentioning "formerly" or "translated from" would spare
# the live defect too, because that is exactly how a stale descriptor comment
# is worded.
#
# EXIT CODES
#   0  no defects
#   1  at least one defect
#   2  usage error, or a seeded mutant survived --self-test
set -uo pipefail

CANONICAL_FILE="launcher-standard_praxis.deed"
RETIRED_FILE="launcher-standard.a2ml"
CURRENT_VERSION="0.6.0"
SELF_TEST_TMP=""

# Path globs exempt as historical records. Matched against the repo-relative
# path. Each entry is justified; do not add one without a reason.
ALLOWLIST=(
  'docs/audits/*'                    # dated audit records (AC1's exemption)
  'docs/triage/*'                    # dated backlog classifications. Same class as docs/audits/:
                                     # a record whose SUBJECT is a rename must be able to name the
                                     # renamed file, or the record disagrees with the issue it
                                     # indexes. This exempts the record, not new guidance: a live
                                     # document instructing anyone to use the retired name is still
                                     # a defect, and the check still reports it everywhere else.
  '9-archive/*'                      # frozen history (9-archive/MOVED.adoc indexes it). A record moved
                                     # there keeps the names of its day; it is read, never updated. The
                                     # retired A2ML corpus lands under 9-archive/a2ml/ with original paths,
                                     # so docs/audits/* above no longer matches an archived audit on its own.
  '1-formats/deed/mappings/*'        # the .a2ml -> .deed conversion record; naming both is its job
  'dev-notes/*'                      # working notes, not compliance claims
  '*HANDOVER*'                       # handover documents record prior state
  '*CHANGELOG*'                      # a changelog that cannot name the old file is useless
  'launcher-standard_praxis.deed'    # the canon itself, at a repo root; its ;; header records its own provenance
  '*/launcher-standard_praxis.deed'  # ...and the same canon VENDORED at any depth by a consumer (G2)
  '*/descriptiles/META.a2ml'         # descriptiles ADR carriers: dated architecture decision records
                                     # (G3, AC1's exemption). Canonical spelling, 0-canon/CANONICAL-NAMES.adoc.
  '*/6a2/META.a2ml'                  # ...and the deprecated '6a2' spelling of descriptiles. Both are needed:
                                     # the estate migration is chartered separately and BOTH are on disk today
                                     # (measured 2026-09-22: descriptiles 164 dirs, the deprecated one 770).
                                     # NARROW BY DESIGN: matches only META.a2ml under those dirs, never
                                     # `.machine_readable/launcher/*.launcher.a2ml`, which are live descriptors.
  'scripts/check-launcher-standard-currency.sh'        # this file
  'scripts/tests/check-launcher-standard-currency-test.sh'
)

usage() {
  cat <<USAGE
Usage: check-launcher-standard-currency.sh [options]

  --root DIR            tree to scan (default: .)
  --standard FILE       read the expected version from a deed's :standard-version
  --expect-version VER  expected version, overrides --standard and the default
  --self-test           run the seeded-mutant self-test and exit
  -h, --help            this message

Expected version resolution order:
  --expect-version  >  --standard  >  built-in default (${CURRENT_VERSION})
USAGE
}

# Read :standard-version out of a praxis deed. The DEED grammar carries TWO
# versions and they are not interchangeable: :schema-version is the GRAMMAR
# (1.0.0) and :standard-version is the DOCUMENT. Reading the first yields a
# number that looks like a newer spec, so the resulting error reads as an
# upgrade rather than as drift.
read_standard_version() {
  local f="$1" v
  [ -r "$f" ] || { echo "ERROR: cannot read standard file: $f" >&2; return 2; }
  v=$(command grep -m1 -oE ':standard-version[[:space:]]+"[0-9]+\.[0-9]+\.[0-9]+"' "$f" \
        | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] || { echo "ERROR: no :standard-version in $f" >&2; return 2; }
  printf '%s' "$v"
}

is_allowlisted() {
  local path="$1" glob
  for glob in "${ALLOWLIST[@]}"; do
    # shellcheck disable=SC2053
    [[ "$path" == $glob ]] && return 0
  done
  return 1
}

# Scan $1 recursively for retired filenames and document-version claims that
# differ from $2. Allowlisted paths and DEED grammar/schema versions are ignored.
# Prints one typed record per defect; returns 0 when clean and 1 otherwise.
scan() {
  local root="$1" expect="$2" defects=0 hit file lineno text rel found gap gaplc

  while IFS= read -r hit; do
    file="${hit%%:*}"; hit="${hit#*:}"
    lineno="${hit%%:*}"; text="${hit#*:}"
    rel="${file#"$root"/}"; rel="${rel#./}"
    is_allowlisted "$rel" && continue

    if [[ "$text" == *"$RETIRED_FILE"* ]]; then
      printf 'DEFECT retired-filename  %s:%s  names %s (deleted upstream 2026-09-22, #952)\n' \
        "$rel" "$lineno" "$RETIRED_FILE"
      defects=$((defects + 1))
    fi

    if [[ "$text" =~ launcher-standard(\.a2ml|_praxis\.deed)([^0-9]{0,24})v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      gap="${BASH_REMATCH[2]}"
      found="${BASH_REMATCH[3]}"
      # G1 -- THE TWO VERSIONS ARE NOT INTERCHANGEABLE, AND THIS GATE TRACKS ONE.
      # The header above says :schema-version is the GRAMMAR (1.0.0) and
      # :standard-version is the DOCUMENT (0.6.0). This test used to accept any
      # number within 24 non-digit characters of the filename, so a line reading
      #   `launcher-standard_praxis.deed` (DEED v1.0.0). Per-app config:
      # captured the GRAMMAR version and reported it as document drift -- the gate
      # asking a different question than its consumer, in its own implementation.
      # The gap between filename and number says which version is being named, so
      # read it rather than discarding it.
      gaplc="${gap,,}"
      if [[ "$gaplc" == *deed* || "$gaplc" == *schema* || "$gaplc" == *grammar* ]]; then
        :   # a grammar/schema version, not a document-version claim -- not a defect
      elif [ "$found" != "$expect" ]; then
        printf 'DEFECT stale-version     %s:%s  claims v%s, current is v%s\n' \
          "$rel" "$lineno" "$found" "$expect"
        defects=$((defects + 1))
      fi
    fi
  done < <(command grep -rInF -e "$RETIRED_FILE" -e "$CANONICAL_FILE" "$root" --exclude-dir=.git 2>/dev/null)

  [ "$defects" -eq 0 ] && return 0
  printf '\n%s defect(s).\n' "$defects"
  return 1
}

# Seeded-mutant self-test. A passing check proves nothing until a mutant dies,
# so every defect class gets a mutant AND there is a clean negative control.
self_test() {
  local rc=0 out seeded=0
  # NOTE: a `trap ... RETURN` here would NOT be scoped to this function -- bash
  # installs it globally, so it fires on every later function return and, since
  # $tmp is local, dies under `set -u`. Use a global + EXIT trap instead.
  SELF_TEST_TMP="$(mktemp -d)"
  trap 'rm -rf "${SELF_TEST_TMP:-}"' EXIT
  local tmp="$SELF_TEST_TMP"

  mkdir -p "$tmp/docs/audits"
  # mutant 1: retired filename, no version
  printf '# Compliant with %s\n' "$RETIRED_FILE"                      > "$tmp/m1.toml"; seeded=$((seeded+1))
  # mutant 2: canonical filename, stale version
  printf '# Compliant with %s v0.3.0\n' "$CANONICAL_FILE"             > "$tmp/m2.toml"; seeded=$((seeded+1))
  # mutant 3: retired filename WITH the current version -- filename must fail on its own
  printf '# Compliant with %s v%s\n' "$RETIRED_FILE" "$CURRENT_VERSION" > "$tmp/m3.toml"; seeded=$((seeded+1))
  # negative control: fully current, must NOT be reported
  printf '# Compliant with %s v%s\n' "$CANONICAL_FILE" "$CURRENT_VERSION" > "$tmp/clean.toml"
  # allowlist control: the worst mutant, under a dated-audit path -- must NOT be reported
  printf '# Compliant with %s v0.1.0\n' "$RETIRED_FILE"               > "$tmp/docs/audits/old-2026-05-26.adoc"

  # ---- G1/G2/G3 controls. Each of the three cures below silenced a MEASURED
  # false positive on hyperpolymath/launch-scaffolder (4 of them). An exclusion
  # without a mutant proving it is narrow is the vacuous-gate pattern, so the
  # last fixture here MUST still fire: it is the one that proves the three
  # exclusions did not also spare a true positive.
  mkdir -p "$tmp/vendor" "$tmp/.machine_readable/descriptiles" \
           "$tmp/.machine_readable/6a2" "$tmp/.machine_readable/launcher"   # canonical + deprecated spellings

  # G1 control: the DEED GRAMMAR version, not the document version. Must NOT fire.
  printf '| Standard: `%s` (DEED v1.0.0). Per-app config:\n' "$CANONICAL_FILE" > "$tmp/g1-grammar.adoc"

  # G2 control: the canon VENDORED by a consumer, carrying its own provenance
  # header naming the retired file. The allowlist used to name only this repo's
  # own `launcher/` path, so a consumer got a false defect on the canon itself.
  printf ';; translated from %s\n' "$RETIRED_FILE" > "$tmp/vendor/launcher-standard_praxis.deed"

  # G3 control: dated ADR carriers. AC1 exempts a dated historical record, and
  # META.a2ml under a descriptiles dir is an estate-wide convention. BOTH
  # spellings are seeded because both are on disk: the canonical `descriptiles`
  # and the deprecated one it replaces (0-canon/CANONICAL-NAMES.adoc). Neither
  # must fire.
  printf 'adr = "ADR-003"  ;; superseded; named %s\n' "$RETIRED_FILE" \
    > "$tmp/.machine_readable/descriptiles/META.a2ml"
  printf 'adr = "ADR-003"  ;; superseded; named %s\n' "$RETIRED_FILE" \
    > "$tmp/.machine_readable/6a2/META.a2ml"   # the deprecated spelling of descriptiles

  # G3 NARROWNESS control -- THIS ONE MUST STILL FIRE. A live launcher descriptor
  # lives under the same .machine_readable/ tree as the ADR carrier above, so a
  # blanket '.machine_readable/*' exemption would have spared it. It is a real
  # compliance claim against a deleted file and a dead version.
  printf '# Compliant with %s v0.3.0\n' "$RETIRED_FILE" \
    > "$tmp/.machine_readable/launcher/demo-app.launcher.a2ml"; seeded=$((seeded+1))

  if [ "$seeded" -eq 0 ]; then
    echo "SELF-TEST ERROR: zero fixtures seeded -- the self-test is vacuous." >&2
    return 2
  fi

  out="$(scan "$tmp" "$CURRENT_VERSION")" || rc=1

  # Coverage counters. These are INCREMENTED BY THE CHECKS THEMSELVES so the
  # summary line can never drift from the controls actually run -- the previous
  # version printed a hardcoded "2 controls clean" while seven were present.
  local fail=0 ndet=0 nabs=0
  check_detects() {
    ndet=$((ndet + 1))
    if ! printf '%s' "$out" | command grep -q "$1"; then
      echo "SELF-TEST FAIL: mutant survived -- expected to detect: $1" >&2
      fail=1
    fi
  }
  check_absent() {
    nabs=$((nabs + 1))
    if printf '%s' "$out" | command grep -q "$1"; then
      echo "SELF-TEST FAIL: false positive on: $1" >&2
      fail=1
    fi
  }

  check_detects 'retired-filename  m1.toml'
  check_detects 'stale-version     m2.toml'
  check_detects 'retired-filename  m3.toml'
  check_absent  'm3.toml.*stale-version'   # m3 is current; only the filename is wrong
  check_absent  'clean.toml'
  check_absent  'docs/audits'
  check_absent  'g1-grammar.adoc'                 # G1: grammar version is not document drift
  check_absent  'vendor/launcher-standard_praxis.deed'   # G2: a vendored canon is still the canon
  check_absent  'descriptiles/META.a2ml'          # G3: a dated ADR carrier is a historical record
  check_absent  '6a2/META.a2ml'                   # ...same, in the deprecated spelling of descriptiles
  # ...and the exclusions above must NOT have spared a live descriptor:
  check_detects 'retired-filename  .machine_readable/launcher/demo-app.launcher.a2ml'
  check_detects 'stale-version     .machine_readable/launcher/demo-app.launcher.a2ml'

  if [ "$rc" -ne 1 ]; then
    echo "SELF-TEST FAIL: scan returned 0 with mutants present." >&2
    fail=1
  fi

  if [ "$fail" -ne 0 ]; then
    echo "--- scan output was ---" >&2
    printf '%s\n' "$out" >&2
    return 2
  fi

  if [ "$ndet" -eq 0 ] || [ "$nabs" -eq 0 ]; then
    echo "SELF-TEST ERROR: a whole check tier is empty (detects=$ndet absent=$nabs)." >&2
    return 2
  fi
  printf 'self-test: %s mutants seeded, %s detections asserted, %s false-positive controls clean, OK\n' "$seeded" "$ndet" "$nabs"
  return 0
}

main() {
  local root="." standard="" expect="" do_self_test=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root)           root="${2:-}"; shift 2 ;;
      --standard)       standard="${2:-}"; shift 2 ;;
      --expect-version) expect="${2:-}"; shift 2 ;;
      --self-test)      do_self_test=1; shift ;;
      -h|--help)        usage; return 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage >&2; return 2 ;;
    esac
  done

  [ "$do_self_test" -eq 1 ] && { self_test; return $?; }

  if [ -z "$expect" ] && [ -n "$standard" ]; then
    expect="$(read_standard_version "$standard")" || return 2
  fi
  [ -z "$expect" ] && expect="$CURRENT_VERSION"

  if [ ! -d "$root" ]; then
    echo "ERROR: --root is not a directory: $root" >&2
    return 2
  fi

  echo "check-launcher-standard-currency: canonical=${CANONICAL_FILE} expected=v${expect}"
  if scan "$root" "$expect"; then
    echo "No stale launcher-standard references."
    return 0
  fi
  cat >&2 <<REMEDY

Cure: name ${CANONICAL_FILE} at v${expect}.
The standard lives at launcher/launcher-standard_praxis.deed in
metadatastician/standards. Clause citations are s-expression heads --
write (runtime ...), not [runtime] or the old section-sign notation.
REMEDY
  return 1
}

main "$@"
