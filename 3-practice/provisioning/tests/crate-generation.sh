#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the actual generator with controlled importer failures, without network.
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
engine="${1:-$root/templates/build/just/provision-lib.sh}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/repository with spaces/build/guix" "$work/bin"
cat > "$work/bin/guix-control" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
lock=${3#--lockfile=}
if grep -q $'\r' "$lock"; then exit 88; fi
printf '(define rust-a-1.0\n  (crate-source "a" "1.0" "fixture"))\n'
case "${IMPORT_MODE:-good}" in
  missing) exit 0 ;;
  duplicate) printf '(define rust-a-1.0\n  (crate-source "a" "1.0" "fixture"))\n' ;;
  *) printf '(define rust-b-1.0\n  (crate-source "b" "1.0" "fixture"))\n' ;;
esac
if [ "${IMPORT_MODE:-good}" = failed ]; then exit 17; fi
STUB
chmod +x "$work/bin/guix-control"
export PATH="$work/bin:$PATH" GUIX=guix-control
cd "$work/repository with spaces"
printf 'version = 4\r\n[[package]]\r\nname = "a"\r\nsource = "registry+https://github.com/rust-lang/crates.io-index"\r\n[[package]]\r\nname = "b"\r\nsource = "git+https://example.invalid/b#0123456789012345678901234567890123456789"\r\n' > Cargo.lock
cp Cargo.lock "$work/original-lock"
printf ';; SPDX-License-Identifier: MPL-2.0\n' > guix.scm
run() { PROVISION_ROOT="$PWD" "$BASH" "$engine" crates-scm; }
run
grep -q 'rust-b-1.0' build/guix/crates.scm
cmp Cargo.lock "$work/original-lock"
cp build/guix/crates.scm "$work/previous"
for mode in failed missing duplicate; do
  if IMPORT_MODE="$mode" run; then echo "accepted broken importer: $mode" >&2; exit 1; fi
  cmp build/guix/crates.scm "$work/previous"
done
rm build/guix/crates.scm
mkdir build/guix/crates.scm
if run; then echo 'accepted a directory as output file' >&2; exit 1; fi
rmdir build/guix/crates.scm
printf 'version = 4\n[[package]]\nname = "local"\nversion = "1.0.0"\n' > Cargo.lock
run
grep -q '(list))' build/guix/crates.scm
printf 'passed 6 crate-generation controls\n'
