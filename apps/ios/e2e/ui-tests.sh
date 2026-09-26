#!/bin/bash
#
# Runs the iOS UI tests (scheme YorozuUITests) on a throwaway iPhone simulator, with the wire
# harness up so ConnectionTests drive the real relay and Mac sidecar. The same run locally and
# in CI (.github/workflows/ui-tests.yml). Test-only; nothing here ships.
#
# Usage: apps/ios/e2e/ui-tests.sh [xcodebuild test options, e.g. -only-testing:YorozuUITests/ConnectionTests]
# Results: apps/ios/e2e/.ui/results.xcresult and harness.log, kept for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
IOS="$ROOT/apps/ios"
DEVICE_TYPE=${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
OUT="$IOS/e2e/.ui"
rm -rf "$OUT"
mkdir -p "$OUT"
UDID=""
HARNESS=""

cleanup() {
  local status=$?
  [ -n "$HARNESS" ] && kill "$HARNESS" 2>/dev/null || true
  if [ -n "$UDID" ]; then
    # The app's own log dies with the simulator, and on failure it is the other half of the story.
    [ "$status" -ne 0 ] && xcrun simctl spawn "$UDID" log show --last 30m --style compact \
      --predicate 'subsystem == "to.yumi.yorozu"' >"$OUT/device.log" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> build the relay and sidecar"
(cd "$ROOT" && pnpm -r build >/dev/null)

echo "==> start the wire harness"
# Held open on a fifo: the harness stops when its stdin closes, which is the trap's kill here.
mkfifo "$OUT/stdin"
node "$ROOT/packages/runtime/test-support/wire-harness.mjs" <"$OUT/stdin" >"$OUT/ready" 2>"$OUT/harness.log" &
HARNESS=$!
exec 3>"$OUT/stdin"
for _ in $(seq 1 100); do [ -s "$OUT/ready" ] && break; sleep 0.1; done
PORT=$(sed -E 's/.*"control":([0-9]+).*/\1/' "$OUT/ready")
[ -n "$PORT" ] || { echo "the harness did not start; see $OUT/harness.log" >&2; exit 1; }

echo "==> build for testing"
# Signed ad hoc rather than not at all: without its entitlements the app cannot reach the
# Keychain, where pairings live, and it needs no certificate that CI would have to hold.
(cd "$ROOT" && tuist generate --no-open --path apps/ios >/dev/null)
UDID=$(xcrun simctl create yorozu-ui-tests "$DEVICE_TYPE")
xcodebuild build-for-testing \
  -workspace "$IOS/Yorozu.xcworkspace" -scheme YorozuUITests \
  -destination "id=$UDID" -derivedDataPath "$OUT/dd" \
  -skipPackagePluginValidation -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=

echo "==> test"
# TEST_RUNNER_ variables reach the test process without the prefix.
TEST_RUNNER_YOROZU_RIG="http://127.0.0.1:$PORT" xcodebuild test-without-building \
  -workspace "$IOS/Yorozu.xcworkspace" -scheme YorozuUITests \
  -destination "id=$UDID" -derivedDataPath "$OUT/dd" \
  -resultBundlePath "$OUT/results.xcresult" "$@"
