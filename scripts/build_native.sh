#!/bin/sh
# Generates the project with Tuist, builds Yorozu.app and replaces build/Yorozu.app in place (never a second app).
# --restart: if the dev app is running, quit it after a successful build, swap the bundle and relaunch it.
# Only this checkout's build/Yorozu.app is touched, never /Applications/Yorozu.app (same bundle id).
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/build/Yorozu.app"
RESTART=0; [ "${1:-}" = "--restart" ] && RESTART=1
running() { pgrep -f "$APP/Contents/MacOS/Yorozu" || true; }
if [ -n "$(running)" ] && [ "$RESTART" = 0 ]; then
    echo "Refusing to replace a running app. Quit build/Yorozu.app first, or pass --restart." >&2
    exit 3
fi
mkdir -p build
tuist generate --no-open --path apps/mac
# Pass the version explicitly: Tuist caches the manifest, so a version.txt change alone may not reach the build.
env -u SDKROOT xcodebuild -workspace apps/mac/Yorozu.xcworkspace -scheme Yorozu -configuration Release \
    -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -quiet MARKETING_VERSION="$(tr -d '[:space:]' < version.txt)" CURRENT_PROJECT_VERSION="${BUILD:-1}" build
WAS_RUNNING=0
for PID in $(running); do
    WAS_RUNNING=1; kill -TERM "$PID"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
done
rm -rf "$APP"
ditto .build/xcode/Build/Products/Release/Yorozu.app "$APP"
codesign --verify --strict "$APP"
shasum -a 256 "$APP/Contents/MacOS/Yorozu" > build/native-sha256.txt
# LaunchServices starts it with the user's session environment, not this shell's.
if [ "$RESTART" = 1 ] || [ "$WAS_RUNNING" = 1 ]; then open -n "$APP"; fi
printf '\nNative app: %s\n' "$APP"
