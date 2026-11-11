#!/usr/bin/env bash
# Checks for the Windows client's Rust core. Run from anywhere: bash apps/windows/ci/core.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== snow transport mode"
if grep -rnE 'into_transport_mode|into_stateless_transport_mode' core/src; then
  echo "the core uses snow only for the handshake (spec section 4)" >&2
  exit 1
fi

echo "== no aws-lc-rs"
# cargo exits non-zero when no package matches; any other failure must not pass silently.
if tree_err=$(cargo tree --workspace -i aws-lc-rs 2>&1 >/dev/null); then
  echo "aws-lc-rs is in the dependency tree; it must not be" >&2
  exit 1
elif ! grep -q 'did not match any packages' <<<"$tree_err"; then
  printf 'cargo tree failed:\n%s\n' "$tree_err" >&2
  exit 1
fi

echo "== fmt"
cargo fmt --all --check

echo "== clippy"
cargo clippy --workspace --exclude yorozu-windows --all-targets --features yorozu-core/insecure-plaintext-store -- -D warnings

echo "== test"
# The Tauri crate (yorozu-windows) needs WebView2; app.ps1 builds it on Windows from W1.
# Until then cargo only warns that the excluded package doesn't exist.
cargo test --workspace --exclude yorozu-windows --features yorozu-core/insecure-plaintext-store

echo "== conformance"
# The client's expectations of the real Node relay (pnpm install --filter @yorozu/relay first).
node --test conformance/host/*.test.ts

echo "== commit-type tests"
bash ci/commit-type.test.sh
