#!/bin/bash
#
# Screenshots of the phone's chat, one showcase scene per picture, into docs/screens.
#
# A test helper only — nothing here ships. It is the phone counterpart of
# `scripts/mac-screens.sh`: the app is launched once per scene with the state that scene needs
# seeded on the simulator alone (see apps/ios/Sources/YorozuIOS/E2EHarness.swift) and the
# device's screen is captured.
#
# Unlike the Mac, the phone only reaches its showcase once it is paired — the seeding hangs off
# ``ChatModel``, which `Session` only builds for a pairing. So this starts the same throwaway
# relay and sidecar `apps/ios/e2e/run.sh` does, purely to mint a pairing string to inject.
#
# Usage: scripts/ios-screens.sh [scene ...]     — all of them when none are named.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IOS="$ROOT/apps/ios"
OUT=${OUT:-"$ROOT/docs/screens"}
BUNDLE_ID=to.yumi.yorozu.ios
DEVICE_TYPE=${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
RELAY_PORT=${RELAY_PORT:-8793}
PROVIDER_PORT=${PROVIDER_PORT:-8797}

WORK="$IOS/e2e/.screens"
# Agent-owned test output only. Preserve failed artifacts until next explicit run.
if [ -d "$WORK" ]; then
  trash "$WORK"
fi
mkdir -p "$WORK"
UDID=""
PIDS=()

# One line per picture: <file> <launch arguments…>, where <file> is the name in docs/screens
# without its extension.
SCENES=(
  "54-pairing          -yorozuShowcase pairing"
  "54-pairing-manual   -yorozuShowcase pairing-manual"
  "54-pairing-error    -yorozuShowcase pairing-error"
  "t33-thread-list   -yorozuShowcase threads"
  "55-new-thread     -yorozuShowcase new-thread"
  "32-chat-empty-state -yorozuShowcase threads -yorozuScene empty"
  "32-chat-markdown  -yorozuShowcase chat"
  "37-tool-rows      -yorozuShowcase activity"
  "38-approval-card  -yorozuShowcase approval"
  "39-search         -yorozuShowcase threads -yorozuScene search"
  "54-thread-search  -yorozuShowcase threads -yorozuScene thread-search"
  "39-reply          -yorozuShowcase threads -yorozuScene reply"
  "40-queued         -yorozuShowcase queued"
  "40-link-preview   -yorozuShowcase link"
  "42-model-menu     -yorozuShowcase model"
  "41-share-sheet    -yorozuShowcase share"
  "54-settings       -yorozuShowcase settings"
  "45-card           -yorozuShowcase card"
  "45-rule-editor    -yorozuShowcase rule-editor"
  "45-proposal       -yorozuShowcase proposal"
  "45-question       -yorozuShowcase question"
  "45-progress       -yorozuShowcase progress"
  "45-batch          -yorozuShowcase batch"
  "53-images-grid    -yorozuShowcase images"
  "53-images-viewer  -yorozuShowcase images-viewer"
)

cleanup() {
  local status=$?
  [ "$status" -ne 0 ] && printf '\n==> FAILED — logs kept in %s\n' "$WORK" >&2
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

say "starting relay and sidecar, for a pairing string to inject"
PORT=$RELAY_PORT node "$ROOT/apps/relay/dist/index.js" >"$WORK/relay.log" 2>&1 &
PIDS+=($!)
PORT=$PROVIDER_PORT node "$IOS/e2e/fake-provider.mjs" >"$WORK/provider.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/relay.log" "relay listening" "the relay"

# Only the fake provider: left to seed itself the sidecar would pick up whatever CLIs this
# machine has, and a screenshot run has no business calling them.
mkdir -p "$WORK/state"
cat >"$WORK/state/providers.json" <<JSON
[{ "id": "openai", "kind": "openai-compat", "label": "Fake", "baseUrl": "http://127.0.0.1:$PROVIDER_PORT", "models": ["fake"], "enabled": true }]
JSON

YOROZU_RELAY_URL="ws://127.0.0.1:$RELAY_PORT" \
  YOROZU_STATE_DIR="$WORK/state" \
  YOROZU_BASE_URL="http://127.0.0.1:$PROVIDER_PORT" \
  YOROZU_API_KEY=fake \
  node "$ROOT/packages/runtime/dist/serve.js" >"$WORK/sidecar.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/sidecar.log" "^PAIR " "the pairing string"
PAIR=$(grep -m1 '^PAIR ' "$WORK/sidecar.log" | cut -c6-)

say "generating and building the app"
tuist generate --no-open --path "$IOS" >/dev/null
UDID=$(xcrun simctl create yorozu-screens "$DEVICE_TYPE")
# Signed, like the e2e run: ad-hoc simulator signing is what gives the app its
# application-identifier entitlement, without which the Keychain fails with -34018.
xcodebuild build \
  -workspace "$IOS/Yorozu.xcworkspace" \
  -scheme YorozuIOS \
  -destination "id=$UDID" \
  -derivedDataPath "$WORK/dd" >"$WORK/xcodebuild.log" 2>&1 ||
  { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/YorozuIOS.app"
# A clean status bar, so the pictures in a set do not each carry a different clock and battery.
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 2>/dev/null || true

# First launch on a newly created iOS 27 simulator can return to SpringBoard while launch
# services finishes registering embedded extensions. Warm once before evidence capture so the
# first named scene is held to the same standard as every later one.
xcrun simctl launch "$UDID" "$BUNDLE_ID" -yorozuPair "$PAIR" -yorozuShowcase threads >/dev/null 2>&1 || true
sleep 8
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

taken=0
mkdir -p "$OUT"
for scene in "${SCENES[@]}"; do
  read -r name args <<<"$scene"
  # Named scenes only, when any were named.
  if [ "$#" -gt 0 ]; then
    wanted=""
    for pick in "$@"; do [ "$pick" = "$name" ] && wanted=yes; done
    [ -n "$wanted" ] || continue
  fi
  taken=$((taken + 1))
  say "$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  log="$WORK/$name.log"
  # A console PTY sometimes becomes the foreground process instead of the app and leaves the
  # simulator on a blank transition frame. A normal launch returns the app pid immediately and
  # keeps SpringBoard focused on the scene we are about to capture.
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -yorozuPair "$PAIR" $args >"$log" 2>&1
  # Pairing owns the root view. The first launch of a fresh simulator can spend several seconds
  # registering with the throwaway relay before the seeded root swaps in.
  sleep 12
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  echo "$OUT/$name.png"
done

say "done — $taken pictures in docs/screens"
