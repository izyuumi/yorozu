#!/bin/sh
# Generates the project with Tuist, builds Yorozu.app, replaces build/Yorozu.app in place (never a second app).
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/build/Yorozu.app"
if [ -f "$APP/Contents/MacOS/Yorozu" ] && /usr/sbin/lsof -t "$APP/Contents/MacOS/Yorozu" >/dev/null 2>&1; then
    echo "Refusing to replace a running app. Quit build/Yorozu.app first." >&2
    exit 3
fi
mkdir -p build
tuist generate --no-open --path apps/mac
env -u SDKROOT xcodebuild -workspace apps/mac/Yorozu.xcworkspace -scheme Yorozu -configuration Release \
    -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -quiet CURRENT_PROJECT_VERSION="${BUILD:-1}" build
rm -rf "$APP"
ditto .build/xcode/Build/Products/Release/Yorozu.app "$APP"
codesign --verify --strict "$APP"
shasum -a 256 "$APP/Contents/MacOS/Yorozu" > build/native-sha256.txt
printf '\nNative app: %s\n' "$APP"
