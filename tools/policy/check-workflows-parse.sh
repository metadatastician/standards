#!/usr/bin/env bash
# Fail if any tracked GitHub Actions workflow does not parse as YAML.
set -uo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo '::error::git is required to enumerate tracked workflows'
  exit 1
fi

declare -a workflows=()
mapfile -d '' -t workflows < <(
  git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    '**/.github/workflows/*.yml' '**/.github/workflows/*.yaml'
)

if [ "${#workflows[@]}" -eq 0 ]; then
  echo "no workflows tracked - nothing to check"
  exit 0
fi

parser=''
if command -v yq >/dev/null 2>&1; then
  parser=yq
else
  echo "::error::no YAML parser available (yq)" >&2
  exit 1
fi

parse_ok() {
  case "$parser" in
    yq) yq '.' "$1" >/dev/null 2>&1 ;;
  esac
}

# GitHub rejects a reusable-workflow call job before creating any jobs when it
# contains step-job-only keys such as timeout-minutes. The file remains valid
# YAML, so the parser gate alone cannot see this zero-check failure mode.
has_reusable_timeout() {
  case "$parser" in
    yq)
      yq -e '[.jobs[] | select(has("uses") and has("timeout-minutes"))] | length > 0' "$1" >/dev/null 2>&1
      ;;
  esac
}

# A syntactically valid file with no jobs is still rejected at startup.
has_no_jobs() {
  local file="$1" result
  case "$parser" in
    yq) yq -e '(.jobs | tag) != "!!map" or (.jobs | length == 0)' "$file" >/dev/null 2>&1; result=$? ;;
    *) echo "::error::unsupported workflow parser: $parser" >&2; return 0 ;;
  esac
  return "$result"
}

has_forbidden_control() {
  od -An -v -tu1 "$1" | awk '
    { for (i=1; i<=NF; i++) if (($i < 9) || ($i > 10 && $i < 13) || ($i > 13 && $i < 32)) found=1 }
    END { exit !found }
  '
}

status=0
for file in "${workflows[@]}"; do
  [ -f "$file" ] || continue
  if ! parse_ok "$file"; then
    status=1
    printf '::error file=%s::workflow does not parse; an unloaded workflow produces no check run\n' "$file"
    if has_forbidden_control "$file"; then
      echo '    contains a YAML-forbidden control character'
    fi
  elif has_no_jobs "$file"; then
    status=1
    printf '::error file=%s::workflow has no executable jobs; commented templates do not create checks\n' "$file"
  elif has_reusable_timeout "$file"; then
    status=1
    printf '%s\n' "::error file=$file::a reusable-workflow call job cannot declare timeout-minutes; GitHub rejects it before creating any jobs"
  fi
done

if [ "$status" -eq 0 ]; then
  echo "all ${#workflows[@]} workflow(s) parse"
else
  echo 'At least one workflow cannot load. Fix the YAML; do not delete the check.'
fi
exit "$status"
