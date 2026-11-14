#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The external-UUID pragma of check-uuid-v8.sh (owner ruling CASE-067,
# 2026-11-14): "hypatia: allow uuid/external -- <reason>" on the same line, or
# "hypatia: allow-next-line uuid/external -- <reason>" on the line before,
# exempts the bare-UUID rule on exactly one line. It never exempts identity
# fields, a reason is required, and a stale mark fails.
#
# Every UUID here is assembled at runtime (see uuid-v8-test.sh), and every
# pragma is assembled too, so this file neither trips nor uses the gate itself.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-uuid-v8.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

uuid() { printf '%s-%s-%s-%s-%s' "$@"; }
V4="$(uuid 258eafa5 e914 47da 95ca c5ab0dc85b11)"     # version 4 (an external GUID shape)
V4B="$(uuid 3f2504e0 4f89 41d3 9a0c 0305e82c3301)"    # another version 4
V8="$(uuid 01890a5d ac96 874b 8cce b302099a8057)"     # version 8
V5L="$(uuid 886313e1 3b8a 5372 9b90 0c9aee199e5d)"    # version 5, lower case
P="hypatia: allow uuid""/external"
N="hypatia: allow-next-line uuid""/external"

pass=0; fail=0
expect() { # expect <wanted-exit> <label> [flags...]
  local want="$1" label="$2" got=0; shift 2
  "$SCRIPT" "$@" "$WORK/t" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}
fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
names() {
  if grep -qF -- "$1" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $2"
  else fail=$((fail+1)); echo "  FAIL  $2"; sed 's/^/        /' "$WORK/out"; fi
}

for mode in "" --strict; do
  echo "mode: ${mode:-default}"
  fresh; printf 'const G = "%s" // %s -- RFC 6455 WebSocket GUID\n' "$V4" "$P" > "$WORK/t/a.js"
  expect 0 "same-line pragma with a reason exempts that line" $mode
  fresh; printf '// %s -- RFC 6455 WebSocket GUID\nconst G = "%s"\n' "$N" "$V4" > "$WORK/t/a.js"
  expect 0 "next-line pragma exempts the following line" $mode
  fresh; printf 'const G = "%s" // %s -- ok\nconst H = "%s"\n' "$V4" "$P" "$V4B" > "$WORK/t/a.js"
  expect 1 "the pragma covers its own line only" $mode
  names "non-v8" "an unmarked line is still refused"
  fresh; printf '// %s -- ok\nconst G = "%s"\nconst H = "%s"\n' "$N" "$V4" "$V4B" > "$WORK/t/a.js"
  expect 1 "next-line pragma covers one line only" $mode
  fresh; printf 'const G = "%s" // %s\n' "$V4" "$P" > "$WORK/t/a.js"
  expect 1 "a pragma without a reason is refused" $mode
  names "malformed uuid/external pragma" "the refusal names the malformed pragma"
  fresh; printf 'const G = "%s" // %s --   \n' "$V4" "$P" > "$WORK/t/a.js"
  expect 1 "a pragma with an empty reason is refused" $mode
  fresh; printf 'const G = "%s" // %s -- now v8\n' "$V8" "$P" > "$WORK/t/a.js"
  expect 1 "a pragma on a line with only acceptable UUIDs is stale" $mode
  names "stale uuid/external pragma" "the refusal names the stale pragma"
  fresh; printf 'no uuid here // %s -- left behind\n' "$P" > "$WORK/t/a.js"
  expect 1 "a pragma on a line with no UUID is stale" $mode
  fresh; printf '// %s -- dangling\n' "$N" > "$WORK/t/a.js"
  expect 1 "a next-line pragma at end of file is stale" $mode
  fresh; printf '// %s -- x\nnothing here\n' "$N" > "$WORK/t/a.js"
  expect 1 "a next-line pragma before a line without a refused UUID is stale" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s") ; %s -- not identity\n' "$V5L" "$P" > "$WORK/t/x_chora.deed"
  expect 1 "the pragma never exempts an identity field" $mode
  names "identity field :repo-uuid must carry a v8 id" "the identity refusal stands"
  fresh; printf 'example: `%s -- <reason>`\n' "$P" > "$WORK/t/doc.adoc"
  expect 0 "a documentation example with the <reason> placeholder is ignored" $mode
  fresh; printf 'the uuid''/external marker is described in prose\n' > "$WORK/t/doc.adoc"
  expect 0 "prose that names uuid/external without the pragma is ignored" $mode
done

echo
echo "uuid-v8-pragma-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
