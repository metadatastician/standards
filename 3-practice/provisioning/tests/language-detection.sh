#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run with the host shell (including macOS /bin/bash 3.2); no installations.
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
engine="$root/templates/build/just/provision-lib.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/repository with spaces"
cd "$work/repository with spaces"
expect() {
  actual=$(PROVISION_ROOT="$PWD" "$BASH" "$engine" langs)
  [[ "$actual" == "$1" ]] || { printf 'expected <%s>, got <%s>\n' "$1" "$actual" >&2; exit 1; }
}
expect docs
touch Cargo.toml
expect rust
touch package.json
expect $'rust\nbun'
rm Cargo.toml
expect bun
rm package.json
expect docs
printf 'passed 5 language-detection controls\n'
