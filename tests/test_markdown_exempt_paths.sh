#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# test_markdown_exempt_paths.sh: config/settings/markdown-exempt-paths.json is
# valid (3-practice/DOC-FORMAT-POLICY.adoc D-1). Runs on the real ledger, then
# on planted bad copies that must fail, so it cannot pass by reading nothing.
# Exit: 0 pass; 1 a check failed; 2 NOT RUN (jq missing).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "test_markdown_exempt_paths: jq missing; NOT RUN" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# valid FILE: succeed when FILE is a conforming ledger, JCS-canonical.
valid() {
  local f=$1
  jq -e . "$f" >/dev/null 2>&1 || return 1
  [ "$(jq -cS . "$f")" = "$(head -n1 "$f")" ] && [ "$(wc -l <"$f")" -eq 1 ] || return 1
  jq -e '
    type == "array" and length > 0 and all(.[];
      type == "object"
      and (keys == ["class","paths","reason","repo","ruling"])
      and (.repo | type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))
      and (.class | type == "string" and length > 0)
      and (.reason | type == "string" and length > 0)
      and (.ruling | type == "string" and length > 0)
      and (.paths | type == "array" and length > 0 and all(.[];
            type == "string" and endswith(".md") and (startswith("/") | not)
            and (contains("..") | not) and (. != "**"))))
    and (map(.repo) | length == (unique | length))' "$f" >/dev/null 2>&1
}

fail=0
valid "$root/config/settings/markdown-exempt-paths.json" || { echo "FAIL: real ledger invalid" >&2; fail=1; }

# plant NAME JSON: a bad ledger that must be rejected.
reject() {
  printf '%s\n' "$2" >"$tmp/$1.json"
  if valid "$tmp/$1.json"; then echo "FAIL: $1 accepted" >&2; fail=1; fi
}
ok='{"class":"upstream-copy","paths":["a/**/index.md"],"reason":"r","repo":"o/n","ruling":"x"}'
printf '[%s]\n' "$ok" >"$tmp/good.json"
valid "$tmp/good.json" || { echo "FAIL: positive fixture rejected" >&2; fail=1; }
reject notjson 'nope'
reject pretty "[ $ok ]"
reject unsorted '[{"repo":"o/n","class":"upstream-copy","paths":["a.md"],"reason":"r","ruling":"x"}]'
for bad in '../a.md' '/a.md' '**' 'a.txt' 'a/../b.md'; do
  reject "path-${#bad}-${bad//[^a-z]/_}" "[{\"class\":\"c\",\"paths\":[\"$bad\"],\"reason\":\"r\",\"repo\":\"o/n\",\"ruling\":\"x\"}]"
done
reject badrepo '[{"class":"c","paths":["a.md"],"reason":"r","repo":"onlyname","ruling":"x"}]'
reject missing '[{"class":"c","paths":["a.md"],"repo":"o/n","ruling":"x"}]'
reject empty '[]'
[ "$fail" -eq 0 ] && echo "test_markdown_exempt_paths: ok"
exit "$fail"
