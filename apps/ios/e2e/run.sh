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
PROXY_PORT=${PROXY_PORT:-8792}
PROVIDER_PORT=${PROVIDER_PORT:-8799}
SECOND_PROVIDER_PORT=${SECOND_PROVIDER_PORT:-8800}
REPLY=${REPLY:-"hello from the fake model"}
SECOND_REPLY="hello from the second Mac"

# A fixed directory, not a mktemp one: on failure the logs are the only evidence there is.
WORK="$IOS/e2e/.logs"
DERIVED_DATA=${YOROZU_E2E_DERIVED_DATA:-"$WORK/dd"}
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
      xcrun simctl io "$UDID" screenshot "$WORK/failure.png" >/dev/null 2>&1 || true
    fi
    for name in app app2 app3 app-fault app-recovered app4 app5 sidecar sidecar2 relay proxy provider provider2 device; do
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

wait_for_transcript() {
  local pattern=$1 label=$2 seconds=${3:-60}
  for _ in $(seq "$seconds"); do
    grep -q "$pattern" "$WORK/state/transcripts/"*.jsonl 2>/dev/null && return 0
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
PORT=$PROXY_PORT UPSTREAM="ws://127.0.0.1:$RELAY_PORT" DROP_FILE="$WORK/drop-host-frames" \
  node "$IOS/e2e/relay-fault-proxy.mjs" >"$WORK/proxy.log" 2>&1 &
PIDS+=($!)
PORT=$PROVIDER_PORT REPLY="$REPLY" FAULT_FILE="$WORK/fault-provider" RELEASE_FILE="$WORK/release-provider" \
  node "$IOS/e2e/fake-provider.mjs" >"$WORK/provider.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/relay.log" "relay listening" "the relay"
wait_for "$WORK/proxy.log" "fault proxy listening" "the phone proxy"

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
PAIR=$(node -e 'const pair = new URL(process.argv[1]); pair.searchParams.set("relay", process.argv[2]); console.log(String(pair))' \
  "$PAIR" "ws://127.0.0.1:$PROXY_PORT")

say "generating and building the app"
tuist generate --no-open --path "$IOS" >/dev/null
# Pin a runtime when checking a specific OS; otherwise preserve simctl's installed default.
if [ -n "${SIMULATOR_RUNTIME:-}" ]; then
  UDID=$(xcrun simctl create yorozu-e2e "$DEVICE_TYPE" "$SIMULATOR_RUNTIME")
else
  UDID=$(xcrun simctl create yorozu-e2e "$DEVICE_TYPE")
fi
# Signed, unlike CI's compile-only build: ad-hoc simulator signing is what gives the app its
# application-identifier entitlement, and the Keychain fails with -34018 (errSecMissingEntitlement)
# without one. It needs no developer account.
xcodebuild build \
  -workspace "$IOS/Yorozu.xcworkspace" \
  -scheme YorozuIOS \
  -skipPackagePluginValidation \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" >"$WORK/xcodebuild.log" 2>&1 ||
  { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }

say "booting the simulator and installing"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/YorozuIOS.app"

say "pairing, sending one message in a fresh draft, and again in a second thread"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuPair "$PAIR" -yorozuSend hi -yorozuThread Groceries >"$WORK/app.log" 2>&1 &
PIDS+=($!)
# The sidecar seeing `paired` proves the phone joined and its hello landed; the app seeing the
# reply proves the sealed round trip. Check both, nearest cause first.
wait_for "$WORK/sidecar.log" "^STATE paired" "the phone to pair" 45
# The first message goes in a draft thread, which exists only on the phone until it is sent:
# the reply coming back proves `thread_create` and the message that followed it both landed.
# Match the draft's identity: its automatic title may arrive before or after the reply.
wait_for "$WORK/app.log" "YOROZU-E2E-DRAFT-REPLY $REPLY" "the agent's reply in the draft" 45
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
  -skipPackagePluginValidation \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" >>"$WORK/xcodebuild.log" 2>&1 ||
  { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }
xcrun simctl install "$UDID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/YorozuIOS.app"
# Again with no pairing string: everything it needs is in the Keychain, which the install did
# not touch, and the thread cache is in Application Support, which it did not touch either.
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuSend "hi after the update" >"$WORK/app3.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app3.log" "YOROZU-E2E paired" "the phone to rejoin after reinstalling" 45
wait_for "$WORK/app3.log" "YOROZU-E2E-REPLY \[.*\] $REPLY" "a reply after the reinstall" 45

say "dropping host confirmations, killing phone, then recovering finished work"
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
previous_requests=$(grep -c '^request ' "$WORK/provider.log")
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuSend fault-path-question -yorozuSendInFirstThread yes -yorozuSendDelayMs 3000 \
  >"$WORK/app-fault.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app-fault.log" "YOROZU-E2E paired" "the phone to rejoin before the fault" 45
touch "$WORK/drop-host-frames" "$WORK/fault-provider"
wait_for "$WORK/provider.log" "^request $((previous_requests + 1))$" "host execution after the lost receipt" 45
wait_for "$WORK/app-fault.log" "YOROZU-E2E-DELIVERY confirming" "uncertain delivery state" 20
if grep -q 'finished after disconnect' "$WORK/state/transcripts/"*.jsonl 2>/dev/null; then
  echo "host finished before the phone was terminated" >&2
  exit 1
fi
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
touch "$WORK/release-provider"
wait_for_transcript 'finished after disconnect' "host completion while phone is dead" 45
test "$(grep -c '^request ' "$WORK/provider.log")" -eq "$((previous_requests + 1))"
test "$(grep -c 'dropped host frame' "$WORK/proxy.log")" -gt 0
rm "$WORK/drop-host-frames" "$WORK/fault-provider" "$WORK/release-provider"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuObserve yes >"$WORK/app-recovered.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app-recovered.log" 'YOROZU-E2E-FINAL .*finished after disconnect.*pending=0' "completed answer and reconciled outbox after relaunch" 45
test "$(grep -c '^request ' "$WORK/provider.log")" -eq "$((previous_requests + 1))"
node - "$WORK/state/transcripts" <<'JS'
const fs = require('node:fs');
const events = fs.readdirSync(process.argv[2]).filter(name => name.endsWith('.jsonl'))
  .flatMap(name => fs.readFileSync(`${process.argv[2]}/${name}`, 'utf8').trim().split('\n').map(JSON.parse));
const messages = events.filter(event => event.kind === 'message' && event.data.role === 'user' && event.data.text === 'fault-path-question');
if (messages.length !== 1) throw new Error(`fault request recorded ${messages.length} times`);
const answers = events.filter(event => event.threadId === messages[0].threadId && event.kind === 'message' && event.data.role === 'agent' && event.data.done && event.data.text.includes('finished after disconnect'));
if (answers.length !== 1) throw new Error(`fault answer recorded ${answers.length} times`);
JS

say "adding a second host without replacing the first"
PORT=$SECOND_PROVIDER_PORT REPLY="$SECOND_REPLY" node "$IOS/e2e/fake-provider.mjs" >"$WORK/provider2.log" 2>&1 &
PIDS+=($!)
mkdir -p "$WORK/state2"
cat >"$WORK/state2/providers.json" <<JSON
[{ "id": "openai", "kind": "openai-compat", "label": "Second fake", "baseUrl": "http://127.0.0.1:$SECOND_PROVIDER_PORT", "models": ["fake"], "enabled": true }]
JSON
YOROZU_RELAY_URL="ws://127.0.0.1:$RELAY_PORT" \
  YOROZU_STATE_DIR="$WORK/state2" \
  YOROZU_BASE_URL="http://127.0.0.1:$SECOND_PROVIDER_PORT" \
  YOROZU_API_KEY=fake \
  node "$ROOT/packages/runtime/dist/serve.js" --direct-provider >"$WORK/sidecar2.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/sidecar2.log" "^PAIR " "the second pairing string"
PAIR2=$(grep -m1 '^PAIR ' "$WORK/sidecar2.log" | cut -c6-)
# Host identity comes from the authenticated encryption key, never the relay or display name.
HOST1=$(node --input-type=module -e 'console.log(new URL(process.argv[1]).searchParams.get("key"))' "$PAIR")
HOST2=$(node --input-type=module -e 'console.log(new URL(process.argv[1]).searchParams.get("key"))' "$PAIR2")
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuPairSecond "$PAIR2" -yorozuSend "hi both hosts" >"$WORK/app4.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app4.log" "YOROZU-E2E-HOSTS 2" "both hosts in the client" 45
wait_for "$WORK/app4.log" "YOROZU-E2E-DRAFT-REPLY $REPLY" "a fresh reply from the first host" 45
wait_for "$WORK/app4.log" "YOROZU-E2E-DRAFT-REPLY $SECOND_REPLY" "a fresh reply from the second host" 45
wait_for "$WORK/app4.log" "YOROZU-E2E-HOST-REPLY \[$HOST1\].*$REPLY" "the first host's reply" 45
wait_for "$WORK/app4.log" "YOROZU-E2E-HOST-REPLY \[$HOST2\].*$SECOND_REPLY" "the second host's reply" 45
wait_for "$WORK/app4.log" "YOROZU-E2E-MERGED-HOSTS 2" "both hosts in the combined thread list" 45
xcrun simctl io "$UDID" screenshot "$WORK/two-hosts.png" >/dev/null

say "removing only the first host and sending through the survivor"
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
  -yorozuRemoveHost "$HOST1" -yorozuSend "hi surviving host" >"$WORK/app5.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/app5.log" "YOROZU-E2E-REMOVED \[$HOST1\] remaining=1" "isolated host removal" 45
wait_for "$WORK/app5.log" "YOROZU-E2E-DRAFT-REPLY $SECOND_REPLY" "a fresh reply after removal" 45
wait_for "$WORK/app5.log" "YOROZU-E2E-HOST-REPLY \[$HOST2\].*$SECOND_REPLY" "the surviving host's reply" 45
if grep -q "YOROZU-E2E-HOST-REPLY \[$HOST1\]" "$WORK/app5.log"; then
  echo "removed host received activity" >&2
  exit 1
fi

say "PASS — the phone received:"
grep -m2 'YOROZU-E2E-REPLY' "$WORK/app.log"
grep -m1 'YOROZU-E2E-TOOL' "$WORK/app.log"
grep -m1 'YOROZU-E2E-REPLY' "$WORK/app2.log"
grep -m1 'YOROZU-E2E-REPLY' "$WORK/app3.log"
grep -m1 'YOROZU-E2E-DELIVERY' "$WORK/app-fault.log"
grep -m1 'YOROZU-E2E-FINAL .*finished after disconnect.*pending=0' "$WORK/app-recovered.log"
grep 'YOROZU-E2E-HOST-REPLY' "$WORK/app4.log"
grep 'YOROZU-E2E-REMOVED\|YOROZU-E2E-HOST-REPLY' "$WORK/app5.log"
grep '^STATE ' "$WORK/sidecar.log"
