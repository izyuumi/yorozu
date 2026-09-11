#!/bin/bash
#
# End-to-end proof for the iOS app, and a test helper only — nothing here ships.
#
# Starts a relay, a fake OpenAI-compatible provider and the runtime sidecar, boots a throwaway
# iPhone simulator, installs the app, injects the sidecar's pairing QR as a launch argument
# (the simulator has no camera), sends one message and asserts the streamed reply arrives.
#
# Usage: apps/ios/e2e/run.sh     — logs are kept in apps/ios/e2e/.logs for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
IOS="$ROOT/apps/ios"
BUNDLE_ID=to.yumi.yorozu.ios
DEVICE_TYPE=${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
RELAY_PORT=${RELAY_PORT:-8791}
PROVIDER_PORT=${PROVIDER_PORT:-8799}
REPLY=${REPLY:-"hello from the fake model"}

# A fixed directory, not a mktemp one: on failure the logs are the only evidence there is.
WORK="$IOS/e2e/.logs"
rm -rf "$WORK"
mkdir -p "$WORK"
UDID=""
PIDS=()

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf '\n==> FAILED — logs kept in %s\n' "$WORK" >&2
    if [ -n "$UDID" ]; then
      xcrun simctl spawn "$UDID" log show --last 5m --style compact \
        --predicate 'process == "YorozuIOS"' >"$WORK/device.log" 2>/dev/null || true
    fi
    for name in app sidecar relay provider device; do
      [ -s "$WORK/$name.log" ] || continue
      printf '\n--- %s.log ---\n' "$name" >&2
      tail -30 "$WORK/$name.log" >&2
    done
  fi
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

say() { printf '\n==> %s\n' "$1"; }

# Waits for a file to contain a pattern, so no step depends on a fixed sleep.
wait_for() {
  local file=$1 pattern=$2 label=$3 seconds=${4:-60}
  for _ in $(seq "$seconds"); do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 1
  done
  echo "timed out waiting for $label" >&2
  return 1
}

say "building TypeScript workspaces"
pnpm -C "$ROOT" -r build >/dev/null

say "starting relay, fake provider and sidecar"
PORT=$RELAY_PORT node "$ROOT/apps/relay/dist/index.js" >"$WORK/relay.log" 2>&1 &
PIDS+=($!)
PORT=$PROVIDER_PORT REPLY="$REPLY" node "$IOS/e2e/fake-provider.mjs" >"$WORK/provider.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/relay.log" "relay listening" "the relay"

YOROZU_RELAY_URL="ws://127.0.0.1:$RELAY_PORT" \
  YOROZU_STATE_DIR="$WORK/state" \
  YOROZU_BASE_URL="http://127.0.0.1:$PROVIDER_PORT" \
  YOROZU_API_KEY=fake \
  node "$ROOT/packages/runtime/dist/serve.js" >"$WORK/sidecar.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/sidecar.log" "^QR " "the pairing QR"
QR=$(grep -m1 '^QR ' "$WORK/sidecar.log" | cut -c4-)

say "generating and building the app"
tuist generate --no-open --path "$IOS" >/dev/null
UDID=$(xcrun simctl create yorozu-e2e "$DEVICE_TYPE")
# Signed, unlike CI's compile-only build: ad-hoc simulator signing is what gives the app its
# application-identifier entitlement, and the Keychain fails with -34018 (errSecMissingEntitlement)
# without one. It needs no developer account.
xcodebuild build \
  -workspace "$IOS/Yorozu.xcworkspace" \
  -scheme YorozuIOS \
  -destination "id=$UDID" \
  -derivedDataPath "$WORK/dd" >"$WORK/xcodebuild.log" 2>&1 ||
  { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }

say "booting the simulator and installing"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/YorozuIOS.app"

say "pairing and sending one message"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuPair "$QR" -yorozuSend hi >"$WORK/app.log" 2>&1 &
PIDS+=($!)
# The sidecar seeing `paired` proves the phone joined and its hello landed; the app seeing the
# reply proves the sealed round trip. Check both, nearest cause first.
wait_for "$WORK/sidecar.log" "^STATE paired" "the phone to pair" 45
wait_for "$WORK/app.log" "YOROZU-E2E-REPLY $REPLY" "the agent's reply" 45
# The fake provider's first turn calls `echo`: the phone logging it proves a tool call reaches
# the trace the drill-down draws, not just the message.
wait_for "$WORK/app.log" "YOROZU-E2E-TOOL echo" "the agent's tool call" 45

say "PASS — the phone received: $(grep -m1 'YOROZU-E2E-REPLY' "$WORK/app.log")"
grep -m1 'YOROZU-E2E-TOOL' "$WORK/app.log"
grep '^STATE ' "$WORK/sidecar.log"
