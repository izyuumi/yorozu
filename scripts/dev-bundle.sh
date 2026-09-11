#!/bin/sh
# Wrap the `swift build` product in a minimal .app bundle and ad-hoc sign it.
#
# TCC keys grants by bundle ID and code signature. A bare `swift run` binary has neither, so
# every rebuild looks like a new app and every permission has to be granted again. Running
# the app out of this bundle gives it a stable identity (to.yumi.yorozu) and grants stick.
set -eu
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-debug}
APP=${APP:-apps/mac/.build/Yorozu.app}

swift build --package-path apps/mac -c "$CONFIG"
BIN="$(swift build --package-path apps/mac -c "$CONFIG" --show-bin-path)/YorozuMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Yorozu"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Yorozu</string>
  <key>CFBundleIdentifier</key><string>to.yumi.yorozu</string>
  <key>CFBundleName</key><string>Yorozu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Yorozu drives Calendar, Mail, Reminders and System Events on your behalf.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Yorozu reads and writes your calendar when you ask it to.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Yorozu reads and writes your reminders when you ask it to.</string>
  <key>NSSystemAdministrationUsageDescription</key>
  <string>Yorozu needs Full Disk Access to read and write files anywhere you can.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier to.yumi.yorozu "$APP"
echo "$APP"
