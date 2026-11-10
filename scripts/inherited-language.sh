#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# inherited-language.sh, the inherited-language paths of a real fork.
#
# WHAT THIS IS FOR
#
#   A repository that is a real fork of someone else's project receives files
#   in a language the estate bans (TypeScript, ReScript, JavaScript). The
#   scanner reports each one as `cicd_rules/banned_language_file`, correctly.
#   The fork cannot port a file its upstream still owns, so the finding can
#   never be worked off. It is not debt: a baseline entry would need a new
#   expiry date every year for a fact that does not change.
#
#   The caller declares those files, one exact path per line. This script
#   takes that ONE rule off those EXACT paths in the gating projections. The
#   verdict grid still reports the findings as excluded (reported, never
#   graded). Every other rule on the same file still gates and grades, and a
#   banned file the fork adds itself is not on the list.
#
# WHAT IT REFUSES
#
#   Python, Go, Makefile and Gemfile are banned without exception in the
#   scanner itself (Hypatia.ScannerSuppression). A list cannot bring one back:
#   only .ts, .tsx, .js, .jsx, .mjs, .cjs, .res and .resi paths are accepted.
#   Absolute paths, `..` and `.` segments, and backslashes are refused, and
#   an empty list is refused. `paths` FAILS CLOSED: a list that was asked for
#   and is unusable is a configuration error, never "nothing to excuse".
#
#   The two filters FAIL OPEN, like filter-sarif-by-scope.sh: on any error the
#   input is copied through unchanged, because more visible findings are
#   safer than silent suppression.
#
# USAGE
#   inherited-language.sh paths FILE              normalised list on stdout
#   inherited-language.sh sarif IN OUT LIST       drop the rule on listed paths
#   inherited-language.sh findings IN OUT LIST    the same, for findings JSON
#
#   LIST is the output of `paths`. A SARIF result is dropped only when it has
#   at least one location and EVERY location is a listed path.
#
# EXIT CODES
#   0  done, or (filters only) copied through unchanged with a warning
#   2  usage error, or (paths) an unusable list
set -uo pipefail

RULE_MODULE=cicd_rules
RULE_TYPE=banned_language_file

usage() {
  echo "usage: inherited-language.sh paths FILE | sarif IN OUT LIST | findings IN OUT LIST" >&2
  exit 2
}

cmd="${1:-}"
case "$cmd" in
  paths)
    file="${2:-}"
    [ -n "$file" ] || usage
    [ -f "$file" ] || { echo "inherited-language: path list not found: $file" >&2; exit 2; }
    # `#` comments and blank lines keep the tracked list self-documenting.
    list=$(jq -R -s -r '
      [ split("\n")[] | sub("\r$"; "") | sub("^\\s+"; "") | sub("\\s+$"; "")
        | select(length > 0 and (startswith("#") | not)) | sub("^\\./+"; "") ] as $paths
      | [ $paths[] | select(
            startswith("/") or contains("\\") or test("(^|/)\\.\\.?(/|$)")
            or (test("\\.(ts|tsx|js|jsx|mjs|cjs|res|resi)$") | not)) ] as $bad
      | if ($paths | length) == 0 then error("the list is empty")
        elif ($bad | length) > 0 then error("not an inherited-language path: " + ($bad | join(", ")))
        else ($paths | unique | .[]) end' "$file" 2>&1) || {
      echo "inherited-language: $file: ${list#jq: error (at *): }" >&2
      exit 2
    }
    printf '%s\n' "$list"
    ;;
  sarif|findings)
    in="${2:-}"; out="${3:-}"; list="${4:-}"
    [ -n "$in" ] && [ -n "$out" ] && [ -n "$list" ] || usage
    [ -f "$list" ] || { echo "inherited-language: normalised list not found: $list" >&2; exit 2; }
    copy_through() { [ "$out" = "$in" ] || cp "$in" "$out"; }
    if [ ! -s "$in" ]; then
      echo "  no input at $in, nothing to filter"
      [ "$out" != "$in" ] && : > "$out"
      exit 0
    fi
    listed=$(jq -R -s 'split("\n") | map(select(length > 0))' "$list" 2>/dev/null) || {
      echo "  ::warning::inherited-language list unreadable, $cmd copied unfiltered"; copy_through; exit 0; }
    if [ "$cmd" = sarif ]; then
      count='[.runs[]?.results[]?] | length'
      # shellcheck disable=SC2016
      filter='
        def norm: (. // "") | sub("^\\./+"; "") | sub("^/"; "");
        def inherited:
          ((.ruleId // "") | sub("^hypatia/"; "")) == ($module + "/" + $type)
          and ([ .locations[]?.physicalLocation.artifactLocation.uri | norm ] as $uris
               | ($uris | length) > 0 and all($uris[]; . as $u | $listed | index($u) != null));
        .runs = ((.runs // []) | map(.results = ((.results // []) | map(select(inherited | not)))))'
      shape='type == "object" and (.runs | type) == "array"'
    else
      count='length'
      # shellcheck disable=SC2016
      filter='
        def norm: if type == "string" then gsub("\\\\"; "/") | sub("^\\./+"; "") else "" end;
        map(select((.rule_module == $module and .type == $type
                    and ((.file | norm) as $p | $listed | index($p) != null)) | not))'
      shape='type == "array"'
    fi
    before=$(jq "$count" "$in" 2>/dev/null) || before="?"
    if ! jq --argjson listed "$listed" --arg module "$RULE_MODULE" --arg type "$RULE_TYPE" \
          "$filter" "$in" > "$out.tmp" 2>/dev/null || ! jq -e "$shape" "$out.tmp" >/dev/null 2>&1; then
      echo "  ::warning::inherited-language $cmd filter failed, copied UNFILTERED rather than a partial file"
      rm -f "$out.tmp"
      copy_through
      exit 0
    fi
    mv "$out.tmp" "$out"
    echo "  $cmd entries: $before -> $(jq "$count" "$out" 2>/dev/null || echo '?')  ($RULE_MODULE/$RULE_TYPE on $(jq 'length' <<<"$listed") inherited-language path(s))"
    ;;
  *) usage ;;
esac
