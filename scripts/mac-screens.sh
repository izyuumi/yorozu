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

# One line per picture: <name> <launch arguments…>. The scene names are the phone's, so the two
# sets of screenshots line up.
SCENES=(
  "threads      -yorozuShowcase threads"
  "chat         -yorozuShowcase threads -yorozuScene plain"
  "search       -yorozuShowcase threads -yorozuScene search"
  "reply        -yorozuShowcase threads -yorozuScene reply"
  "dictation    -yorozuShowcase threads -yorozuScene dictation"
  "approval     -yorozuShowcase approval"
  "model        -yorozuShowcase model"
  "tools        -yorozuShowcase tools"
  "link         -yorozuShowcase link"
  "queued       -yorozuShowcase queued"
  "light        -yorozuShowcase threads -yorozuScene plain -yorozuAppearance light"
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

mkdir -p "$OUT"
rm -rf "$STATE"
mkdir -p "$STATE"

for scene in "${SCENES[@]}"; do
  read -r name args <<<"$scene"
  say "$name"
  stop_app
  log="$STATE/$name.log"
  # A fresh, throwaway state directory and this checkout's runtime. `-onboardingCompleted YES`
  # goes in the defaults *argument* domain, which is volatile: the wizard does not cover the
  # window and the real preference is left alone.
  YOROZU_STATE_DIR="$STATE" \
    YOROZU_RELAY_URL="$RELAY" \
    YOROZU_RUNTIME_CMD="node '$ROOT/packages/runtime/dist/serve.js'" \
    "$BIN" $args -onboardingCompleted YES >"$log" 2>&1 &
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
  # A fixed size for every picture. The app remembers where its window was last put, which is
  # right for a person and wrong for a set of screenshots meant to be compared with each other.
  osascript - "$WIDTH" "$HEIGHT" >/dev/null 2>&1 <<'AS' || true
on run argv
  tell application "System Events" to tell (first process whose bundle identifier is "to.yumi.yorozu")
    tell window 1
      set its position to {140, 120}
      set its size to {(item 1 of argv) as integer, (item 2 of argv) as integer}
    end tell
  end tell
end run
AS

  # A moment for the first frame to settle — the window number is printed when the window
  # exists, which is a little before the sidebar and the transcript have drawn into it.
  sleep 2
  screencapture -o -x -l "$window" "$OUT/43-mac-$name.png"
  echo "$OUT/43-mac-$name.png"
done

stop_app
say "done — $(find "$OUT" -name '43-mac-*.png' | wc -l | tr -d ' ') pictures in docs/screens"
