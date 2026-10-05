#!/bin/sh
# Only independent secretary fixtures; never the paused recovery/FIFO suites.
set -eu
cd "$(dirname "$0")/.."
SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/yorozu-internal-check.XXXXXX")
python3 scripts/stage-internal-alpha.py "$SOURCE"
cd "$SOURCE"
pnpm install --frozen-lockfile
pnpm --filter @yorozu/shared --filter @yorozu/runtime build
cargo test --locked --manifest-path packages/host-core/Cargo.toml --test alpha
cargo test --locked --manifest-path packages/host-core/Cargo.toml --test secretary
cargo build --locked --manifest-path packages/host-core/Cargo.toml --bin yorozu-host-core
export YOROZU_SECRETARY_HOST="$SOURCE/packages/host-core/target/debug/yorozu-alpha-host"
export YOROZU_HOST_CORE="$SOURCE/packages/host-core/target/debug/yorozu-host-core"
pnpm --filter @yorozu/runtime exec vitest run secretary- --maxWorkers=2
pnpm --filter @yorozu/runtime exec vitest run harness agent- person-agent- curated-agent- packaged-agent- siwc- native-account- --maxWorkers=2
python3 scripts/test-package-hermes-runtime.py
python3 scripts/package-accounts-helper.test.py
node --test packages/harness-plugins/hermes/adapter.test.mjs packages/harness-plugins/openclaw/adapter.test.mjs
pnpm --filter @yorozu/shared exec vitest run person-agents peer-info siwc-
# These are isolated persistence/wire fixtures, not the legacy recovery/UI harness.
# Keep internal release admission dependent on executed outbox regression tests.
env -u SDKROOT swift test --package-path packages/shared-swift --filter 'OutboxTests|HarnessPlatformTests|PersonAgentsTests|PersonAgentEditingTests'
env -u SDKROOT swift build --package-path apps/mac --product YorozuMac
echo "Internal secretary checks passed for $(python3 -c 'import json; print(json.load(open("internal-source.json"))["sourceSha"])')"
