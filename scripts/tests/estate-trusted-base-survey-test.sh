#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# Regression tests for caller status, query coverage and locale-stable joins.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../estate-trusted-base-survey.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if [ "$2" = user ]; then echo mock; exit 0; fi
case "$2" in
  users/*/repos*) printf '[{"full_name":"alpha/one","archived":false,"fork":false},{"full_name":"alpha/two","archived":false,"fork":false}]\n'; exit 0 ;;
esac
query=""
for arg in "$@"; do case "$arg" in q=*) query=${arg#q=} ;; esac; done
printf '%s\n' "$query" >> "$QUERY_LOG"
case "$query" in
  governance-reusable.yml*)
    if [[ "$query" == *user:alpha* ]] && [ "${CALLER_CASE:-}" = truncated ]; then total=3; else total=2; fi
    if [[ "$query" == *user:beta* ]] && [ "${CALLER_CASE:-}" = failure ]; then exit 1; fi
    printf '{"total_count":%s,"items":[{"repository":{"full_name":"alpha/one"},"path":"one"},{"repository":{"full_name":"alpha/two"},"path":"two"}]}\n' "$total"
    ;;
  *) printf '{"total_count":0,"items":[]}\n' ;;
esac
MOCK
for command in sort comm; do
  cat > "$tmp/bin/$command" <<'MOCK'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" != C ]; then printf '%s missing LC_ALL=C\n' "$0" >> "$LOCALE_LOG"; fi
exec "/usr/bin/${0##*/}" "$@"
MOCK
done
chmod +x "$tmp/bin/gh" "$tmp/bin/sort" "$tmp/bin/comm"
export PATH="$tmp/bin:$PATH" QUERY_LOG="$tmp/queries" LOCALE_LOG="$tmp/locale-errors"
export LC_ALL=C.utf8
# Keep shell startup hooks from replacing the test doubles; refuse to run if
# the survey could resolve a real GitHub CLI.
if [ "$(env -u BASH_ENV bash -c 'command -v gh')" != "$tmp/bin/gh" ]; then
  echo "FAIL mock gh is not selected" >&2
  exit 1
fi
fail=0
run_survey() {
  local label=$1 expected=$2 status=$3; shift 3
  : > "$QUERY_LOG"
  : > "$LOCALE_LOG"
  local out rc
  out=$(env -u BASH_ENV bash "$SCRIPT" --owner alpha --owner beta --markers all --sleep 0 --out "$tmp/$label" "$@" 2>&1); rc=$?
  if [ "$rc" -ne "$expected" ] || [[ "$out" != *"enumeration: $status"* ]] || [ -s "$LOCALE_LOG" ]; then
    echo "FAIL $label (exit=$rc)"; printf '%s\n' "$out"; cat "$LOCALE_LOG"; fail=1
  else
    echo "ok   $label"
  fi
}
printf 'alpha/one\nalpha/two\n' > "$tmp/callers"
CALLER_CASE=complete run_survey callers_file 0 complete --callers-file "$tmp/callers"
for spelling in termination positivity coverage projection-likeness universe; do
  if ! rg -q -- "--no-$spelling-check user:" "$QUERY_LOG"; then
    echo "FAIL missing $spelling query"; fail=1
  fi
done
CALLER_CASE=truncated run_survey truncated_first_owner 0 truncated
CALLER_CASE=failure run_survey failed_owner 2 error
[ "$fail" -eq 0 ]
