#!/bin/sh
# Host the blind relay on this Mac as a LaunchAgent, so phones reach it over Tailscale.
#
# The relay is the one piece that has to be online whenever the phone is; a LaunchAgent
# with KeepAlive is the whole supervision story, and it holds no secrets to protect
# because the relay cannot read what it forwards. Docker is the alternative — see README.
set -eu
cd "$(dirname "$0")/.."

LABEL=to.yumi.yorozu.relay
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/yorozu-relay.log"
PORT=${PORT:-8787}
NODE=${NODE:-$(command -v node)}
ENTRY="$(pwd)/apps/relay/dist/index.js"

[ -f "$ENTRY" ] || {
  echo "relay not built: run pnpm --filter @yorozu/relay build" >&2
  exit 1
}

# The relay binds every interface (ws's default), which is what makes the Tailscale
# address work; Tailscale, not the relay, is what keeps it off the public internet.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$ENTRY</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PORT</key><string>$PORT</string></dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

# bootout first: bootstrap on an already-loaded label is an error, not an update.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "$PLIST"
echo "logs: $LOG"
