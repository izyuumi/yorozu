#!/bin/sh
# Stage only. Never installs, registers, launches or changes permissions.
set -eu
cd "$(dirname "$0")/.."
# Match scripts/build-mac.sh. This is a public identity name, not key material.
IDENTITY=${IDENTITY:-"Developer ID Application: Yumi Izumi (AN5KM8QGEF)"}
[ -x target/release/yorozu-computer-use-helper ] || { echo 'Build the release helper first' >&2; exit 1; }
app=target/mac-stage/YorozuComputerUseHelper.app
[ ! -e "$app" ] || { echo 'Stage already exists; use a reviewed fresh build directory' >&2; exit 1; }
mkdir -p "$app/Contents/MacOS"
cp mac/Info.plist "$app/Contents/Info.plist"
cp target/release/yorozu-computer-use-helper "$app/Contents/MacOS/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$app"
codesign --verify --strict --verbose=2 "$app"
codesign -d -r- "$app"
printf '%s\n' "$app"
