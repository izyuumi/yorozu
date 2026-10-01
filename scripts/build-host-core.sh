#!/bin/sh
# Build the portable Rust backend used by the TypeScript compatibility host.
set -eu
cd "$(dirname "$0")/.."
cargo build --locked --manifest-path packages/host-core/Cargo.toml "$@"
