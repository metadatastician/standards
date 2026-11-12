#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Check UUID literals in files against ESTATE-UUID-V8 (ADR-008).
# Runtime generators still require type-aware tests.
#
# Usage: check-uuid-v8.sh [--strict] [PATH...]
#
# Default (ADR-008 phase P2, dual-accept): version 8 and version 7 literals
# are both accepted, because v7 maps to v8 profile T by one reversible nibble
# flip and the estate is mid-migration. --strict accepts version 8 only; it is
# for repositories that have finished migrating, and becomes the default at P4.
# Either way the variant must be RFC 9562 `10` (nibble 8, 9, a or b).
#
# A literal scanner cannot tell profile T from profile C; ADR-008 puts the
# profile in the field's declared type, which this script does not read.
#
# Retired A2ML files (*.a2ml, *.a2ml.in) are not scanned (owner ruling D320,
# 2026-10-07). A2ML is dead and may not be hand-converted (D313); its
# identifiers become v8 when kyX converts each file into deed, so checking
# them here would only force edits to a format the estate is deleting.
#
# The deed linter's negative fixtures (1-formats/deed/tools/fixtures/invalid/)
# hold malformed UUIDs on purpose: a v4 id or a bad variant is what each one
# tests the linter rejects. They are not scanned. Valid fixtures still are.
set -eu

strict=0
if [ "${1:-}" = "--strict" ]; then
  strict=1
  shift
fi
if [ "$#" -eq 0 ]; then
  set -- .
fi
# A mistyped path must not turn into an empty, passing scan.
for path in "$@"; do
  if [ ! -e "$path" ]; then
    printf '%s: scan path does not exist\n' "$path" >&2
    exit 2
  fi
done

# Print the text of a file that is subject to the UUID rule.
#
# Julia project files name each dependency by the UUID the General registry
# assigned it. Those are external identifiers (the standard: preserve and type
# explicitly), so the [deps], [weakdeps] and [extras] tables of a
# Project.toml / JuliaProject.toml are not scanned, and neither is a Manifest
# (every entry is a resolved dependency). Everything else in a project file,
# including the package's own top-level `uuid =`, is still checked.
#
# A mint template `<name>.in` becomes `<name>` when a repository is minted from
# it, so it is scanned under <name>'s rules. rsr-template-repo's julia-library
# archetype ships Project.toml.in; scanned as an unknown file, its [extras]
# registry UUIDs failed the strict gate in the template itself (2026-10-14).
scannable_text() {
  base=${1##*/}
  case "$base" in
    *.in) base=${base%.in} ;;
  esac
  case "$base" in
    Manifest.toml|Manifest-v*.toml|JuliaManifest.toml|JuliaManifest-v*.toml) ;;
    Project.toml|JuliaProject.toml)
      awk '/^[[:space:]]*\[/ { t = $0; gsub(/[[:space:]]/, "", t); sub(/#.*/, "", t)
             skip = (t == "[deps]" || t == "[weakdeps]" || t == "[extras]") }
           !skip' "$1" ;;
    *) cat "$1" ;;
  esac
}

# Exit 0 when a version:variant pair is acceptable in the current mode.
# Keep this POSIX so it can run in every estate checkout.
acceptable() {
  case "$1" in
    8:8|8:9|8:a|8:b) return 0 ;;
    7:8|7:9|7:a|7:b) [ "$strict" -eq 0 ] ;;
    *) return 1 ;;
  esac
}

status=0
while IFS= read -r file; do
  [ -f "$file" ] || continue
  # Ignore the checkers themselves and retired A2ML files (D320); scan source
  # and data files, not binaries.
  case "$file" in
    */.git/*|*/check-uuid-v7.sh|*/check-uuid-v8.sh|*.a2ml|*.a2ml.in) continue ;;
    1-formats/deed/tools/fixtures/invalid/*|*/1-formats/deed/tools/fixtures/invalid/*) continue ;;
  esac
  if grep -IEni -- '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$file" >/dev/null 2>&1; then
    # Every UUID on a line is checked, not only the last one (grep -o).
    while IFS= read -r uuid; do
      [ -n "$uuid" ] || continue
      version=$(printf '%s' "$uuid" | cut -d- -f3 | cut -c1)
      variant=$(printf '%s' "$uuid" | cut -d- -f4 | cut -c1 | tr 'A-F' 'a-f')
      if ! acceptable "$version:$variant"; then
        if [ "$strict" -eq 1 ]; then
          printf '%s: non-v8 UUID literal (%s)\n' "$file" "$uuid" >&2
        else
          printf '%s: non-v8/v7 UUID literal (%s)\n' "$file" "$uuid" >&2
        fi
        status=1
      fi
    done <<EOF
$(scannable_text "$file" | grep -oEi -- '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)
EOF
  fi
done <<EOF
$(find "$@" -type f -not -path '*/.git/*' -print 2>/dev/null)
EOF

if [ "$status" -ne 0 ]; then
  printf '%s\n' 'UUID check failed. Use ESTATE-UUID-V8 (docs/decisions/ADR-008-uuid-v8-estate-standard.adoc) and type external/legacy IDs explicitly.' >&2
fi
exit "$status"
