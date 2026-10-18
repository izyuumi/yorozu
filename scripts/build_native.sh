#!/bin/sh
# Builds the client app's macOS destination (apps/ios, scheme YorozuIOS) and replaces /Applications/Yorozu.app in place:
# the one Yorozu on this Mac (owner, 2026-10-12).
# --restart: if the app is running, quit it after a successful build, swap the bundle and relaunch it.
# Signing: Developer ID with hardened runtime when that identity is in the Keychain, else ad hoc. Either way without the
# app's entitlements (push, associated domains, Keychain and App Groups), which on macOS need a provisioning profile that
# does not exist for the Mac id to.yumi.yorozu; the client keeps its keys in the login Keychain without them.
set -eu
cd "$(dirname "$0")/.."
APP="/Applications/Yorozu.app"
RESTART=0; [ "${1:-}" = "--restart" ] && RESTART=1
# Any executable in the bundle: the client's, or the old host's it replaces.
running() { pgrep -f "$APP/Contents/MacOS/" || true; }
if [ -n "$(running)" ] && [ "$RESTART" = 0 ]; then
    echo "Refusing to replace a running app. Quit Yorozu first, or pass --restart." >&2
    exit 3
fi
if security find-identity -v -p codesigning | grep -q '"Developer ID Application'; then
    set -- CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp
else
    echo "No Developer ID Application identity: signing ad hoc." >&2
    set -- CODE_SIGN_IDENTITY=-
fi
VERSION=$(tr -d '[:space:]' < version.txt)
BUILD=${BUILD:-1}
mkdir -p build
tuist generate --no-open --path apps/ios
# Pass the version explicitly: Tuist caches the manifest, so a version.txt change alone may not reach the build.
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS -configuration Release \
    -destination 'platform=macOS' -derivedDataPath .build/xcode-native -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -quiet MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(scripts/build-number.sh "$VERSION" "$BUILD")" YOROZU_BUILD="$BUILD" \
    CODE_SIGN_STYLE=Manual "$@" CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
WAS_RUNNING=0
for PID in $(running); do
    WAS_RUNNING=1; kill -TERM "$PID"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
done
rm -rf "$APP"
ditto .build/xcode-native/Build/Products/Release/YorozuIOS.app "$APP"
codesign --verify --strict "$APP"
shasum -a 256 "$APP/Contents/MacOS/YorozuIOS" > build/native-sha256.txt
# LaunchServices starts it with the user's session environment, not this shell's.
if [ "$RESTART" = 1 ] || [ "$WAS_RUNNING" = 1 ]; then open -n "$APP"; fi
printf '\nNative app: %s\n' "$APP"
