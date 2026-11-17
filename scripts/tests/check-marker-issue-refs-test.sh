#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-marker-issue-refs-test.sh — fixture suite for scripts/check-marker-issue-refs.sh.
#
# Proves, each with a planted positive and a clean negative:
#   1. a bare marker is caught in every comment syntax the gate claims, and a
#      marker that cites an issue is accepted;
#   2. mentions are not markers: prose, strings, file names, fenced examples,
#      listing blocks, heredoc bodies, a leader glued to text;
#   3. the stated limits behave as documented (fail-closed string, heredoc to
#      end of file);
#   4. the exclusions are exactly as narrow as the gate's header says;
#   5. the marker/example pragma excuses one line, and a stale or reasonless
#      pragma fails;
#   6. the ledger is shrink-only (new, grown, stale, malformed, duplicate),
#      and --prune only deletes or lowers, never hides a new offender, and is
#      idempotent;
#   7. --cached reads the staged copy; --online reports closed, missing and
#      pull-request citations through a stub gh;
#   8. the suite sees a regression: three mutants of the gate are killed;
#   9. this repository matches its ledger.
#
# Fixture text is assembled from fragments ($T, $F, $PK) so this file holds no
# marker and no pragma and does not appear in the gate's own scan.
#
# Run: bash scripts/tests/check-marker-issue-refs-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$SCRIPT_DIR/../check-marker-issue-refs.sh}"
REPO_ROOT="$SCRIPT_DIR/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

T="TO""DO"
F="FIX""ME"
PK="hypatia: allow marker""/example"
PN="hypatia: allow-next-line marker""/example"
pass=0 fail=0

fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
plant() { mkdir -p "$(dirname "$WORK/t/$1")"; cat > "$WORK/t/$1"; }
ledger() { plant .machine_readable/marker-allow.txt; }

# expect <label> <want-rc> <needle|-> [gate] [args...] — runs the gate (or a
# mutant) on $WORK/t; checks the exit code and, unless "-", an output substring.
expect() {
  local label=$1 want=$2 needle=$3 gate=${4:-$GATE} out rc
  shift 4 2>/dev/null || shift $#
  out="$(bash "$gate" --root "$WORK/t" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || { [ "$needle" != - ] && ! printf '%s' "$out" | grep -qF -- "$needle"; }; then
    echo "FAIL: $label — wanted exit $want and '$needle', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# bare_case <label> <relpath> <content> — one file; the gate must refuse it.
bare_case() {
  fresh; printf '%b' "$3" | plant "$2"
  expect "caught: $1" 1 "new bare marker(s) in $2 (1)"
}
# clean_case <label> <relpath> <content> — one file; the gate must pass it.
clean_case() {
  fresh; printf '%b' "$3" | plant "$2"
  expect "not a marker: $1" 0 "0 ledgered bare marker(s) across 0 file(s)"
}

echo "== bare markers are caught in every claimed syntax =="
bare_case "shell #"                     a.sh          "#!/bin/sh\n# $T: fix this\n"
bare_case "trailing YAML #"             c.yml         "x: 1  # $T: later\n"
bare_case "Nickel #, word alone"        c.ncl         "{ a = 1 } # $T\n"
bare_case "Rust //"                     s.rs          "fn a() {}\n    // $T tidy up\n"
bare_case "Rust /// doc"                s.rs          "/// $F: wrong bound\n"
bare_case "C /* */ on one line"         s.c           "int a; /* $T: x */\n"
bare_case "continuation * in a block"   s.zig         "/*\n * $F: y\n */\n"
bare_case "bare line in a block"        s.js          "/*\n   $T: y\n*/\n"
bare_case "Haskell --"                  h.hs          "f = 1 -- $T: z\n"
bare_case "Haskell {- -}"               h.hs          "{- $T: z -}\n"
bare_case "deed ;;"                     d.deed        ";; $T: z\n(x)\n"
bare_case "TeX %"                       p.tex         "% $F: z\n"
bare_case "Markdown <!-- -->"           r.md          "text\n<!-- $T: z -->\n"
bare_case "HTML comment over lines"     p.html        "<!--\n  $T: z\n-->\n"
bare_case "AsciiDoc // at column 1"     d.adoc        "= T\n// $T: z\n"
bare_case "AsciiDoc //// block"         d.adoc        "////\n$F z\n////\n"
bare_case "template keeps its syntax"   x.rs.liquid   "// $T: z\n"
bare_case "extensionless shell hook"    hooks/pre-x   "#!/usr/bin/env bash\n# $T: z\n"
bare_case "a non-issue in parentheses"  a.sh          "# $T(alice): z\n"
bare_case "an issue cited loosely"      a.sh          "# $T: see #12\n"

echo
echo "== a marker that cites an issue is accepted =="
clean_case "this repository, (#N)"      a.sh   "# $T(#12): z\n"
clean_case "another repository"         s.rs   "// $F(hyperpolymath/proven#3) z\n"
clean_case "Markdown comment, cited"    r.md   "<!-- $T(#1) -->\n"

echo
echo "== mentions are not markers =="
clean_case "Markdown prose and status"  r.md   "- **Status:** $T\n**$T:** merge it\n"
clean_case "AsciiDoc table and list"    d.adoc "| $T: parser fixtures\n* $T: write the prose\n"
clean_case "AsciiDoc listing block"     d.adoc "----\n// $T: shown as an example\n# $T: z\n----\n"
clean_case "Markdown fence"             r.md   "\`\`\`\n<!-- $T: example -->\n\`\`\`\n"
clean_case "a string in shell"          a.sh   "msg='$T: fill in'\n"
clean_case "leader glued to text"       a.sh   "printf 'x\\\\n# $T: z\\\\n'\n"
clean_case "later in a comment"         a.sh   "# see the old # $T: list\n"
clean_case "a Rust string holding #"    s.rs   "s.push_str(\"# $T — fill in\");\n"
clean_case "a file name"                c.yml  "files: [\"$T.md\"]\n"
clean_case "word run on"                a.sh   "# $T-only templates\n# ${T}s\n"
clean_case "lower case"                 a.sh   "# todo: lower case is not the marker\n"
clean_case "heredoc body in shell"      a.sh   "cat <<'EOF'\n# $T: fixture text\nEOF\necho ok\n"
clean_case "heredoc in a YAML run"      w.yml  "run: |\n  cat <<EOF\n  # $T: fixture\n  EOF\n"
clean_case "here-string is no heredoc"  a.sh   "x=\$(cat <<<\"\$y\")\n"
clean_case "a type with no comments"    d.json "{\"a\": \"// $T: x\"}\n"

echo
echo "== the stated limits behave as documented =="
bare_case "a whitespace-led # inside a string fails closed" a.sh "echo \" # $T: x\"\n"
clean_case "an unterminated heredoc runs to the end" a.sh "cat <<EOF\n# $T: x\n"
fresh; printf 'cat <<EOF\nEOF\n# %s: x\n' "$T" | plant a.sh
expect "a closed heredoc ends the skip" 1 "new bare marker(s) in a.sh (1)"
fresh; printf '%s\n' "x=\$((1<<y))" "# $T: after a shift" | plant a.sh
expect "a shift is not a heredoc" 1 "new bare marker(s) in a.sh (1)"

echo
echo "== exclusions are as narrow as stated =="
fresh
printf '# %s: placeholder\n' "$T" | plant t.k9.ncl.in
printf '# %s: x\n' "$T" | plant .machine_readable/Debtfile.a2ml
printf '// %s: x\n' "$T" | plant docs/DEBTFILE-SPEC.adoc
expect "the three excluded paths are not read" 0 "0 ledgered"
printf '# %s: x\n' "$T" | plant t.ncl
printf '# %s: x\n' "$T" | plant sub/.machine_readable/Debtfile.a2ml
printf '// %s: x\n' "$T" | plant docs/OTHER.adoc
printf '# %s: x\n' "$T" | plant t.in.ncl
expect "neighbours of the excluded paths are read" 1 "4 bare marker(s) across 4 file(s)"
# The same exclusions through git pathspecs, which is how CI runs.
fresh
printf '# %s: placeholder\n' "$T" | plant x/t.k9.ncl.in
printf '# %s: x\n' "$T" | plant .machine_readable/Debtfile.a2ml
printf '# %s: x\n' "$T" | plant x/.machine_readable/Debtfile.a2ml
(cd "$WORK/t" && git init -q && git add -A)
expect "git mode: only the nested Debtfile is read" 1 "new bare marker(s) in x/.machine_readable/Debtfile.a2ml (1)"

echo
echo "== the marker/example pragma =="
fresh; printf '# %s: x  %s -- shows the refused form\n' "$T" "$PK" | plant a.sh
expect "a same-line pragma excuses its line" 0 "0 ledgered"
fresh; printf '# %s -- shows the refused form\n# %s: x\n' "$PN" "$T" | plant a.sh
expect "a next-line pragma excuses the next line" 0 "0 ledgered"
fresh; printf '# %s -- shows the refused form\n# %s: x\n# %s: y\n' "$PN" "$T" "$T" | plant a.sh
expect "a next-line pragma covers one line only" 1 "new bare marker(s) in a.sh (1)"
fresh; printf '# %s(#4): x  %s -- no longer needed\n' "$T" "$PK" | plant a.sh
expect "a pragma on a cited marker is stale" 1 "stale marker/example pragma"
fresh; printf '# %s: x  %s\n' "$T" "$PK" | plant a.sh
expect "a pragma without a reason is malformed" 1 "malformed marker/example pragma"
fresh; printf '# %s -- <reason>\n# %s: x\n' "$PK" "$T" | plant a.sh
expect "a <reason> placeholder is documentation, neither stale nor an excuse" 1 ": 1 problem(s); 1 bare"

echo
echo "== the ledger is shrink-only =="
fresh
printf '# %s: a\n# %s: b\n' "$T" "$F" | plant w.sh
printf '# header\n\nw.sh:2\n' | ledger
expect "exact ledger match passes" 0 "2 ledgered bare marker(s) across 1 file(s)"
printf 'w.sh:1\n' | ledger
expect "a count above the ledger GREW fails" 1 "bare markers GREW in w.sh: 2, ledger allows 1"
printf 'w.sh:3\n' | ledger
expect "a count below the ledger is stale" 1 "stale ledger entry w.sh:3 — now 2"
printf 'w.sh:2\ngone.sh:1\n' | ledger
expect "an entry with no bare marker left is stale" 1 "stale ledger entry gone.sh:1 — no bare marker left"
printf 'w.sh:2\n' | ledger
printf '// %s: c\n' "$T" | plant n.rs
expect "a new path beside a clean ledger fails" 1 "new bare marker(s) in n.rs (1)"
rm "$WORK/t/n.rs"
printf 'w.sh:two\n' | ledger
expect "a malformed entry fails closed" 1 "malformed or duplicate ledger entry"
printf 'w.sh:0\n' | ledger
expect "a zero count is malformed, not an allowance" 1 "malformed or duplicate ledger entry"
printf 'w.sh:2\nw.sh:2\n' | ledger
expect "a duplicate entry fails closed" 1 "malformed or duplicate ledger entry"

echo
echo "== --prune deletes and lowers, never adds or raises =="
fresh
printf '# %s: a\n' "$T" | plant w.sh
printf '# %s: a\n# %s: b\n' "$T" "$T" | plant g.sh
printf '# keep me\nw.sh:3\ngone.sh:1\ng.sh:2\n' | ledger
expect "prune: stale lines are fixed" 0 "2 ledger line(s) changed" "$GATE" --prune
if [ "$(cat "$WORK/t/.machine_readable/marker-allow.txt")" = "$(printf '# keep me\nw.sh:1\ng.sh:2')" ]; then
  echo "PASS: prune lowered w.sh, deleted gone.sh, kept the comment and order"; pass=$((pass + 1))
else
  echo "FAIL: prune wrote the wrong ledger"; sed 's/^/      | /' "$WORK/t/.machine_readable/marker-allow.txt"; fail=$((fail + 1))
fi
cp "$WORK/t/.machine_readable/marker-allow.txt" "$WORK/before"
expect "prune: a second run changes nothing" 0 "0 ledger line(s) changed" "$GATE" --prune
if cmp -s "$WORK/before" "$WORK/t/.machine_readable/marker-allow.txt"; then
  echo "PASS: prune is idempotent (byte-identical)"; pass=$((pass + 1))
else echo "FAIL: prune is not idempotent"; fail=$((fail + 1)); fi
printf '# %s: c\n' "$T" | plant n.sh
printf '# %s: d\n' "$T" >> "$WORK/t/g.sh"
expect "prune: a new offender still fails" 1 "new bare marker(s) in n.sh (1)" "$GATE" --prune
expect "prune: a grown count still fails" 1 "bare markers GREW in g.sh: 3, ledger allows 2" "$GATE" --prune
if cmp -s "$WORK/before" "$WORK/t/.machine_readable/marker-allow.txt"; then
  echo "PASS: prune neither added n.sh nor raised g.sh"; pass=$((pass + 1))
else echo "FAIL: prune hid an offender"; sed 's/^/      | /' "$WORK/t/.machine_readable/marker-allow.txt"; fail=$((fail + 1)); fi
expect "prune does not combine with --cached" 2 "does not combine" "$GATE" --prune --cached

echo
echo "== --cached reads the staged copy =="
fresh
printf 'echo ok\n' | plant a.sh
(cd "$WORK/t" && git init -q && git add -A)
printf '# %s: staged\n' "$T" > "$WORK/t/a.sh"
(cd "$WORK/t" && git add a.sh)
printf 'echo fixed in the working tree only\n' > "$WORK/t/a.sh"
expect "the staged bare marker is refused under --cached" 1 "new bare marker(s) in a.sh (1)" "$GATE" --cached
expect "the working tree is clean without --cached" 0 "0 ledgered"

echo
echo "== --online, against a stub gh =="
BIN="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$BIN" "$FIX"
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# Fixture-backed gh: `api repos/O/R/issues/N --jq EXPR`, read-only.
[ "$1" = api ] || { echo "stub gh: only api is supported" >&2; exit 3; }
path=$2; jqf=.
[ "${3:-}" = --jq ] && jqf=$4
f="$GH_FIX/${path//\//_}.json"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
[ "$(cat "$f")" = ERR ] && { echo "connect: connection refused" >&2; exit 1; }
jq -r "$jqf" "$f"
SHIM
chmod +x "$BIN/gh"
echo '{"state":"open"}' > "$FIX/repos_me_here_issues_1.json"
echo '{"state":"closed"}' > "$FIX/repos_me_here_issues_2.json"
echo '{"state":"open"}' > "$FIX/repos_o_r_issues_3.json"
echo '{"state":"open","pull_request":{"url":"x"}}' > "$FIX/repos_me_here_issues_5.json"
echo ERR > "$FIX/repos_me_here_issues_6.json"
online() { GH_FIX="$FIX" PATH="$BIN:$PATH" expect "$@"; }
fresh; printf '# %s(#1): a\n// is not read\n' "$T" | plant a.sh
printf '// %s(o/r#3): b\n' "$F" | plant b.rs
online "all cited issues open" 0 "2 cited issue(s), all open" "$GATE" --online --repo me/here
online "the listing names each issue and site" 0 "open    o/r#3  b.rs:1" "$GATE" --online --repo me/here
printf '# %s(#2): c\n' "$T" | plant c.sh
online "a closed issue fails" 1 "me/here#2 is closed" "$GATE" --online --repo me/here
rm "$WORK/t/c.sh"; printf '# %s(#4): c\n' "$T" | plant c.sh
online "a missing issue fails" 1 "me/here#4 does not exist" "$GATE" --online --repo me/here
rm "$WORK/t/c.sh"; printf '# %s(#5): c\n' "$T" | plant c.sh
online "a pull request is not an issue" 1 "me/here#5 is a pull request" "$GATE" --online --repo me/here
rm "$WORK/t/c.sh"; printf '# %s(#6): c\n' "$T" | plant c.sh
online "an unreadable issue is not a pass" 2 "could not be read" "$GATE" --online --repo me/here
online "no repository to resolve (#N) is a usage error" 2 "pass --repo" "$GATE" --online

echo
echo "== the suite can see a regression (kill the mutants) =="
# mutant <name> <sed-expr> <label> <want-rc> <needle> [args...]: a copy of the
# gate with <sed-expr> applied must parse, must differ from the gate, and must
# give <want-rc> on the current fixture where the real gate gives the opposite.
mutant() {
  local name=$1 expr=$2 m="$WORK/mutant-$1.sh"; shift 2
  sed "$expr" "$GATE" > "$m"
  if ! bash -n "$m" || cmp -s "$m" "$GATE"; then
    echo "FAIL: mutant $name is invalid or identical to the gate — it proves nothing"
    fail=$((fail + 1)); return
  fi
  local label=$1 want=$2 needle=$3; shift 3
  expect "mutant killed ($name): $label" "$want" "$needle" "$m" "$@"
}
fresh; printf '# %s: a\n' "$T" | plant w.sh; printf 'w.sh:3\n' | ledger
expect "control: a lowered count is stale under the real gate" 1 "stale ledger entry w.sh:3"
# shellcheck disable=SC2016 # the $ is sed text to match, not an expansion
mutant no-lower 's/elif \[ "\$n" -lt "\$want" \]; then echo "LOWER/elif false; then echo "LOWER/' \
  "without the LOWER verdict a shrunk count passes" 0 "none stale"
fresh; printf "printf 'x\\\\n# %s: z\\\\n'\n" "$T" | plant a.sh
expect "control: a glued leader is a mention under the real gate" 0 "0 ledgered"
mutant glued-leader 's/if (q == 1 || substr(s, q - 1, 1) ~ \/\[ \\t\]\/) return q/return q/' \
  "a leader glued to text is no longer refused as a leader" 1 "new bare marker"
fresh; printf '# %s: a\n' "$T" | plant w.sh; printf 'w.sh:3\n' | ledger
m="$WORK/mutant-prune-raises.sh"
# shellcheck disable=SC2016 # the $ is sed text to match, not an expansion
sed 's/LOWER) lower\[\$f\]=\$b/LOWER) lower[$f]=$((b + 5))/' "$GATE" > "$m"
if bash -n "$m" && ! cmp -s "$m" "$GATE"; then
  bash "$m" --root "$WORK/t" --prune >/dev/null 2>&1
  expect "mutant killed (prune-raises): the real gate refuses what a raising prune wrote" 1 "stale ledger entry w.sh:6"
else
  echo "FAIL: mutant prune-raises is invalid or identical to the gate"; fail=$((fail + 1))
fi

echo
echo "== this repository matches its ledger =="
out="$(bash "$GATE" --root "$REPO_ROOT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: repository ledger is exact — $out"; pass=$((pass + 1))
else
  echo "FAIL: repository ledger drifted (exit $rc)"; printf '%s\n' "$out" | sed 's/^/      | /'
  fail=$((fail + 1))
fi

echo
echo "check-marker-issue-refs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
