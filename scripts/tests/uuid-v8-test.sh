#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves check-uuid-v8.sh CAN FAIL, and fails for the right reasons, in both
# its default (dual-accept, ADR-008 P2) and --strict (v8 only) modes.
#
# The checker runs over this very repository (uuid-v8.yml), so every UUID in
# this file is ASSEMBLED AT RUNTIME from fragments. A literal non-conforming
# UUID here would turn the real gate red on its own test.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-uuid-v8.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Join five fragments into one 8-4-4-4-12 UUID string.
uuid() { printf '%s-%s-%s-%s-%s' "$@"; }
V8_8="$(uuid 01890a5d ac96 874b 8cce b302099a8057)"   # version 8, variant 8 (profile T shape)
V8_B="$(uuid 01890A5D AC96 874B BCCE B302099A8057)"   # version 8, variant b, upper case
V7_8="$(uuid 01890a5d ac96 774b 8cce b302099a8057)"   # version 7, variant 8
V4="$(uuid 3f2504e0 4f89 41d3 9a0c 0305e82c3301)"     # version 4
V5="$(uuid 886313e1 3b8a 5372 9b90 0c9aee199e5d)"     # version 5 (deed #u5 output shape)
V8_C="$(uuid 01890a5d ac96 874b ccce b302099a8057)"   # version 8, NON-RFC variant c
V8_7="$(uuid 01890a5d ac96 874b 7cce b302099a8057)"   # version 8, NCS variant 7

pass=0; fail=0
# Run the checker (with any extra flags) over $WORK/t and compare its exit code.
expect() { # expect <wanted-exit> <label> [checker flags...]
  local want="$1" label="$2" got=0; shift 2
  "$SCRIPT" "$@" "$WORK/t" >"$WORK/out" 2>&1 || got=$?   # by shebang (/bin/sh), as CI runs it
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}
# Empty the scratch tree.
fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
# Assert the last checker output contains a fixed string.
names() { # names <fixed-string> <label>
  if grep -qF -- "$1" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $2"
  else fail=$((fail+1)); echo "  FAIL  $2"; sed 's/^/        /' "$WORK/out"; fi
}

echo "default mode (dual-accept)"
fresh; printf 'id = "%s"\n' "$V8_8" > "$WORK/t/a.toml"
expect 0 "a v8 UUID (variant 8) is accepted"
fresh; printf 'id: %s\n' "$V8_B" > "$WORK/t/a.kyaml"
expect 0 "an upper-case v8 UUID (variant b) is accepted"
fresh; printf 'id = "%s"\n' "$V7_8" > "$WORK/t/a.toml"
expect 0 "a v7 UUID is accepted during dual-accept"
fresh; printf 'no identifiers here\n' > "$WORK/t/a.txt"
expect 0 "a file with no UUID is accepted"
fresh
expect 0 "an empty tree is accepted"
fresh; printf 'id = "%s"\n' "$V4" > "$WORK/t/a.toml"
expect 1 "a v4 UUID is rejected"
names "a.toml: non-v8/v7 UUID literal ($V4)" "the rejection names the file and the UUID"
fresh; printf 'id = "%s"\n' "$V5" > "$WORK/t/a.json"
expect 1 "a v5 UUID is rejected"
fresh; printf 'id = "%s"\n' "$V8_C" > "$WORK/t/a.toml"
expect 1 "version 8 with a non-RFC variant nibble (c) is rejected"
fresh; printf 'id = "%s"\n' "$V8_7" > "$WORK/t/a.toml"
expect 1 "version 8 with an NCS variant nibble (7) is rejected"
fresh; printf 'ok = "%s"\nbad = "%s"\n' "$V8_8" "$V4" > "$WORK/t/a.toml"
expect 1 "a v4 on a later line than a v8 is still rejected"
fresh; printf 'ids = ["%s", "%s"]\n' "$V4" "$V8_8" > "$WORK/t/a.toml"
expect 1 "a v4 BEFORE a v8 on the same line is rejected"
names "($V4)" "the same-line rejection names the v4, not the v8"
fresh; printf 'ids = ["%s", "%s"]\n' "$V8_8" "$V4" > "$WORK/t/a.toml"
expect 1 "a v4 AFTER a v8 on the same line is rejected"
fresh; mkdir -p "$WORK/t/sub/deeper"; printf '%s\n' "$V4" > "$WORK/t/sub/deeper/x.json"
expect 1 "a v4 in a nested directory is rejected"
fresh; mkdir -p "$WORK/t/.git"; printf '%s\n' "$V4" > "$WORK/t/.git/packed-refs"
expect 0 "a v4 inside .git/ is ignored"
fresh; printf '\000%s\n' "$V4" > "$WORK/t/blob.bin"
expect 0 "a v4 inside a binary file is ignored"
fresh; printf 'name = "P"\nuuid = "%s"\n\n[deps]\nX = "%s"\n\n[weakdeps]\nY = "%s"\n\n[extras]\nZ = "%s"\n' \
  "$V8_8" "$V4" "$V4" "$V4" > "$WORK/t/Project.toml"
expect 0 "v4 dependency UUIDs in Project.toml [deps]/[weakdeps]/[extras] are accepted"
fresh; printf 'name = "P"\nuuid = "%s"\n\n[deps]\nX = "%s"\n' "$V4" "$V8_8" > "$WORK/t/Project.toml"
expect 1 "a v4 package's own uuid in Project.toml is rejected"
fresh; printf 'uuid = "%s"\n[ deps ] # comment\nX = "%s"\n\n[compat]\n\n[sources]\nY = "%s"\n' \
  "$V8_8" "$V4" "$V4" > "$WORK/t/JuliaProject.toml"
expect 1 "the exemption ends at the next table header"
fresh; printf '[deps]\nX = "%s"\n' "$V4" > "$WORK/t/deps.toml"
expect 1 "a [deps] table outside a Julia project file is not exempt"
fresh; mkdir -p "$WORK/t/docs"; printf '[[deps.X]]\nuuid = "%s"\n' "$V4" > "$WORK/t/docs/Manifest-v1.12.toml"
expect 0 "a v4 in a Julia Manifest is accepted"
fresh; printf 'name = "{{P}}"\nuuid = "{{U}}"\n\n[extras]\nTest = "%s"\n' "$V4" > "$WORK/t/Project.toml.in"
expect 0 "a Project.toml.in mint template gets Project.toml's [extras] exemption"
fresh; printf 'uuid = "%s"\n\n[extras]\nTest = "%s"\n' "$V4" "$V4" > "$WORK/t/Project.toml.in"
expect 1 "a v4 package uuid in a Project.toml.in mint template is rejected"
fresh; printf '[deps]\nX = "%s"\n' "$V4" > "$WORK/t/deps.toml.in"
expect 1 "a [deps] table in a non-Julia .in template is not exempt"
fresh; printf '[[deps.X]]\nuuid = "%s"\n' "$V4" > "$WORK/t/Manifest.toml.in"
expect 0 "a v4 in a Manifest.toml.in template is accepted"
fresh; printf '[deps]\nX = "%s"\n' "$V4" > "$WORK/t/Project.toml.inx"
expect 1 "a near-miss suffix (Project.toml.inx) is not exempt"

fresh; printf 'id = "%s"\n' "$V4" > "$WORK/t/CLADE.a2ml"
expect 0 "a v4 in a retired .a2ml file is ignored (D320)"
fresh; printf 'id = "%s"\n' "$V4" > "$WORK/t/CLADE.a2ml.in"
expect 0 "a v4 in a retired .a2ml.in template is ignored (D320)"
fresh; printf 'id = "%s"\n' "$V4" > "$WORK/t/a2ml-notes.adoc"
expect 1 "a v4 in a file merely NAMED after a2ml is still rejected"
fresh; printf 'id = "%s"\n' "$V4" > "$WORK/t/x.a2mlx"
expect 1 "a v4 in a .a2mlx file (near-miss extension) is still rejected"

echo "scan paths"
got=0; "$SCRIPT" "$WORK/no-such-dir" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "  ok    a missing scan path exits 2"
else fail=$((fail+1)); echo "  FAIL  a missing scan path exits 2 (got $got)"; fi
names "scan path does not exist" "the missing-path error names the problem"

echo "--strict mode (v8 only)"
fresh; printf 'id = "%s"\n' "$V8_8" > "$WORK/t/a.toml"
expect 0 "a v8 UUID is accepted under --strict" --strict
fresh; printf 'id = "%s"\n' "$V7_8" > "$WORK/t/a.toml"
expect 1 "a v7 UUID is rejected under --strict" --strict
names "a.toml: non-v8 UUID literal ($V7_8)" "the --strict rejection names the v7 UUID"
fresh; printf 'id = "%s"\n' "$V8_C" > "$WORK/t/a.toml"
expect 1 "a bad variant is still rejected under --strict" --strict
# The rsr-template-repo julia-library archetype: registry UUIDs (v5) under
# [extras] of a Project.toml.in, with a v8 placeholder for the package's own.
fresh; printf 'name = "P"\nuuid = "%s"\n\n[extras]\nAqua = "%s"\nTest = "%s"\n' \
  "$V8_8" "$V5" "$V5" > "$WORK/t/Project.toml.in"
expect 0 "registry UUIDs in a Project.toml.in [extras] pass under --strict" --strict

echo "deed opaque literal #uuid\"…\" (deed.abnf v1.3.0, ruling U4)"
LOWER_V8_B="$(printf '%s' "$V8_B" | tr 'A-F' 'a-f')"
V5_C="$(uuid 886313e1 3b8a 5372 cb90 0c9aee199e5d)"   # version 5, NON-RFC variant c
for mode in "" --strict; do
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "a v5 in the identity field :repo-uuid is rejected ${mode:-(default)}" $mode
  names "identity field :repo-uuid must carry a v8 id, found v5" "the identity rejection names the field ${mode:-(default)}"
  for key in :estate-uuid :forge-uuid :beholding-chora :uuid :estate :base :forge :repo; do
    fresh; printf '(x %s #uuid"%s")\n' "$key" "$V5" > "$WORK/t/a_chora.deed"
    expect 1 "a v5 in the identity field $key is rejected ${mode:-(default)}" $mode
  done
  fresh; printf '(x :of-chora #uuid"%s")\n' "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "a v5 in the identity field :of-chora is rejected ${mode:-(default)}" $mode
  # Owner ruling Q2 (2026-11-14): #u5 in an identity field is an error in every
  # mode; #u8 is accepted. Neither file holds a bare UUID, so this also checks
  # that the #u5 rule runs on files the UUID scan would skip.
  for key in :repo-uuid :estate-uuid :forge-uuid :beholding-chora :of-chora :uuid :estate :base :forge :repo; do
    fresh; printf '(x %s #u5"estate/chora")\n' "$key" > "$WORK/t/a_chora.deed"
    expect 1 "#u5 in the identity field $key is rejected ${mode:-(default)}" $mode
  done
  names "identity field :repo carries a #u5 literal" "the #u5 rejection names the field ${mode:-(default)}"
  fresh; printf '(repo-deed\n  :repo-uuid\n  #u5"github.com/o/x")\n' > "$WORK/t/a_chora.deed"
  expect 1 "#u5 on the line after its identity field is rejected ${mode:-(default)}" $mode
  fresh; printf '(repo-deed\n  :repo-uuid ; a note\n  #u5"github.com/o/x")\n' > "$WORK/t/a_chora.deed"
  expect 1 "#u5 after a comment used as the separator is rejected ${mode:-(default)}" $mode
  fresh; printf '(repo-deed\n  :repo-uuid ; a note\n  #uuid"%s")\n' "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "a v5 #uuid after a comment used as the separator is rejected ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :note (":repo-uuid ; example" \043u5"ordinary-name"))\n' > "$WORK/t/a_chora.deed"
  expect 0 "a ';' inside a string is not a comment, so no identity field is invented ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :note ":repo-uuid \\" ; still a string" \043u5"ordinary-name")\n' > "$WORK/t/a_chora.deed"
  expect 0 "an escaped quote does not end the string before a ';' ${mode:-(default)}" $mode
  fresh; printf '(repo-deed) ; :repo-uuid \043u5"github.com/o/x"\n' > "$WORK/t/a_chora.deed"
  expect 1 "a comment that quotes a field with #u5 is rejected (lexical rule) ${mode:-(default)}" $mode
  fresh; printf '(repo-deed\n  :repo-uuid\n  #uuid"%s")\n' "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "a v5 #uuid on the line after its identity field is rejected ${mode:-(default)}" $mode
  fresh; printf '\000\001:repo-uuid \043u5"github.com/o/x"\000' > "$WORK/t/blob.bin"
  expect 0 "a binary file is not read for #u5 identity fields ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #u8"gv-clade-index:github.com/o/x" :beholding-chora #u8"chora:estate/github.com/o")\n' > "$WORK/t/a_chora.deed"
  expect 0 "#u8 in identity fields is accepted ${mode:-(default)}" $mode
  fresh; printf '(praxis-deed (alias :registry-name #u5"github.com/o/x"))\n' > "$WORK/t/a_praxis.deed"
  expect 0 "#u5 outside an identity field is not this rule's business ${mode:-(default)}" $mode
  fresh; printf '(praxis-deed (alias :registry-v5 #uuid"%s"))\n' "$V5" > "$WORK/t/a_praxis.deed"
  expect 0 "a v5 inside #uuid\"…\" outside an identity field is accepted ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$LOWER_V8_B" > "$WORK/t/a_chora.deed"
  expect 0 "a v8 inside #uuid\"…\" is accepted ${mode:-(default)}" $mode
  fresh; printf 'The id is `#uuid"%s"`.\n' "$V5" > "$WORK/t/notes.adoc"
  expect 0 "a v5 typed as #uuid\"…\" in prose is accepted ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V4" > "$WORK/t/a_chora.deed"
  expect 1 "a v4 inside #uuid\"…\" is rejected ${mode:-(default)}" $mode
  names "#uuid literal is not v5 or v8 with variant 10 ($V4)" "the typed rejection names the v4 ${mode:-(default)}"
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V7_8" > "$WORK/t/a_chora.deed"
  expect 1 "a v7 inside #uuid\"…\" is rejected, even in default mode ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V5_C" > "$WORK/t/a_chora.deed"
  expect 1 "a v5 with a non-RFC variant inside #uuid\"…\" is rejected ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V8_B" > "$WORK/t/a_chora.deed"
  expect 1 "an upper-case v8 in #uuid\"…\" is malformed, not a plain v8 ${mode:-(default)}" $mode
  names "malformed #uuid literal" "the upper-case rejection says malformed ${mode:-(default)}"
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$(printf '%s' "$V7_8" | tr 'a-f' 'A-F')" > "$WORK/t/a_chora.deed"
  expect 1 "an upper-case v7 in #uuid\"…\" does not fall through to dual-accept ${mode:-(default)}" $mode
  fresh; printf '(x #uuid "%s")\n' "$V7_8" > "$WORK/t/a_chora.deed"
  expect 1 "a v7 in #uuid with a space does not fall through to dual-accept ${mode:-(default)}" $mode
  fresh; printf '(repo-deed :repo-uuid #uuid"%s")\n' "$(printf '%s' "$V5" | tr 'a-f' 'A-F')" > "$WORK/t/a_chora.deed"
  expect 1 "an upper-case v5 in #uuid\"…\" is not typed, so it is rejected ${mode:-(default)}" $mode
  fresh; printf '{"name": "%s"}\n' "$V5" > "$WORK/t/a.json"
  expect 1 "a bare v5 outside #uuid\"…\" is still rejected ${mode:-(default)}" $mode
  fresh; printf '(x #uuid"%s" "%s")\n' "$V5" "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "a bare v5 beside a typed one on the same line is rejected ${mode:-(default)}" $mode
  fresh; printf '(x #uuid "%s")\n' "$V5" > "$WORK/t/a_chora.deed"
  expect 1 "#uuid with a space before the string is malformed ${mode:-(default)}" $mode
done

echo "per-repository exemptions (.uuid-v8-exempt)"
FIX=1-formats/deed/tools/fixtures/invalid
fresh; mkdir -p "$WORK/t/$FIX"
printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V4" > "$WORK/t/$FIX/inuuid-v4_chora.deed"
expect 1 "with no exemption file, nothing is exempt by path (the script names no paths)" --strict
printf '# reason\n\n%s\n' "$FIX/inuuid-v4_chora.deed" > "$WORK/t/.uuid-v8-exempt"
expect 0 "a file listed in .uuid-v8-exempt is not scanned" --strict
printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V4" > "$WORK/t/$FIX/inuuid-other_chora.deed"
expect 1 "an unlisted sibling is still scanned" --strict
fresh; mkdir -p "$WORK/t/$FIX"
printf '(repo-deed :repo-uuid #uuid"%s")\n' "$V4" > "$WORK/t/$FIX/inuuid-v4_chora.deed"
printf './%s\n' "$FIX/inuuid-v4_chora.deed" > "$WORK/t/.uuid-v8-exempt"
expect 0 "an entry may start with ./" --strict
printf '%s\n' "$FIX/inuuid-*" > "$WORK/t/.uuid-v8-exempt"
expect 2 "a glob in .uuid-v8-exempt is a usage error" --strict
names "is not an exact path (no globs)" "the glob error names the problem"
fresh; mkdir -p "$WORK/t/sub"
printf '%s\n' "$V4" > "$WORK/t/sub/a.json"
printf 'a.json\n' > "$WORK/t/.uuid-v8-exempt"
expect 1 "an entry is relative to the scan root, not a file name anywhere" --strict
fresh; printf '%s\n' "$V4" > "$WORK/t/a.json"; printf 'a.json\n' > "$WORK/t/.uuid-v8-exempt"
got=0; "$SCRIPT" --strict "$WORK/t/" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 0 ]; then pass=$((pass+1)); echo "  ok    a scan root given with a trailing slash still matches"
else fail=$((fail+1)); echo "  FAIL  a scan root given with a trailing slash still matches (got $got)"; sed 's/^/        /' "$WORK/out"; fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
