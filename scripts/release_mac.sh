#!/bin/sh
# Builds a Mac release the way v1 shipped them, so v1's Sparkle updates to it and it keeps updating (owner, 2026-10-11):
# a Developer ID-signed, notarized and stapled Yorozu.dmg and an appcast.xml with one item signed with v1's EdDSA key.
#   BUILD=<n> scripts/release_mac.sh beta|stable
# BUILD must be above every published build: v1's stable is 293 and its beta 10271, so v2 starts at 10272.
# Nothing is published. The output in build/release/<version>-<build>/ goes to a GitHub release (docs/release.md, Mac:
# publish), which is the owner's step: a "latest" release reaches every installed copy within the hour.
# Needs apps/mac/Signing.local.xcconfig (Developer ID), the `yorozu-notary` notarytool profile and the Sparkle EdDSA
# private key in the login Keychain (or SPARKLE_ED_KEY_FILE).
set -eu
cd "$(dirname "$0")/.."
CHANNEL=${1:-}
case "$CHANNEL" in beta|stable) ;; *) echo "usage: BUILD=<n> $0 beta|stable" >&2; exit 64 ;; esac
: "${BUILD:?BUILD is required, above every published build (v1 beta is 10271)}"
[ "$BUILD" -gt 10271 ] || { echo "BUILD must be above 10271, v1's last beta build." >&2; exit 65; }
[ -f apps/mac/Signing.local.xcconfig ] || { echo "apps/mac/Signing.local.xcconfig with the Developer ID identity is required." >&2; exit 1; }
xcrun notarytool history --keychain-profile yorozu-notary >/dev/null 2>&1 || { echo "The yorozu-notary notarytool profile is missing or unusable." >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < version.txt)
TAG=$([ "$CHANNEL" = beta ] && echo "v$VERSION-beta" || echo "v$VERSION")
OUT="$PWD/build/release/$VERSION-$BUILD"
APP="$PWD/.build/xcode-release/Build/Products/Release/Yorozu.app"
rm -rf "$OUT"; mkdir -p "$OUT"

tuist generate --no-open --path apps/mac
env -u SDKROOT xcodebuild -workspace apps/mac/Yorozu.xcworkspace -scheme Yorozu -configuration Release \
    -derivedDataPath .build/xcode-release -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation -quiet \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" YOROZU_FEED_URL="https://yorozu.yumi.to/appcast.xml" build
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Not signed with a Developer ID." >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "The app carries get-task-allow." >&2; exit 1; fi
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
# Sparkle's helpers ship with Sparkle's signature, which notarization refuses: re-sign them inside out with ours, as
# Sparkle documents, then the app itself with its entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements apps/mac/Yorozu.entitlements "$APP"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Yorozu.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Yorozu -srcfolder "$STAGE" -ov -format UDZO "$OUT/Yorozu.dmg" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/Yorozu.dmg"
xcrun notarytool submit "$OUT/Yorozu.dmg" --keychain-profile yorozu-notary --wait | tee "$OUT/notary.txt"
grep -q "status: Accepted" "$OUT/notary.txt" || { echo "Notarization was not accepted; see xcrun notarytool log <id> --keychain-profile yorozu-notary." >&2; exit 1; }
xcrun stapler staple "$OUT/Yorozu.dmg"
spctl --assess --type open --context context:primary-signature -v "$OUT/Yorozu.dmg"

# One item, as v1's release checks expect; beta items carry the beta channel, which only beta users read.
TOOLS="$PWD/.build/xcode-packages/artifacts/sparkle/Sparkle/bin"
set -- --download-url-prefix "https://github.com/izyuumi/yorozu/releases/download/$TAG/"
[ "$CHANNEL" = beta ] && set -- "$@" --channel beta
[ -n "${SPARKLE_ED_KEY_FILE:-}" ] && set -- "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"
"$TOOLS/generate_appcast" "$@" "$OUT"
grep -q 'sparkle:edSignature' "$OUT/appcast.xml" || { echo "appcast.xml has no EdDSA signature." >&2; exit 1; }
printf '{"schema":1,"source_branch":"projectx","source_sha":"%s","tag":"%s","version":"%s","build":%s,"mac":{"asset":"Yorozu.dmg"}}\n' \
    "$(git rev-parse HEAD)" "$TAG" "$VERSION" "$BUILD" > "$OUT/candidate.json"
printf '\nRelease %s (%s), %s, not published:\n%s\n' "$VERSION" "$BUILD" "$CHANNEL" "$OUT"
