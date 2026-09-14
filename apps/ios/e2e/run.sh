#!/bin/bash
#
# End-to-end proof for the iOS app, and a test helper only — nothing here ships.
#
# Starts a relay, a fake OpenAI-compatible provider and the runtime sidecar, boots a throwaway
# iPhone simulator, installs the app, injects the sidecar's pairing string as a launch argument
# (the simulator has no camera), sends one message and asserts the streamed reply arrives.
# Then it kills the app and launches it again with no pairing string at all, to prove the
# phone rejoins the relay on its own and a message still round-trips. Finally it installs a
# rebuilt bundle over the same bundle id — an app update, as far as the device is concerned —
# and does it once more, which is what proves the pairing survives an update.
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
    for name in app app2 app3 sidecar relay provider device; do
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

# Only the fake provider, written before the sidecar starts. `--direct-provider` keeps this test
# pinned to it instead of sending the turn to whichever live OpenClaw gateway is on the machine.
mkdir -p "$WORK/state"
cat >"$WORK/state/providers.json" <<JSON
[{ "id": "openai", "kind": "openai-compat", "label": "Fake", "baseUrl": "http://127.0.0.1:$PROVIDER_PORT", "models": ["fake"], "enabled": true }]
JSON

YOROZU_RELAY_URL="ws://127.0.0.1:$RELAY_PORT" \
  YOROZU_STATE_DIR="$WORK/state" \
  YOROZU_BASE_URL="http://127.0.0.1:$PROVIDER_PORT" \
  YOROZU_API_KEY=fake \
  node "$ROOT/packages/runtime/dist/serve.js" --direct-provider >"$WORK/sidecar.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/sidecar.log" "^PAIR " "the pairing string"
PAIR=$(grep -m1 '^PAIR ' "$WORK/sidecar.log" | cut -c6-)

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

say "pairing, sending one message in a fresh draft, and again in a second thread"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuPair "$PAIR" -yorozuSend hi -yorozuThread Groceries >"$WORK/app.log" 2>&1 &
PIDS+=($!)
# The sidecar seeing `paired` proves the phone joined and its hello landed; the app seeing the
# reply proves the sealed round trip. Check both, nearest cause first.
wait_for "$WORK/sidecar.log" "^STATE paired" "the phone to pair" 45
# The first message goes in a draft thread, which exists only on the phone until it is sent:
# the reply coming back proves `thread_create` and the message that followed it both landed.
# It is still untitled while the reply streams, so the phone draws it as "New chat".
wait_for "$WORK/app.log" "YOROZU-E2E-REPLY \[New chat\] $REPLY" "the agent's reply in the draft" 45
# The fake provider's first turn calls `echo`: the phone logging it proves a tool call reaches
# the trace the drill-down draws, not just the message.
wait_for "$WORK/app.log" "YOROZU-E2E-TOOL echo" "the agent's tool call" 45
# The app also creates `Groceries` outright on pairing and sends the same message there:
# a named thread is created, synced and talked in end to end.
wait_for "$WORK/app.log" "YOROZU-E2E-REPLY \[Groceries\] $REPLY" "the reply in the new thread" 45

say "killing the app and launching it again with no pairing string"
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
# No -yorozuPair this time: the phone has only what it persisted. Its one-time token is spent,
# so joining at all means it rejoined the relay against the nonce as a device the room knows.
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuSend "hi again" >"$WORK/app2.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app2.log" "YOROZU-E2E paired" "the phone to rejoin without a token" 45
# Any title: the relaunch sends in a fresh draft, which the runtime auto-titles from the reply
# it is still streaming, so which of the two names the line carries is a race and not the point.
wait_for "$WORK/app2.log" "YOROZU-E2E-REPLY \[.*\] $REPLY" "a reply after the relaunch" 45

say "reinstalling a rebuilt app over the paired one, as a TestFlight update does"
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
# The same bundle id installed over itself is what an update is on the simulator, and the
# nearest thing to TestFlight there is: the data container and the Keychain stay, the bundle
# is replaced. The rebuild is incremental and usually a no-op; it is here so what gets
# installed is a freshly produced bundle rather than the very bytes already on the device.
xcodebuild build \
  -workspace "$IOS/Yorozu.xcworkspace" \
  -scheme YorozuIOS \
  -destination "id=$UDID" \
  -derivedDataPath "$WORK/dd" >>"$WORK/xcodebuild.log" 2>&1 ||
  { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/YorozuIOS.app"
# Again with no pairing string: everything it needs is in the Keychain, which the install did
# not touch, and the thread cache is in Application Support, which it did not touch either.
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuSend "hi after the update" >"$WORK/app3.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app3.log" "YOROZU-E2E paired" "the phone to rejoin after reinstalling" 45
wait_for "$WORK/app3.log" "YOROZU-E2E-REPLY \[.*\] $REPLY" "a reply after the reinstall" 45

say "PASS — the phone received:"
grep -m2 'YOROZU-E2E-REPLY' "$WORK/app.log"
grep -m1 'YOROZU-E2E-TOOL' "$WORK/app.log"
grep -m1 'YOROZU-E2E-REPLY' "$WORK/app2.log"
grep -m1 'YOROZU-E2E-REPLY' "$WORK/app3.log"
grep '^STATE ' "$WORK/sidecar.log"
