#!/bin/bash
#
# Screenshots of the Mac chat, one showcase scene per picture, into docs/screens.
#
# A test helper only — nothing here ships. It is the Mac counterpart of the phone's
# `-yorozuShowcase` screenshots: the app is launched once per scene with the state that scene
# needs seeded on this machine alone (see apps/mac/Sources/YorozuMac/Showcase.swift), the chat
# window is captured by its own window number, and the app is quit again.
#
# Everything runs against a throwaway state directory, so the Yorozu you actually use — its
# threads, its pairing and its socket in ~/Library/Application Support/Yorozu — is never
# touched. The runtime is the one built in this checkout, and the relay is the hosted default.
#
# `screencapture` needs Screen Recording for whatever runs this script. The window number comes
# from the app itself, which is the one thing in the picture that reliably knows it.
#
# Usage: scripts/mac-screens.sh [scene ...]     — all of them when none are named.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/docs/screens"
APP="$ROOT/apps/mac/.build/Yorozu.app"
BIN="$APP/Contents/MacOS/Yorozu"
STATE=${STATE:-/tmp/yorozu-mac-screens}
RELAY=${YOROZU_RELAY_URL:-wss://relay.yumi.to}
WIDTH=${WIDTH:-900}
HEIGHT=${HEIGHT:-620}

# One line per picture: <file> <launch arguments…>, where <file> is the name in docs/screens
# without its extension. The scene names inside the arguments are the phone's, so the two sets
# of screenshots line up.
SCENES=(
  "43-mac-threads      -yorozuShowcase threads"
  "43-mac-chat         -yorozuShowcase threads -yorozuScene plain"
  "43-mac-search       -yorozuShowcase threads -yorozuScene search"
  "43-mac-reply        -yorozuShowcase threads -yorozuScene reply"
  "43-mac-dictation    -yorozuShowcase threads -yorozuScene dictation"
  "43-mac-approval     -yorozuShowcase approval"
  "43-mac-model        -yorozuShowcase model"
  "43-mac-tools        -yorozuShowcase tools"
  "43-mac-link         -yorozuShowcase link"
  "43-mac-queued       -yorozuShowcase queued"
  "43-mac-light        -yorozuShowcase threads -yorozuScene plain -yorozuAppearance light"
  # v1.5 approval hardening: the structured card and the three grants, the rule editor the
  # third of them opens, the proposal after repeated approvals, and an exact batch.
  "45-card             -yorozuShowcase card"
  "45-rule-editor      -yorozuShowcase rule-editor"
  "45-proposal         -yorozuShowcase proposal"
  "45-batch            -yorozuShowcase batch"
)

say() { printf '\n==> %s\n' "$1"; }

stop_app() {
  pkill -f "$BIN" 2>/dev/null || true
  # Waits for it to actually go: the next launch binds the same socket.
  for _ in $(seq 20); do
    pgrep -f "$BIN" >/dev/null || return 0
    sleep 0.5
  done
  pkill -9 -f "$BIN" 2>/dev/null || true
}
trap stop_app EXIT

say "building the runtime and the app bundle"
CI=true pnpm -C "$ROOT" -r build >/dev/null
env -u SDKROOT sh "$ROOT/scripts/dev-bundle.sh" >/dev/null

taken=0
mkdir -p "$OUT"
rm -rf "$STATE"
mkdir -p "$STATE"

for scene in "${SCENES[@]}"; do
  read -r name args <<<"$scene"
  # Named scenes only, when any were named. The header's usage line has always promised this.
  if [ "$#" -gt 0 ]; then
    wanted=""
    for pick in "$@"; do [ "$pick" = "$name" ] && wanted=yes; done
    [ -n "$wanted" ] || continue
  fi
  taken=$((taken + 1))
  say "$name"
  stop_app
  log="$STATE/$name.log"
  # A fresh, throwaway state directory and this checkout's runtime. `-onboardingCompleted YES`
  # goes in the defaults *argument* domain, which is volatile: the wizard does not cover the
  # window and the real preference is left alone.
  YOROZU_STATE_DIR="$STATE" \
    YOROZU_RELAY_URL="$RELAY" \
    YOROZU_RUNTIME_CMD="node '$ROOT/packages/runtime/dist/serve.js'" \
    "$BIN" $args -yorozuWindowSize "${WIDTH}x${HEIGHT}" -onboardingCompleted YES >"$log" 2>&1 &
  # Off the job table, so quitting it at the end of the scene is not announced as a signal.
  disown

  # The app prints its own window number once the chat window has one; see
  # ``WindowNumberReporter``. Nothing here depends on a fixed sleep.
  window=""
  for _ in $(seq 40); do
    window=$(sed -n 's/^YOROZU-MAC window=//p' "$log" | head -1)
    [ -n "$window" ] && break
    sleep 0.5
  done
  if [ -z "$window" ]; then
    echo "no window from the app for scene $name; log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  # The fixed frame every picture shares is set by the app itself, from the
  # `-yorozuWindowSize` argument above — see ``WindowNumberReporter``. It used to be done from
  # here with System Events, which needs Accessibility for whatever runs this script and fails
  # silently without it, so the set came out at whatever size the window happened to remember.

  # A moment for the first frame to settle — the window number is printed when the window
  # exists, which is a little before the sidebar and the transcript have drawn into it.
  sleep 2
  screencapture -o -x -l "$window" "$OUT/$name.png"
  echo "$OUT/$name.png"
done

stop_app
say "done — $taken pictures in docs/screens"
