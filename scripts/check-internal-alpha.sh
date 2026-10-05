#!/bin/sh
# Only independent secretary fixtures; never the paused recovery/FIFO suites.
set -eu
cd "$(dirname "$0")/.."
# Darwin Unix-domain sockets have a short path limit; hosted runner TMPDIR
# plus fixture names exceeds it. Keep all fixtures task-isolated under /tmp.
TMPDIR=$(mktemp -d /tmp/yri.XXXXXX)
export TMPDIR
SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/yorozu-internal-check.XXXXXX")
python3 scripts/stage-internal-alpha.py "$SOURCE"
cd "$SOURCE"
pnpm install --frozen-lockfile
pnpm --filter @yorozu/shared --filter @yorozu/runtime build
# Receipts are emitted only after every explicitly selected test passes.
RECEIPTS=${YOROZU_INTERNAL_RECEIPTS:-$SOURCE}
mkdir -p "$RECEIPTS"
rm -f "$RECEIPTS/internal-host.json" "$RECEIPTS/internal-swift.json"
python3 scripts/test-check-internal-host.py
python3 scripts/check-internal-host.py --receipt "$RECEIPTS/internal-host.json"
cargo build --locked --manifest-path packages/host-core/Cargo.toml --bin yorozu-host-core
export YOROZU_SECRETARY_HOST="$SOURCE/packages/host-core/target/debug/yorozu-alpha-host"
export YOROZU_HOST_CORE="$SOURCE/packages/host-core/target/debug/yorozu-host-core"
pnpm --filter @yorozu/runtime exec vitest run secretary- --maxWorkers=2
pnpm --filter @yorozu/runtime exec vitest run harness agent- person-agent- curated-agent- packaged-agent- siwc- native-account- --maxWorkers=2
python3 scripts/test-package-hermes-runtime.py
python3 scripts/test-hermes-release-provenance.py
python3 scripts/test-hermes-public-archive-provenance.py
python3 scripts/package-accounts-helper.test.py
node --test packages/harness-plugins/hermes/adapter.test.mjs packages/harness-plugins/openclaw/adapter.test.mjs
pnpm --filter @yorozu/shared exec vitest run person-agents peer-info siwc-
# These are isolated persistence/wire fixtures, not the legacy recovery/UI harness.
# Keep internal release admission dependent on executed outbox regression tests.
python3 scripts/test-check-internal-swift.py
env -u SDKROOT python3 scripts/check-internal-swift.py --receipt "$RECEIPTS/internal-swift.json"
env -u SDKROOT swift build --package-path apps/mac --product YorozuMac
echo "Internal secretary checks passed for $(python3 -c 'import json; print(json.load(open("internal-source.json"))["sourceSha"])')"
