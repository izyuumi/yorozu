#!/usr/bin/env bash
# Checks for the Windows client's Rust core. Run from anywhere: bash apps/windows/ci/core.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== snow transport mode"
code=0
grep -rnE 'into_transport_mode|into_stateless_transport_mode' core/src || code=$?
case $code in
  0) echo "the core must use snow only for the Noise handshake, never its transport mode" >&2; exit 1 ;;
  1) ;;
  *) echo "grep failed" >&2; exit 1 ;;
esac

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
# cargo warns that the excluded package does not exist, only until W1 adds it.
cargo test --workspace --exclude yorozu-windows --features yorozu-core/insecure-plaintext-store

echo "== probe"
cargo build -p yorozu-probe --features yorozu-core/insecure-plaintext-store
export YOROZU_PROBE_BIN="$(pwd)/target/debug/yorozu-probe"

echo "== conformance"
# The client's expectations of the real Node relay (pnpm install --filter @yorozu/relay first).
node --test --test-timeout=60000 conformance/host/*.test.ts

echo "== commit-type tests"
bash ci/commit-type.test.sh
