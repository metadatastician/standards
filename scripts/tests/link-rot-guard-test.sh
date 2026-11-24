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
#   5. the suite sees a regression: eleven mutants of the gate are killed;
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
mutant "Markdown links not scanned" 's#\*\.md\)   grep#*.mdx) grep#' fx_md 1 "new broken link"
fx_root() { clean_tree; plant docs/c.adoc <<<'Root-style: link:docs/target.adoc[x]'; }
fx_title() { clean_tree; plant docs/c.md <<<'A [t](target.adoc "A title").'; }
fx_img() { clean_tree; plant docs/c.adoc <<<'image::logo.png[Logo]'; }
fx_attr() { clean_tree; plant docs/c.adoc <<<$':base: target.adoc\nSee link:{base}[x].'; }
fx_base() { base_repo 'docs/c.adoc:1' 'docs/c.adoc:2'; }
mutant "repo-root fallback restored" 's#if \[ -e "\$dir/\$target" \]; then#if [ -e "$dir/$target" ] || [ -e "$target" ]; then#' fx_root 1 "broken internal link"
mutant "Markdown title not split off" 's#^      target=\$\(strip_title "\$target"\)#      target=$target#' fx_title 0 "none new"
mutant "block image keeps its leading colon" 's#\)::\?#):#g' fx_img 0 "none new"
mutant "document attributes not expanded" 's#target=\$\(resolve_attrs "\$f" "\$target"\) \|\| continue#:#' fx_attr 0 "none new"
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
