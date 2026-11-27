#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The estate Guix channel: idris2 is a Guix spec (not a gap), the canon channels.scm
# passes the stub gate, a channel without its own pin fails it, and re-pinning moves
# only the `guix` channel. Needs no Guix and no network.
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
engine="$root/templates/build/just/provision-lib.sh"
canon="$root/templates/guix/channels.scm"
work=$(mktemp -d)
mkdir -p "$work"/{unpinned,no-estate,badintro,badfpr,commentonly,guixonly,nog}
trap 'rm -rf -- "$work"' EXIT
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir "$work/repository with spaces"; cd "$work/repository with spaces"
touch pack.ipkg
specs=$(PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-specs)
case " $specs " in *" idris2 "*) ;; *) die "guix-specs lacks idris2: $specs" ;; esac
gaps=$(PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-gaps)
case "$gaps" in *idris2*) die "idris2 still listed as a Guix gap: $gaps" ;; esac
# The canon channels.scm: both channels pinned, estate introduction present.
PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-stub "$canon" || die "canon channels.scm rejected"
grep -q 'name .estate' "$canon" || die "canon lacks the estate channel"
grep -q 'E0B3 6C1B 28F6 E9E0 A460  3F47 FE6E 34E9 F311 0F92' "$canon" || die "estate fingerprint missing"
# A second channel with no commit pin must fail the gate.
awk '/d4c84bde7a728a4a5bbc6bf865ed45e983d01c6d"\)$/ && !d { d = 1; next } { print }' "$canon" > "$work/unpinned/channels.scm"
! grep -q '(commit "d4c8' "$work/unpinned/channels.scm" || die "test setup: pin not removed"
if PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-stub "$work/unpinned/channels.scm" >/dev/null; then die "unpinned estate channel accepted"; fi
# Re-pin: only the guix channel moves.
eval "$(awk '/^guix_channel_commit\(\)/,/^}/' "$engine")"
eval "$(awk '/^repin_guix_channel\(\)/,/^}/' "$engine")"
cp "$canon" "$work/c.scm"
new=0123456789abcdef0123456789abcdef01234567
repin_guix_channel "$work/c.scm" "$new" || die "repin failed"
[ "$(guix_channel_commit < "$work/c.scm")" = "$new" ] || die "guix pin not moved"
grep -q "(commit \"d4c84bde7a728a4a5bbc6bf865ed45e983d01c6d\")" "$work/c.scm" || die "estate pin moved"
# A guix channel with no commit must not re-pin the estate channel in its place.
awk '/ae77aeb9543de2661d739104bc4d3803d8c6f38b/ { next } { print }' "$canon" > "$work/nog/channels.scm"
cp "$work/nog/channels.scm" "$work/nog.before"
if repin_guix_channel "$work/nog/channels.scm" "$new"; then die "repinned a file with no guix commit"; fi
cmp -s "$work/nog/channels.scm" "$work/nog.before" || die "file changed on failed repin"
[ -z "$(guix_channel_commit < "$work/nog/channels.scm")" ] || die "read the estate commit as the guix pin"
# Hardened gate: an idris2-only repository must name the estate channel and carry its
# introduction commit and fingerprint (positive above; negatives here).
gate() { PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-stub "$1" 2>&1; }
no_estate="$work/no-estate/channels.scm"
awk '/^      \(channel$/ { skip = 1 } !skip { print } END {}' "$canon" | sed '$ s/$/)/' > "$no_estate"
# drop the estate channel but keep the guix one (balanced closing paren appended above)
if gate "$no_estate" >/dev/null; then die "idris2-only repo accepted without the estate channel"; fi
why=$(gate "$no_estate" || true)
case "$why" in *"no estate channel"*) ;; *) die "wrong reason without estate channel: $why" ;; esac
sed 's/4b91d37a4bbb4bc8c16de791eb5bd2241fb26f4b"$/0000000000000000000000000000000000000000"/' "$canon" > "$work/badintro/channels.scm"
if gate "$work/badintro/channels.scm" >/dev/null; then die "wrong introduction commit accepted"; fi
sed 's/E0B3 6C1B 28F6 E9E0 A460  3F47 FE6E 34E9 F311 0F92/0000 0000 0000 0000 0000  0000 0000 0000 0000 0000/' "$canon" > "$work/badfpr/channels.scm"
if gate "$work/badfpr/channels.scm" >/dev/null; then die "wrong fingerprint accepted"; fi
# A comment naming the estate channel must not satisfy the gate.
{ grep -v 'estate' "$canon" | grep -v 'E0B3' ; echo ';; (name (quote estate)) 4b91d37a4bbb4bc8c16de791eb5bd2241fb26f4b'; } > "$work/commentonly/channels.scm" || true
if gate "$work/commentonly/channels.scm" >/dev/null; then die "comment satisfied the estate gate"; fi
# Other repositories are not affected: rust-only accepts a guix-only channels.scm.
mkdir "$work/rust" && cd "$work/rust" && touch Cargo.toml
awk '/^      \(channel$/ { skip = 1 } !skip { print }' "$canon" | sed '$ s/$/)/' > "$work/guixonly/channels.scm"
PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-stub "$work/guixonly/channels.scm" || die "rust repo rejected a guix-only channels.scm"
# Deed as the single source of truth: gaps follow :guix-gaps; built-in values equal the deed.
mkdir "$work/gl" && cd "$work/gl" && touch gleam.toml package.json
real=$(PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-gaps)
[ "$real" = "gleam, bun deno pnpm" ] || die "unexpected gaps from canon deed: $real"
deed="$root/provisioning-standard_praxis.deed"
sed 's/:guix-gaps      ("gleam" "bun" "deno" "pnpm" "lychee" "julia")/:guix-gaps      ("bun" "pnpm" "lychee" "julia" "idris2")/' "$deed" > "$work/mod.deed"
cmp -s "$deed" "$work/mod.deed" && die "test setup: deed not modified"
changed=$(PROVISION_STANDARD_DEED="$work/mod.deed" PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-gaps)
[ "$changed" = "bun pnpm" ] || die "deed change did not change computed gaps: $changed"
touch "$work/gl/x.ipkg"
idr=$(PROVISION_STANDARD_DEED="$work/mod.deed" PROVISION_ROOT="$PWD" "$BASH" "$engine" guix-gaps)
case "$idr" in *idris2*) ;; *) die "idris2 added to the deed list is not a gap: $idr" ;; esac
# The channel constants in channels.scm agree with the deed.
for k in introduction fingerprint pin; do
  v=$(grep -oE "^[[:space:]]*:guix-estate-${k}[[:space:]]+\"[^\"]*\"" "$deed" | sed -E 's/^[^"]*"//; s/"$//')
  [ -n "$v" ] || die "deed lacks :guix-estate-$k"
  grep -qF "\"$v\"" "$canon" || die "canon channels.scm does not carry deed :guix-estate-$k"
done
printf 'passed 22 guix-estate-channel controls\n'
