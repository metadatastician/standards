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
# An identifier written as a deed opaque literal, #uuid"<id>" (deed.abnf
# v1.3.0, owner ruling U4, 2026-11-12), is explicitly typed: it carries an id
# minted elsewhere: for a repository, ruling V8 makes it the profile C UUIDv8
# of its birth path. Inside that literal, version 5 or 8 with variant 10 is accepted in
# both modes, exactly as deed.abnf's uuid-hex allows; the body must be lower
# case, as the grammar requires. In an identity field (CHORA-SPEC 7.1: the
# deed's own id :repo-uuid, :estate-uuid, :forge-uuid and the clause field
# :uuid, and the references :beholding-chora, :of-chora and the clause fields
# :estate, :base, :forge and :repo) only version 8 is accepted, in both modes
# (owner ruling, 2026-11-13; A1 V8, T30). A #u5"…" literal in an identity field
# is rejected in both modes, and a #u8"…" literal there is accepted: it is
# computed to a v8 (owner ruling Q2, 2026-11-14; A1 T30). A version 5 stays
# legal in #uuid outside identity, as the registry alias. Every other version
# is still rejected there,
# and a bare v5 anywhere else is still rejected. Anything that looks like the
# literal but is not exactly it (an upper- or mixed-case body, or space before
# the string) is rejected as malformed in both modes; it never falls through
# to the bare-UUID policy, where a v7 would pass in dual-accept mode.
#
# Per-repository exemptions: a scan root may hold a file named .uuid-v8-exempt
# listing paths, relative to that root, one per line (blank lines and lines
# starting with # are ignored). A listed file is not scanned. Entries are exact
# paths: a glob character is a usage error, so an exemption names each file
# and is reviewed in the repository that adds it. The script itself exempts
# nothing by path, so no caller of the reusable gate inherits another
# repository's exemptions.
#
# Retired A2ML files (*.a2ml, *.a2ml.in) are not scanned (owner ruling D320,
# 2026-10-07). A2ML is dead and may not be hand-converted (D313); its
# identifiers become v8 when kyX converts each file into deed, so checking
# them here would only force edits to a format the estate is deleting.
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

# Collect the exempt files of every scan root, as the paths find will print.
EXEMPT=''
for root in "$@"; do
  # find prints <root>/<path>, with <root> as given, minus a trailing slash.
  root=${root%/}
  list="$root/.uuid-v8-exempt"
  [ -f "$list" ] || continue
  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
      ''|'#'*) continue ;;
      *'*'*|*'?'*|*'['*)
        printf '%s: exemption %s is not an exact path (no globs)\n' "$list" "$entry" >&2
        exit 2 ;;
    esac
    entry=${entry#./}
    EXEMPT="$EXEMPT
$root/$entry"
  done < "$list"
done

# Exit 0 when a file is listed in a scan root's .uuid-v8-exempt.
exempt() {
  [ -n "$EXEMPT" ] && printf '%s\n' "$EXEMPT" | grep -qxF -- "$1"
}

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

# Print two one-line views of a file's scannable text, for the identity
# rules: the text with line breaks folded to spaces (so a field and its value
# on separate lines meet), and the same with ';' comments removed first (so a
# comment used as the separator between them cannot hide the value). A ';'
# inside a double-quoted string is not a comment, so strings are tracked,
# across lines, with backslash escapes. The raw
# view keeps comments, so a comment that quotes a field and a #u5 is still
# flagged (owner ruling of 2026-11-14: the rule is lexical). The views read
# the whole file, not scannable_text: the Julia dependency tables and
# manifests that the UUID scan skips hold registry ids, not identity fields,
# and a field written there is still an error.
folded_views() {
  tr '\n\r' '  ' < "$1"
  printf '\n'
  awk '
    { out = ""; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q) { out = out c
                 if (c == "\\") { i++; out = out substr($0, i, 1) }
                 else if (c == "\"") q = 0 }
        else if (c == "\"") { q = 1; out = out c }
        else if (c == ";") break
        else out = out c
      }
      print out }' "$1" | tr '\n\r' '  '
  printf '\n'
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

# The 8-4-4-4-12 shape, and the same shape inside a deed opaque literal.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
TYPED_RE='#uuid"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
# Anything that looks like the literal: any case in the body, optional space.
APPARENT_RE='#uuid[[:space:]]*"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"'
# A #uuid literal written as the value of an identity field (CHORA-SPEC 7.1).
IDENT_RE='(:repo-uuid|:estate-uuid|:forge-uuid|:beholding-chora|:of-chora|:uuid|:estate|:base|:forge|:repo)[[:space:]]+#uuid"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
# A #u5"…" literal written as the value of an identity field (owner ruling Q2,
# 2026-11-14). It is checked in every file, not only those holding a bare UUID.
U5_IDENT_RE='(:repo-uuid|:estate-uuid|:forge-uuid|:beholding-chora|:of-chora|:uuid|:estate|:base|:forge|:repo)[[:space:]]+#u5"[^"]*"'

# Exit 0 when a version:variant pair is legal inside #uuid"…" (deed.abnf
# uuid-hex: version 5 or 8, variant 10). The mode does not change this.
typed_acceptable() {
  case "$1" in
    5:8|5:9|5:a|5:b|8:8|8:9|8:a|8:b) return 0 ;;
    *) return 1 ;;
  esac
}

# External UUID pragma (owner ruling CASE-067, 2026-11-14). An external,
# non-estate UUID constant (a protocol GUID such as RFC 6455's, a test vector,
# a vendor id) is marked on its own line, in any comment syntax:
#
#   <code with the UUID>   <comment> hypatia: allow uuid/external -- <reason>
#
# or, where the format cannot carry a comment on the same line, on the line
# before it:
#
#   <comment> hypatia: allow-next-line uuid/external -- <reason>
#
# The mark exempts the bare-UUID rule on exactly that one line. It never
# exempts an identity field (CHORA-SPEC 7.1), a #u5 identity value or a
# malformed #uuid literal. The reason is required. A mark whose line carries
# no UUID the gate would refuse is stale and fails, so marks cannot pile up
# unseen. Formats with no comment syntax at all (JSON) keep the per-file
# .uuid-v8-exempt. Hypatia refers a missing or stale mark; nothing autofixes
# one. A mark whose reason is the literal placeholder "<reason>" is a
# documentation example and is ignored.
PRAGMA_KEY='uuid/external'

# Read scannable text on stdin; print "U <uuid>" for every UUID on a line the
# pragma does not cover, and "E <line>: <message>" for a malformed or stale
# pragma. POSIX awk only (no interval expressions), so it runs under mawk.
pragma_scan() {
  awk -v strict="$strict" '
    function refused(u,   v, r) {
      v = substr(u, 15, 1); r = tolower(substr(u, 20, 1))
      if (r !~ /^[89ab]$/) return 1
      if (v == "8") return 0
      if (v == "7" && strict == 0) return 0
      return 1
    }
    # Collect the UUIDs on line s into arr; return how many.
    function uuids(s, arr,   n) {
      n = 0
      while (match(s, H8 "-" H4 "-" H4 "-" H4 "-" H12)) {
        arr[++n] = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
      return n
    }
    function any_refused(s,   a, n, i) {
      n = uuids(s, a)
      for (i = 1; i <= n; i++) if (refused(a[i])) return 1
      return 0
    }
    # Classify the pragma on line s: "" none, "doc", "bad", "same", "next".
    function kind(s,   k, rest) {
      if (index(s, "uuid/external") == 0) return ""
      if (s ~ /hypatia:[ \t]*allow-next-line[ \t]+uuid\/external/) k = "next"
      else if (s ~ /hypatia:[ \t]*allow[ \t]+uuid\/external/) k = "same"
      else return ""
      rest = s; sub(/.*uuid\/external/, "", rest)
      if (rest ~ /^[ \t]*--[ \t]*<reason>/) return "doc"
      if (rest !~ /^[ \t]*--[ \t]*[^ \t]/) return "bad"
      return k
    }
    BEGIN {
      h = "[0-9A-Fa-f]"; H4 = h h h h; H8 = H4 H4; H12 = H8 H4
      pend = 0
    }
    {
      k = kind($0)
      covered = 0
      if (pend) {
        covered = 1
        if (!any_refused($0))
          print "E " pend ": stale uuid/external pragma (the next line has no UUID the gate refuses)"
        pend = 0
      }
      if (k == "bad") {
        print "E " NR ": malformed uuid/external pragma; write \"hypatia: allow uuid/external -- <reason>\" with a reason"
      } else if (k == "same") {
        covered = 1
        if (!any_refused($0))
          print "E " NR ": stale uuid/external pragma (this line has no UUID the gate refuses)"
      } else if (k == "next") {
        pend = NR
      }
      if (!covered) {
        n = uuids($0, a)
        for (i = 1; i <= n; i++) print "U " a[i]
      }
    }
    END {
      if (pend) print "E " pend ": stale uuid/external pragma (no line follows it)"
    }'
}

status=0
while IFS= read -r file; do
  [ -f "$file" ] || continue
  # Ignore the checkers themselves and retired A2ML files (D320); scan source
  # and data files, not binaries.
  case "$file" in
    */.git/*|*/check-uuid-v7.sh|*/check-uuid-v8.sh|*.a2ml|*.a2ml.in) continue ;;
  esac
  if exempt "$file"; then continue; fi
  # A #u5"…" in an identity field is an error in both modes (owner ruling Q2,
  # 2026-11-14). #u8"…" there is accepted: it computes to a v8. Binary files
  # are skipped, as for every other rule here. Line breaks are folded to
  # spaces first, because a deed may put a field and its value on separate
  # lines. The rule is lexical, like IDENT_RE: a field followed by #u5 fails
  # wherever it appears, prose and comments included. A file without "#u5"
  # cannot match, so it is skipped before the views are built.
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    key=${pair%%[[:space:]]*}
    printf '%s: identity field %s carries a #u5 literal; write #uuid"<v8 id>" (%s)\n' "$file" "$key" "$pair" >&2
    status=1
  done <<EOF
$(grep -Iq -- '#u5"' "$file" 2>/dev/null && folded_views "$file" | grep -oE -- "$U5_IDENT_RE" | sort -u || true)
EOF
  if grep -IEni -- "$UUID_RE" "$file" >/dev/null 2>&1; then
    # Typed literals first: each #uuid"<id>" must be exactly the literal, and
    # version 5 or 8.
    while IFS= read -r lit; do
      [ -n "$lit" ] || continue
      if ! printf '%s\n' "$lit" | grep -qxE -- "$TYPED_RE"; then
        printf '%s: malformed #uuid literal, must be #uuid"<lower-case id>" (%s)\n' "$file" "$lit" >&2
        status=1
        continue
      fi
      uuid=${lit#'#uuid"'}; uuid=${uuid%'"'}
      version=$(printf '%s' "$uuid" | cut -d- -f3 | cut -c1)
      variant=$(printf '%s' "$uuid" | cut -d- -f4 | cut -c1)
      if ! typed_acceptable "$version:$variant"; then
        printf '%s: #uuid literal is not v5 or v8 with variant 10 (%s)\n' "$file" "$uuid" >&2
        status=1
      fi
    done <<EOF
$(scannable_text "$file" | grep -oE -- "$APPARENT_RE" || true)
EOF
    # An identity field carries version 8 only (owner ruling 2026-11-13).
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      key=${pair%%[[:space:]]*}
      uuid=${pair#*#uuid\"}; uuid=${uuid%\"}
      version=$(printf '%s' "$uuid" | cut -d- -f3 | cut -c1)
      if [ "$version" != 8 ]; then
        printf '%s: identity field %s must carry a v8 id, found v%s (%s)\n' "$file" "$key" "$version" "$uuid" >&2
        status=1
      fi
    done <<EOF
$(grep -q -- '#uuid"' "$file" 2>/dev/null && folded_views "$file" | grep -oE -- "$IDENT_RE" | sort -u || true)
EOF
  fi
  # Then every other UUID, with the typed literals removed. Every UUID on a
  # line is checked, not only the last one. A line marked with the external
  # pragma is not checked for bare UUIDs (owner ruling CASE-067, 2026-11-14);
  # the identity rules above never honour it. pragma_scan prints "U <uuid>"
  # for each bare UUID on an unmarked line and "E <message>" for each
  # malformed or stale pragma. A file with no UUID and no pragma is skipped.
  if grep -IEqi -- "$UUID_RE" "$file" 2>/dev/null || grep -Iq -- "$PRAGMA_KEY" "$file" 2>/dev/null; then
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      case "$rec" in
        E\ *)
          printf '%s:%s\n' "$file" "${rec#E }" >&2
          status=1
          continue ;;
      esac
      uuid=${rec#U }
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
$(scannable_text "$file" | sed -E "s/$APPARENT_RE//g" | pragma_scan)
EOF
  fi
done <<EOF
$(find "$@" -type f -not -path '*/.git/*' -print 2>/dev/null)
EOF

if [ "$status" -ne 0 ]; then
  printf '%s\n' 'UUID check failed. Use ESTATE-UUID-V8 (docs/decisions/ADR-008-uuid-v8-estate-standard.adoc) and type external/legacy IDs explicitly: an external constant takes "hypatia: allow uuid/external -- <reason>" on its line (ADR-008, CASE-067).' >&2
fi
exit "$status"
