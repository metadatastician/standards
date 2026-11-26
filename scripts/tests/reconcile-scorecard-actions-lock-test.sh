#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The Scorecard native-lock reconciler and its tests live in
# tools/scorecard-lock-reconcile (Rust; the Ruby version is retired).
set -euo pipefail
cargo test --quiet --locked --manifest-path "$(dirname "$0")/../../tools/scorecard-lock-reconcile/Cargo.toml"
