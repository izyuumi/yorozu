#!/bin/sh
# Only independent secretary fixtures; never the paused recovery/FIFO suites.
set -eu
cd "$(dirname "$0")/.."
SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/yorozu-internal-check.XXXXXX")
python3 scripts/stage-internal-alpha.py "$SOURCE"
cd "$SOURCE"
pnpm install --frozen-lockfile
pnpm --filter @yorozu/shared --filter @yorozu/runtime build
pnpm --filter @yorozu/runtime exec vitest run secretary- --maxWorkers=2
cargo test --locked --manifest-path packages/host-core/Cargo.toml --test alpha
env -u SDKROOT swift build --package-path apps/mac --product YorozuMac
echo "Internal secretary checks passed for $(python3 -c 'import json; print(json.load(open("internal-source.json"))["sourceSha"])')"
