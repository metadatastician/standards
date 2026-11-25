#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# A3 law G7, "totality": every file in .github/workflows maps to exactly one
# observation, and a workflow that cannot start is `failed`, never silent.
#
#   check-workflow-totality.sh [--json] [--today YYYY-MM-DD] [--exemptions FILE]
#                              [--allow-empty] [ROOT ...]
#
# ROOT is a repository checkout (default: the current directory). Its workflow
# directory is ROOT/.github/workflows.
#
# WHY. GitHub rejects a workflow that does not parse, has a duplicate key, or
# has no `on`/`jobs`, and records NO jobs, NO log and NO check run. A required
# check that such a file would have produced is then simply absent, and absence
# must not read as success (A3 law G3). The existing gate only sees a context
# that exists. This check makes the dead file itself an observation.
#
# OBSERVATIONS, one TSV row per file, fixed order (first column is the state):
#   passed     parses, no duplicate key, has `on` and `jobs`, actionlint clean
#   failed     one or more of the checks below failed (detail names them)
#   not_run    a check could not be performed (actionlint missing)
#   exempt     covered by a typed, dated exemption that has not expired
#   inert      not a workflow file (README, .gitkeep, *.disabled): reported only
#
# CHECKS per workflow file, each named in the detail column:
#   unreachable   a .yml/.yaml in a SUBDIRECTORY of .github/workflows. GitHub
#                 reads only the top level, so the file never runs.
#   parse         yq cannot parse it, or it is empty, or the root is not a mapping.
#   dupkey        duplicate key (delegates to check-workflow-duplicate-keys.sh;
#                 ordinary parsers keep the LAST duplicate and say "fine").
#   shape         no `on`, or no non-empty `jobs`.
#   lint          actionlint (offline rules only; shellcheck and pyflakes are
#                 off so the verdict does not depend on which helpers exist).
#                 A repo may tune runner labels in .github/actionlint.yaml.
#
# EXEMPTIONS: ROOT/.github/workflow-totality-exemptions.tsv, tab separated,
#   file <TAB> kind <TAB> reason <TAB> expires(YYYY-MM-DD)
# kind is one of: wip, generated, upstream. An exemption lapses on its expiry
# date and may not run more than 90 days past --today (so none is permanent).
# A lapsed or over-long exemption is a `failed` row, not a silent skip.
#
# EXIT: 0 every file passed/exempt/inert; 1 any failed (also when some not_run);
#       2 nothing failed but a check could not be performed; 64 usage error.
# This matches the exit-code meaning in A3 section 7 (1 = failed, 2 = not_run).
#
# An empty or missing workflow directory is a failure unless --allow-empty:
# "no workflows" is the purest absence, and every repo has a baseline required set.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUPKEY="$HERE/check-workflow-duplicate-keys.sh"

json=0 allow_empty=0 today="" exfile=""
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --allow-empty) allow_empty=1; shift ;;
    --today) today="${2:?--today needs a date}"; shift 2 ;;
    --exemptions) exfile="${2:?--exemptions needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 64 ;;
    *) roots+=("$1"); shift ;;
  esac
done
[ ${#roots[@]} -eq 0 ] && roots=(.)
[ -z "$today" ] && today="$(date -u +%Y-%m-%d)"
date -u -d "$today" +%Y-%m-%d >/dev/null 2>&1 || { echo "bad --today: $today" >&2; exit 64; }

# mikefarah yq v4 is the estate flavour (check-workflow-duplicate-keys.sh uses `yq -P`);
# another yq parses differently, so refuse rather than guess.
if ! yq --version 2>/dev/null | grep -q mikefarah; then
  printf "not_run\t-\t-\tmikefarah yq v4 is required and missing\n"; exit 2
fi
AL="${ACTIONLINT:-$(command -v actionlint || true)}"
[ -n "$AL" ] && [ -x "$(command -v "$AL" 2>/dev/null)" ] || AL=""   # unusable path counts as absent

rows="$(mktemp)"; trap 'rm -f "$rows"' EXIT
n_failed=0 n_notrun=0 n_files=0

emit() { # state root file detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$rows"
  case "$1" in failed) n_failed=$((n_failed+1));; not_run) n_notrun=$((n_notrun+1));; esac
}

epoch() { date -u -d "$1" +%s 2>/dev/null; }

for root in "${roots[@]}"; do
  dir="$root/.github/workflows"
  if [ ! -d "$dir" ]; then
    [ "$allow_empty" -eq 1 ] || emit failed "$root" "-" "empty: no .github/workflows directory (absence)"
    continue
  fi
  ex="${exfile:-$root/.github/workflow-totality-exemptions.tsv}"

  # --- enumerate every file, top level and below: totality means we look at all
  mapfile -t all < <(cd "$dir" && find . -type f ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort)
  workflow_count=0
  for rel in "${all[@]}"; do
    n_files=$((n_files+1))
    f="$dir/$rel"
    case "$rel" in
      */*)
        case "$rel" in
          *.yml|*.yaml) emit failed "$root" "$rel" "unreachable: workflow in a subdirectory is never run by GitHub" ;;
          *) emit inert "$root" "$rel" "not a workflow file" ;;
        esac
        continue ;;
      *.yml|*.yaml) workflow_count=$((workflow_count+1)) ;;
      *) emit inert "$root" "$rel" "not a workflow file"; continue ;;
    esac

    # --- exemption lookup (typed, dated, bounded)
    if [ -f "$ex" ]; then
      line="$(awk -F'\t' -v f="$rel" '$1==f {print; exit}' "$ex")"
      if [ -n "$line" ]; then
        IFS=$'\t' read -r _ kind reason expires <<<"$line"
        case "$kind" in wip|generated|upstream) kindok=1 ;; *) kindok=0 ;; esac
        if [ "$kindok" -ne 1 ] || [ -z "${reason:-}" ] || ! date -u -d "${expires:-x}" +%Y-%m-%d >/dev/null 2>&1; then
          emit failed "$root" "$rel" "exemption malformed (need file, kind in wip|generated|upstream, reason, expires)"
          continue
        fi
        if [ "$(epoch "$expires")" -lt "$(epoch "$today")" ]; then
          emit failed "$root" "$rel" "exemption lapsed on $expires (kind $kind)"; continue
        fi
        if [ "$(epoch "$expires")" -gt $(( $(epoch "$today") + 90*86400 )) ]; then
          emit failed "$root" "$rel" "exemption runs past 90 days ($expires); none is permanent"; continue
        fi
        emit exempt "$root" "$rel" "$kind until $expires: $reason"
        continue
      fi
    fi

    # --- checks, all run so one report names every defect in the file
    problems=()
    if [ ! -s "$f" ]; then
      problems+=("parse: empty file")
    elif ! perr="$(yq -e '.' "$f" 2>&1 >/dev/null)"; then
      problems+=("parse: $(sed "s#bad file .[^ ]*/\.github/workflows/#bad file #" <<<"${perr//$'\n'/ }")")
    elif [ "$(yq -r 'type' "$f" 2>/dev/null)" != '!!map' ]; then
      problems+=("parse: root is not a mapping")
    else
      derr="$(bash "$DUPKEY" "$f" 2>&1)" || problems+=("dupkey: $(grep -m1 '^FAIL' <<<"$derr" | sed 's/^FAIL [^:]*: //')")
      [ "$(yq -r 'has("on")' "$f" 2>/dev/null)" = true ] || problems+=("shape: no 'on' trigger")
      [ "$(yq -r '(.jobs | type) == "!!map" and (.jobs | length) > 0' "$f" 2>/dev/null)" = true ] || problems+=("shape: no non-empty 'jobs'")
    fi

    lint_state=skipped
    if true; then  # always lint: one report names every defect
      if [ -z "$AL" ]; then
        lint_state=not_run
      else
        lint_state=ran
        # run from ROOT so local reusable `uses: ./.github/workflows/x.yml` resolves
        if lerr="$(cd "$root" && "$AL" -no-color -oneline -shellcheck= -pyflakes= ".github/workflows/$rel" 2>&1)"; then :; else
          rc=$?
          [ "$rc" -eq 1 ] && problems+=("lint: $(head -n3 <<<"$lerr" | tr '\n' ' ' | cut -c1-300)") \
                          || problems+=("lint: actionlint exited $rc: $(head -c 200 <<<"$lerr")")
        fi
      fi
    fi

    if [ ${#problems[@]} -gt 0 ]; then
      emit failed "$root" "$rel" "$(IFS=' | '; echo "${problems[*]}")"
    elif [ "$lint_state" = not_run ]; then
      emit not_run "$root" "$rel" "lint: actionlint not installed; structure checks passed"
    else
      emit passed "$root" "$rel" "ok"
    fi
  done
  if [ "$workflow_count" -eq 0 ] && [ "$allow_empty" -ne 1 ]; then
    emit failed "$root" "-" "empty: no workflow files (absence)"
  fi
done

if [ "$json" -eq 1 ]; then
  jq -R -s -c 'split("\n")[:-1] | map(split("\t") | {state:.[0], root:.[1], file:.[2], detail:.[3]})' "$rows"
else
  printf 'state\troot\tfile\tdetail\n'; cat "$rows"
fi
echo "totality: $n_files file(s); failed=$n_failed not_run=$n_notrun" >&2

[ "$n_failed" -gt 0 ] && exit 1
[ "$n_notrun" -gt 0 ] && exit 2
exit 0
