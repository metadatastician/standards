#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# link-rot-guard-test.sh — fixture suite for scripts/link-rot-guard.sh.
#
# Proves, each with a planted positive and a clean negative:
#   1. a tree whose links all resolve passes (positive control), and each
#      kind of break is refused as new: AsciiDoc link:, AsciiDoc image:,
#      Markdown [text](path); a fragment or query on a good target is fine,
#      and so are http, mailto and absolute targets;
#   2. 9-archive/ at the root is excluded WHATEVER the checkout directory is
#      called (standards, an unrelated name, and `index` as the pre-commit
#      hook's throwaway repository is), while a 9-archive/ lower down is not;
#   3. the ledger is shrink-only: a listed break passes, a new file fails, a
#      grown count fails, a fixed link with its ledger line left fails until
#      pruned, a lowered count fails until pruned, a malformed or duplicate
#      line fails;
#   4b. link syntax and --base: root-relative targets are broken, Markdown
#      titles, block images and document attributes parse, and a ledger line
#      may not be new or higher than at the merge base;
#   4. --prune deletes and lowers, never adds or raises, refuses to hide a new
#      break, and is idempotent; --print and --list report without judging;
#      a positional ROOT still works (the Justfile recipe passes one);
#   5. the suite sees a regression: thirty-two mutants of the gate are killed;
#   6. this repository matches its ledger (exit 0), under its own name and
#      under a copy named otherwise.
#
# Run: bash scripts/tests/link-rot-guard-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$SCRIPT_DIR/../link-rot-guard.sh}"
REPO_ROOT="$SCRIPT_DIR/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

L=.machine_readable/link-rot-allow.txt
pass=0 fail=0

fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
plant() { mkdir -p "$(dirname "$WORK/t/$1")"; cat > "$WORK/t/$1"; }
ledger() { plant "$L"; }

# A clean tree: every kind of good link, nothing broken.
clean_tree() {
  fresh
  plant docs/target.adoc <<<'= Target'
  plant docs/a.adoc <<<'See link:target.adoc[t], link:target.adoc#frag[f], link:target.adoc?x=1[q], link:https://example.org/x[ext], link:mailto:a@b.c[m], link:/abs/path[a] and image:logo.png[logo].'
  : > "$WORK/t/docs/logo.png"
  plant docs/b.md <<<'A [good](target.adoc) one, [web](https://example.org/x), [top](#frag).'
  ledger </dev/null
}

# expect <label> <want-rc> <needle|-> [gate] [args...]
expect() {
  local label=$1 want=$2 needle=$3 gate=${4:-$GATE} out rc
  shift 4 2>/dev/null || shift $#
  out="$(bash "$gate" --root "$WORK/t" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || { [ "$needle" != - ] && ! grep -qF -- "$needle" <<<"$out"; }; then
    echo "FAIL: $label — wanted exit $want and '$needle', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# ---------------------------------------------------------------- 1. controls
clean_tree
expect "positive control: all links resolve" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
expect "new broken AsciiDoc link is refused" 1 "new broken link(s) in docs/c.adoc"

clean_tree; plant docs/c.adoc <<<'Broken: image:nowhere.png[x]'
expect "new broken image is refused" 1 "new broken link(s) in docs/c.adoc"

clean_tree; plant docs/c.md <<<'Broken: [x](nowhere.md)'
expect "new broken Markdown link is refused" 1 "new broken link(s) in docs/c.md"

clean_tree; plant docs/c.adoc <<<'Broken: link:../nowhere/[x]'
expect "the break is named in an annotation" 1 "::error file=docs/c.adoc::broken internal link -> ../nowhere/"

# ---------------------------------------------------------------- 2. archive
for d in standards other-name index; do
  rm -rf "$WORK/t2"; mkdir -p "$WORK/t2/$d/9-archive/old" "$WORK/t2/$d/docs"
  printf 'Dead: link:gone.adoc[x]\n' > "$WORK/t2/$d/9-archive/old/a.adoc"
  printf 'Dead: [x](gone.md)\n' > "$WORK/t2/$d/9-archive/b.md"
  printf '= ok\n' > "$WORK/t2/$d/docs/ok.adoc"
  out="$(bash "$GATE" --root "$WORK/t2/$d" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "PASS: 9-archive/ excluded in a checkout named '$d'"; pass=$((pass + 1))
  else echo "FAIL: 9-archive/ not excluded in a checkout named '$d'"; printf '%s\n' "$out" | sed 's/^/      | /'; fail=$((fail + 1)); fi
done

clean_tree; plant docs/9-archive/a.adoc <<<'Live: link:gone.adoc[x]'
expect "a 9-archive/ below the root is not excluded" 1 "new broken link(s) in docs/9-archive/a.adoc"

# ---------------------------------------------------------------- 3. ledger
clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x] link:nowhere2.adoc[y]'
ledger <<<'docs/c.adoc:2'
expect "a ledgered break passes" 0 "2 ledgered broken link(s) across 1 file(s)"

ledger <<<'docs/c.adoc:1'
expect "a count above the ledger is refused (grown)" 1 "GREW in docs/c.adoc: 2, ledger allows 1"

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
plant docs/d.adoc <<<'Broken: link:nowhere.adoc[x]'
ledger <<<'docs/c.adoc:1'
expect "a new file is refused beside a ledgered one" 1 "new broken link(s) in docs/d.adoc"

clean_tree; ledger <<<'docs/a.adoc:1'
expect "a fixed link with its ledger line left is refused (gone)" 1 "stale ledger entry docs/a.adoc:1 — no broken link left"

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
ledger <<<'docs/c.adoc:3'
expect "a lowered count is refused until pruned" 1 "stale ledger entry docs/c.adoc:3 — now 1"

clean_tree; ledger <<<'docs/a.adoc:zero'
expect "a malformed ledger line is refused" 1 "malformed or duplicate ledger entry"

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
ledger <<<$'docs/c.adoc:1\ndocs/c.adoc:1'
expect "a duplicate ledger line is refused" 1 "malformed or duplicate ledger entry"

# ---------------------------------------------------------------- 4. prune etc.
clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
ledger <<<$'# keep this comment\ndocs/a.adoc:1\ndocs/c.adoc:3'
expect "prune deletes and lowers" 0 "1 line(s) deleted, 1 count(s) lowered" "$GATE" --prune
got=$(cat "$WORK/t/$L"); want=$'# keep this comment\ndocs/c.adoc:1'
if [ "$got" = "$want" ]; then echo "PASS: prune left the comment and the lowered line only"; pass=$((pass + 1))
else echo "FAIL: prune result wrong: $got"; fail=$((fail + 1)); fi
expect "the pruned ledger now passes" 0 "none new, none grown, none stale"
expect "prune is idempotent" 0 "nothing stale" "$GATE" --prune

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x] link:n2.adoc[y]'
ledger <<<$'docs/a.adoc:1\ndocs/c.adoc:1'
before=$(cat "$WORK/t/$L")
expect "prune refuses to hide a grown break" 1 "prune refused" "$GATE" --prune
if [ "$(cat "$WORK/t/$L")" = "$before" ]; then echo "PASS: refused prune left the ledger unchanged"; pass=$((pass + 1))
else echo "FAIL: refused prune edited the ledger"; fail=$((fail + 1)); fi

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
expect "--print lists path:count and exits 0" 0 "docs/c.adoc:1" "$GATE" --print
expect "--list names the target and exits 0" 0 "BROKEN  docs/c.adoc -> nowhere.adoc" "$GATE" --list

clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'
out="$(cd "$WORK" && bash "$GATE" t 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then echo "PASS: a positional ROOT still works"; pass=$((pass + 1))
else echo "FAIL: positional ROOT: exit $rc"; fail=$((fail + 1)); fi

# ---------------------------------------------------------------- 4b. syntax
# A link resolves beside its source, as a renderer resolves it: a repo-root
# looking target in a nested document is broken.
clean_tree; plant docs/c.adoc <<<'Root-style: link:docs/target.adoc[x]'
expect "a repo-root-looking target in a nested document is broken" 1 "broken internal link -> docs/target.adoc"

clean_tree; plant docs/c.md <<<$'A [t](target.adoc "A title") and [u](<target.adoc> \'T\') and [v](target.adoc (T)).'
expect "Markdown titles are split off the destination" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.md <<<'A [t](nowhere.adoc "A title").'
expect "a titled Markdown link to a missing file is reported without its title" 1 "broken internal link -> nowhere.adoc"

clean_tree; plant docs/c.adoc <<<'image::logo.png[Logo]'
expect "an AsciiDoc block image resolves" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.adoc <<<'image::nologo.png[Logo]'
expect "a broken block image is reported without a leading colon" 1 "broken internal link -> nologo.png"

clean_tree; plant docs/c.adoc <<<$':base: target.adoc\nSee link:{base}[x].'
expect "a document attribute is expanded before the check" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.adoc <<<$':base: gone.adoc\nSee link:{base}[x].'
expect "an attribute that expands to a missing file is broken" 1 "broken internal link -> gone.adoc"

clean_tree; plant docs/c.adoc <<<'See link:{set-elsewhere}[x].'
expect "an attribute defined outside the file is skipped, not reported" 0 "none new, none grown, none stale"

# Markdown destinations: balanced parentheses and <angle brackets>.
clean_tree; : > "$WORK/t/docs/a(b).md"; plant docs/c.md <<<'A [t](<a(b).md>) and [u](a(b).md) and [v](<a(b).md> "T").'
expect "Markdown destinations may hold balanced parentheses" 0 "none new, none grown, none stale"

# A name that starts with "http" is a file, not a URL; real schemes are external.
clean_tree; plant docs/c.md <<<'A [g](http-guide.md).'
expect "a missing file named http-guide.md is reported" 1 "broken internal link -> http-guide.md"

clean_tree; plant docs/c.md <<<'[a](https://example.org/x) [b](mailto:a@b.c) [c](irc://example.org/x) [d](#frag)'
expect "URI schemes and fragments are external" 0 "none new, none grown, none stale"

# :imagesdir: moves image targets, not link targets.
clean_tree; mkdir -p "$WORK/t/docs/assets"; : > "$WORK/t/docs/assets/pic.svg"
plant docs/c.adoc <<<$':imagesdir: assets\nimage::pic.svg[P] and image:pic.svg[P]'
expect "an image resolves under :imagesdir:" 0 "none new, none grown, none stale"

clean_tree; mkdir -p "$WORK/t/docs/assets"; : > "$WORK/t/docs/assets/pic.svg"
plant docs/c.adoc <<<$':imagesdir: assets\nSee link:pic.svg[P].'
expect "a link is not moved by :imagesdir:" 1 "broken internal link -> pic.svg"

# Literal and code regions are not links; the state resets when they close.
clean_tree; plant docs/c.adoc <<<$'----\nlink:gone.adoc[x]\n----\n....\nlink:gone2.adoc[x]\n....\n// link:gone3.adoc[x]\n////\nlink:gone4.adoc[x]\n////\nlink:target.adoc[ok]'
expect "AsciiDoc listing, literal and comment blocks are skipped" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.adoc <<<$'----\nlink:gone.adoc[x]\n----\nlink:after.adoc[x]'
expect "a link after a closed block is still checked" 1 "broken internal link -> after.adoc"

clean_tree; plant docs/c.md <<<$'```\n[x](gone.md)\n```\n~~~\n[y](gone2.md)\n~~~\n[z](after.md)'
expect "Markdown fenced blocks are skipped and the fence state resets" 1 "broken internal link -> after.md"

# Attributes follow document order: a later definition wins, an unset removes it.
clean_tree; plant docs/c.adoc <<<$':d: target.adoc\nlink:{d}[a]\n:d: gone.adoc\nlink:{d}[b]'
expect "a redefined attribute changes the target from that line on" 1 "broken internal link -> gone.adoc"

clean_tree; plant docs/c.adoc <<<$':d: gone.adoc\n:d!:\nlink:{d}[a]'
expect "an unset attribute is unresolved and skipped" 0 "none new, none grown, none stale"

# Inline code spans and backslash escapes in Markdown.
clean_tree; plant docs/c.md <<<'Write `[x](missing.md)` and ``[y](missing2.md)`` as examples.'
expect "Markdown inline code spans are not links" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.md <<<'`[a](m.md)` then [b](gone.md).'
expect "a live link after a code span on the same line is checked" 1 "broken internal link -> gone.md"

clean_tree; : > "$WORK/t/docs/a)b.md"; plant docs/c.md <<<'An [ok](a\)b.md) link.'
expect "an escaped parenthesis stays in the Markdown destination" 0 "none new, none grown, none stale"

# xref: file-bearing cross-references are links, local ids are not.
clean_tree; plant docs/c.adoc <<<'See xref:gone.adoc[x].'
expect "an xref to a missing file is reported" 1 "broken internal link -> gone.adoc"

clean_tree; plant docs/c.adoc <<<'See xref:gone.adoc#sec[x].'
expect "an xref to a missing file with an anchor is reported without it" 1 "broken internal link -> gone.adoc"

clean_tree; plant docs/c.adoc <<<'See xref:target.adoc[a], xref:target.adoc#s[b] and xref:local-id[c].'
expect "a resolving xref and a local xref pass" 0 "none new, none grown, none stale"

# Inline passthroughs show a macro literally; they are not links.
clean_tree; plant docs/c.adoc <<<'Show +link:gone.adoc[x]+ and ++link:gone2.adoc[y]++ and pass:[link:gone3.adoc[z]].'
expect "AsciiDoc inline passthroughs holding a macro are skipped" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.adoc <<<'Show +link:gone.adoc[x]+ then link:real-gone.adoc[y].'
expect "a real link after a passthrough on the same line is checked" 1 "broken internal link -> real-gone.adoc"

# .asciidoc is an AsciiDoc source too.
clean_tree; plant docs/c.asciidoc <<<'Broken: link:gone.adoc[x]'
expect "a .asciidoc source is scanned" 1 "new broken link(s) in docs/c.asciidoc"

# Destinations are URL paths: %20 names a space, but a literal % still resolves.
clean_tree; : > "$WORK/t/docs/a b.md"; : > "$WORK/t/docs/100%.md"; plant docs/c.md <<<'An [ok](a%20b.md) and [lit](100%.md) link.'
expect "a percent-encoded destination resolves, and a literal percent file too" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.md <<<'A [x](n%20o.md) link.'
expect "a missing percent-encoded target is reported as written" 0 "BROKEN  docs/c.md -> n%20o.md" "$GATE" --list

# A passthrough inside a macro target is the target; one wrapping a macro is literal.
clean_tree; plant docs/c.adoc <<<'See link:pass:[missing file.pdf][x].'
expect "a passthrough link target is checked" 1 "broken internal link -> missing file.pdf"

clean_tree; : > "$WORK/t/docs/a b.pdf"; plant docs/c.adoc <<<'See link:pass:[a b.pdf][x].'
expect "a passthrough link target that exists resolves" 0 "none new, none grown, none stale"

# Markdown fences close on the same marker, at least as long, with nothing after.
clean_tree; plant docs/c.md <<<$'````\n```\n[x](gone.md)\n````\n[y](after.md)'
expect "a longer fence is not closed by a shorter one" 1 "broken internal link -> after.md"

clean_tree; plant docs/c.md <<<$'```\n~~~\n[x](gone.md)\n```'
expect "a tilde line does not close a backtick fence" 0 "none new, none grown, none stale"

# A link needs an opening bracket before "](".
clean_tree; plant docs/c.md <<<'This is not a link ](missing.md) at all.'
expect "a bare ]( is not a Markdown link" 0 "none new, none grown, none stale"

clean_tree; plant docs/c.md <<<'An image ![alt](target.adoc) and [t](gone.md).'
expect "an image and a link after it still parse" 1 "broken internal link -> gone.md"

# A link that leaves the repository is broken without the filesystem being asked.
clean_tree; : > "$WORK/outside.txt"; plant docs/c.adoc <<<'See link:../../outside.txt[x].'
expect "a link escaping the root is broken even when the file exists" 1 "broken internal link -> ../../outside.txt"

clean_tree; plant docs/c.adoc <<<'See link:../docs/target.adoc[x] and link:./../docs/target.adoc[y].'
expect "a .. that stays inside the root resolves" 0 "none new, none grown, none stale"

clean_tree; : > "$WORK/outside.txt"; plant docs/c.md <<<'See [x](%2e%2e/%2e%2e/outside.txt).'
expect "a percent-encoded escape is broken too" 0 "BROKEN  docs/c.md -> %2e%2e/%2e%2e/outside.txt" "$GATE" --list

# Text from contributor files is printed into the job log: it must not be able
# to start a workflow command of its own.
clean_tree; nm=$'docs/evil\n::error::pwned.adoc'; printf 'link:gone.adoc[x]\n' > "$WORK/t/$nm"
out="$(bash "$GATE" --root "$WORK/t" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && ! grep -q '^::error::pwned' <<<"$out" && grep -qF 'evil?::error::pwned.adoc' <<<"$out"; then
  echo "PASS: a newline in a file name cannot start a workflow command"; pass=$((pass + 1))
else echo "FAIL: a newline in a file name reached the log"; printf '%s\n' "$out" | sed 's/^/      | /'; fail=$((fail + 1)); fi

clean_tree; plant docs/c.adoc <<<'See link:a%0Ab::error::x.adoc[x].'
expect "% in a target is escaped in the annotation" 1 "::error file=docs/c.adoc::broken internal link -> a%250Ab::error::x.adoc"

clean_tree; plant docs/d,e:f.adoc <<<'See link:gone.adoc[x].'
expect "a comma and colon in a path are escaped in the annotation property" 1 "::error file=docs/d%2Ce%3Af.adoc::"

clean_tree; ledger <<<$'docs/a.adoc:1\r'
expect "a carriage return in a ledger line is malformed and shown as ?" 1 "malformed or duplicate ledger entry (want one path:count per file): docs/a.adoc:1?"

# --base: the ledger may not gain a line or a count against the merge base.
base_repo() { # base_repo <base-ledger-text|-> <head-ledger-text>
  clean_tree
  plant docs/c.adoc <<<'Broken: link:n1.adoc[x] link:n2.adoc[y]'
  git -C "$WORK/t" init -q . && git -C "$WORK/t" config user.email t@invalid && git -C "$WORK/t" config user.name t \
    && git -C "$WORK/t" config commit.gpgsign false
  if [ "$1" != - ]; then printf '%s\n' "$1" > "$WORK/t/$L"; else rm -f "$WORK/t/$L"; fi
  git -C "$WORK/t" add -A && git -C "$WORK/t" commit -q -m base
  printf '%s\n' "$2" > "$WORK/t/$L"
}
base_repo 'docs/c.adoc:2' 'docs/c.adoc:2'
expect "--base: an unchanged ledger passes" 0 "none new, none grown, none stale" "$GATE" --base HEAD
base_repo 'docs/c.adoc:1' 'docs/c.adoc:2'
expect "--base: a raised count is refused" 1 "ledger grew against base: docs/c.adoc: 1 -> 2" "$GATE" --base HEAD
base_repo $'docs/z.adoc:1' $'docs/z.adoc:1\ndocs/c.adoc:2'
expect "--base: a new ledger line is refused" 1 "ledger grew against base: docs/c.adoc: 0 -> 2" "$GATE" --base HEAD
base_repo - 'docs/c.adoc:2'
expect "--base: no ledger at the base is the initial snapshot" 0 "initial snapshot accepted" "$GATE" --base HEAD
base_repo 'docs/c.adoc:2' 'docs/c.adoc:2'
expect "--base: an unknown revision is a setup error" 2 "cannot resolve base revision" "$GATE" --base no-such-rev

# ---------------------------------------------------------------- 5. mutants
mkdir -p "$WORK/mut/lib"
cp "$SCRIPT_DIR/../lib/ledger-prune.sh" "$WORK/mut/lib/"

# mutant <label> <sed-expr> <fixture-fn> <want-rc> <needle>
# The mutant must differ from the gate, and the check that kills it must pass
# on the real gate (sections 1-4 above), or the mutant proves nothing.
mutant() {
  local label=$1 expr=$2 fixture=$3 want=$4 needle=$5 out rc
  sed -E "$expr" "$GATE" > "$WORK/mut/m.sh"
  if cmp -s "$GATE" "$WORK/mut/m.sh"; then
    echo "FAIL: mutant '$label' did not change the gate"; fail=$((fail + 1)); return
  fi
  "$fixture"
  out="$(bash "$WORK/mut/m.sh" --root "$WORK/t" ${MARGS:-} 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ] || ! grep -qF -- "$needle" <<<"$out"; then
    echo "PASS: mutant killed — $label"; pass=$((pass + 1))
  else
    echo "FAIL: mutant survived — $label (exit $rc, still '$needle')"; fail=$((fail + 1))
  fi
}
fx_new() { clean_tree; plant docs/c.adoc <<<'Broken: link:nowhere.adoc[x]'; }
fx_stale() { clean_tree; ledger <<<'docs/a.adoc:1'; }
fx_grown() { clean_tree; plant docs/c.adoc <<<'Broken: link:n1.adoc[x] link:n2.adoc[y]'; ledger <<<'docs/c.adoc:1'; }
fx_lower() { clean_tree; plant docs/c.adoc <<<'Broken: link:n1.adoc[x]'; ledger <<<'docs/c.adoc:3'; }
fx_archive() {
  rm -rf "$WORK/t"; mkdir -p "$WORK/t/9-archive"
  printf 'Dead: link:gone.adoc[x]\n' > "$WORK/t/9-archive/a.adoc"
}
fx_md() { clean_tree; plant docs/c.md <<<'Broken: [x](nowhere.md)'; }

# Each kill reads: the mutant must NOT give the verdict the real gate gives
# (want-rc and needle describe the real verdict; surviving it is the failure).
mutant "archive exclusion removed" 's#-path \./9-archive -prune -o ##' fx_archive 0 "none new"
mutant "existence test always true" 's#if \[ -e "\$dir/\$target" \]; then continue; fi#if true; then continue; fi#' fx_new 1 "new broken link"
mutant "stale (gone) verdict dropped" 's#\[ -z "\$\{actual\[\$f\]:-\}" \] &&#false \&\&#' fx_stale 1 "no broken link left"
mutant "grown verdict dropped" 's#elif \[ "\$n" -gt "\$want" \]#elif false#' fx_grown 1 "GREW"
mutant "lowered verdict dropped" 's#elif \[ "\$n" -lt "\$want" \]#elif false#' fx_lower 1 "stale ledger entry"
mutant "Markdown links not scanned" 's#^    \*\.md\) awk#    *.mdx) awk#' fx_md 1 "new broken link"
fx_root() { clean_tree; plant docs/c.adoc <<<'Root-style: link:docs/target.adoc[x]'; }
fx_title() { clean_tree; plant docs/c.md <<<'A [t](target.adoc "A title").'; }
fx_img() { clean_tree; plant docs/c.adoc <<<'image::logo.png[Logo]'; }
fx_attr() { clean_tree; plant docs/c.adoc <<<$':base: gone.adoc\nSee link:{base}[x].'; }
fx_base() { base_repo 'docs/c.adoc:1' 'docs/c.adoc:2'; }
mutant "repo-root fallback restored" 's#if \[ -e "\$dir/\$target" \]; then#if [ -e "$dir/$target" ] || [ -e "$target" ]; then#' fx_root 1 "broken internal link"
mutant "Markdown title not split off" 's#else if \(c ~ /\[\[:space:\]\]/\) break#else if (0) break#' fx_title 0 "none new"
mutant "block image keeps its leading colon" 's#\)::\?#):#g' fx_img 0 "none new"
mutant "document attributes not expanded" 's#if \(!\(nm in attr\)\) break#break#' fx_attr 1 "gone.adoc"
fx_block() { clean_tree; plant docs/c.adoc <<<$'----\nlink:gone.adoc[x]\n----'; }
fx_fence() { clean_tree; plant docs/c.md <<<$'```\n[x](gone.md)\n```'; }
fx_idir() { clean_tree; mkdir -p "$WORK/t/docs/assets"; : > "$WORK/t/docs/assets/pic.svg"; plant docs/c.adoc <<<$':imagesdir: assets\nimage::pic.svg[P]'; }
fx_http() { clean_tree; plant docs/c.md <<<'A [g](http-guide.md).'; }
fx_paren() { clean_tree; : > "$WORK/t/docs/a(b).md"; plant docs/c.md <<<'A [u](a(b).md).'; }
mutant "AsciiDoc blocks not skipped" 's#^      blk \{ next \}#      #' fx_block 0 "none new"
mutant "Markdown fences not skipped" 's#^      fence \{ next \}#      #' fx_fence 0 "none new"
mutant ":imagesdir: ignored" 's#\("imagesdir" in attr\)#0#' fx_idir 0 "none new"
mutant "URL scheme matched by filename prefix" 's#\^\[A-Za-z\]\[A-Za-z0-9\+\.-\]\*:#^http#' fx_http 1 "http-guide.md"
mutant "parentheses not balanced" 's#if \(depth == 0\) break#if (1) break#' fx_paren 0 "none new"
fx_order() { clean_tree; plant docs/c.adoc <<<$':d: target.adoc\nlink:{d}[a]\n:d: gone.adoc\nlink:{d}[b]'; }
fx_span() { clean_tree; plant docs/c.md <<<'Write `[x](missing.md)` as an example.'; }
fx_esc() { clean_tree; : > "$WORK/t/docs/a)b.md"; plant docs/c.md <<<'An [ok](a\)b.md) link.'; }
fx_xref() { clean_tree; plant docs/c.adoc <<<'See xref:gone.adoc[x].'; }
mutant "first attribute definition wins" 's#else attr\[tag\] = v#else if (!(tag in attr)) attr[tag] = v#' fx_order 1 "gone.adoc"
mutant "inline code spans not skipped" 's#gsub\(/`\[\^`\]\*`/, "", s\)#s = s#' fx_span 0 "none new"
mutant "backslash escapes not honoured" 's#k < length\(s\)\) \{ k\+\+#0) { k++#' fx_esc 0 "none new"
mutant "xref macros not read" 's#kind == "xref" && m !~#kind == "xref" || m !~#' fx_xref 1 "gone.adoc"
fx_pass() { clean_tree; plant docs/c.adoc <<<'Show +link:gone.adoc[x]+ and pass:[link:gone3.adoc[z]].'; }
fx_pass2() { clean_tree; plant docs/c.adoc <<<'Show pass:[link:gone3.adoc[z]].'; }
fx_asc() { clean_tree; plant docs/c.asciidoc <<<'Broken: link:gone.adoc[x]'; }
fx_pct() { clean_tree; : > "$WORK/t/docs/a b.md"; plant docs/c.md <<<'An [ok](a%20b.md) link.'; }
mutant "+passthrough+ regions not skipped" '/\(link\|image\|xref\):\[/d' fx_pass 0 "none new"
mutant "pass:[] regions not skipped" 's#gsub\(/pass:#gsub(/NOPE:#' fx_pass2 0 "none new"
mutant ".asciidoc sources not scanned" 's#-o -name .\*\.asciidoc. ##' fx_asc 1 "c.asciidoc"
mutant "percent-decoding dropped" 's#if \[\[ "\$target" =~ %\[0-9A-Fa-f\]\[0-9A-Fa-f\] \]\]; then#if false; then#' fx_pct 0 "none new"
fx_ptarget() { clean_tree; plant docs/c.adoc <<<'See link:pass:[missing file.pdf][x].'; }
fx_fence4() { clean_tree; plant docs/c.md <<<$'````\n```\n[x](gone.md)\n````'; }
fx_bare() { clean_tree; plant docs/c.md <<<'This is not a link ](gone.md) at all.'; }
mutant "passthrough link targets not read" 's#(^ +while \(match\(s, /\(link\|image\|xref\)::\?)pass:#\1passX:#' fx_ptarget 1 "missing file.pdf"
mutant "passthrough stripped inside macros" 's#\\\[\(link\|image\|xref\):#\\[#' fx_ptarget 1 "missing file.pdf"
mutant "fence closes on any fence line" 's#substr\(run, 1, 1\) == fc && length\(run\) >= fl && ##' fx_fence4 0 "none new"
mutant "bracketless ]( parsed as a link" 's#if \(!opener\) continue##' fx_bare 0 "none new"
fx_escape() { clean_tree; : > "$WORK/outside.txt"; plant docs/c.adoc <<<'See link:../../outside.txt[x].'; }
fx_pescape() { clean_tree; : > "$WORK/outside.txt"; plant docs/c.md <<<'See [x](%2e%2e/%2e%2e/outside.txt).'; }
mutant "root containment dropped" 's#if inside_root "\$dir" "\$target"; then#if true; then#' fx_escape 1 "outside.txt"
mutant "root containment dropped for decoded paths" 's#inside_root "\$dir" "\$decoded" && ##' fx_pescape 1 "outside.txt"
fx_nl() { clean_tree; nm=$'docs/evil\n::error::pwned.adoc'; printf 'link:gone.adoc[x]\n' > "$WORK/t/$nm"; }
fx_pct2() { clean_tree; plant docs/c.adoc <<<'See link:a%0Ab.adoc[x].'; }
mutant "control characters not removed from paths" 's#"\$\{f//\[\[:cntrl:\]\]/\?\}" "\$\{target//\[\[:cntrl:\]\]/\?\}"#"$f" "$target"#' fx_nl 1 "evil?::error::pwned"
mutant "% not escaped in annotation data" 's#local s=\$\{1//%/%25\}#local s=$1#' fx_pct2 1 "a%250Ab"
MARGS="--base HEAD" mutant "base comparison dropped" 's#\[ "\$\{allowed\[\$f\]\}" -gt "\$b" \]#false#' fx_base 1 "ledger grew against base"

# ---------------------------------------------------------------- 6. this repo
out="$(bash "$GATE" --root "$REPO_ROOT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "PASS: this repository matches its ledger"; pass=$((pass + 1))
else echo "FAIL: this repository does not match its ledger"; printf '%s\n' "$out" | tail -15 | sed 's/^/      | /'; fail=$((fail + 1)); fi

rm -rf "$WORK/copy"; mkdir -p "$WORK/copy/not-the-usual-name"
tar -C "$REPO_ROOT" --exclude=.git -cf - . | tar -C "$WORK/copy/not-the-usual-name" -xf -
out="$(bash "$GATE" --root "$WORK/copy/not-the-usual-name" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "PASS: a copy under another name matches the same ledger"; pass=$((pass + 1))
else echo "FAIL: a copy under another name differs"; printf '%s\n' "$out" | tail -15 | sed 's/^/      | /'; fail=$((fail + 1)); fi

echo
echo "link-rot-guard-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
