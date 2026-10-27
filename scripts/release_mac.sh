#!/bin/sh
# Builds the Mac release into dist/: Yorozu.dmg (Developer ID signed, notarized, stapled), appcast.xml (Sparkle, EdDSA
# signed) and candidate.json, the assets of a v<version>-beta.<build> GitHub prerelease. yorozu.yumi.to/beta and
# /beta/appcast.xml serve the newest release, prereleases included; /mac and /appcast.xml the latest stable one
# (apps/web). Stable is the last beta of a version, promoted unchanged when version.txt moves on (release-mac.yml).
#   scripts/release_mac.sh                      build only; BUILD=<n> sets the visible build, else the last beta's plus 1
#   scripts/release_mac.sh --publish            also publishes it as v<version>-beta.<build>, which Macs with beta
#                                               updates on install within the hour
#   scripts/release_mac.sh --promote <version>  republishes the last v<version>-beta.<n> as v<version>, the latest
#                                               release, which every Mac installs within the hour; release tags can be
#                                               neither moved nor deleted, so each version has one stable release
# Needs: the "Developer ID Application" identity; a notarytool keychain profile (NOTARY_PROFILE, default yorozu-notary);
# Sparkle's EdDSA key in the login Keychain, or SPARKLE_ED_KEY_FILE; gh signed in, for --publish and --promote.
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-izyuumi/yorozu}
# The highest n of the v<version>-beta.<n> releases, or nothing.
last_beta() {
    gh release list --repo "$REPO" --limit 1000 --json tagName -q '.[].tagName' \
        | sed -n "s/^v$(printf '%s' "$1" | sed 's/\./\\./g')-beta\.\([0-9]*\)\$/\1/p" | sort -n | tail -1
}

if [ "${1:-}" = "--promote" ]; then
    OLD=${2:?Usage: scripts/release_mac.sh --promote <version>}
    if gh release view "v$OLD" --repo "$REPO" >/dev/null 2>&1; then
        echo "v$OLD is already released; nothing to promote."
        exit 0
    fi
    N=$(last_beta "$OLD")
    [ -n "$N" ] || { echo "No v$OLD-beta.<n> release to promote" >&2; exit 1; }
    FILES=$(mktemp -d)
    gh release download "v$OLD-beta.$N" --repo "$REPO" --dir "$FILES"
    # The same DMG, appcast and candidate.json, so the appcast still points at the beta's DMG, which stays published.
    gh release create "v$OLD" --repo "$REPO" --target "$(jq -r .source_sha "$FILES/candidate.json")" --latest \
        --title "v$OLD" --notes "Yorozu $OLD ($N), promoted from v$OLD-beta.$N." "$FILES"/*
    echo "Published v$OLD. Submit the iOS build for $OLD to the App Store in App Store Connect."
    exit 0
fi

PUBLISH=0; [ "${1:-}" = "--publish" ] && PUBLISH=1
VERSION=$(tr -d '[:space:]' < version.txt)
if [ -z "${BUILD:-}" ]; then
    previous=$(last_beta "$VERSION")
    BUILD=$((${previous:-0} + 1))
fi
TAG="v$VERSION-beta.$BUILD"
BUNDLE_VERSION=$(scripts/build-number.sh "$VERSION" "$BUILD")
IDENTITY=${IDENTITY:-"Developer ID Application: Yumi Izumi (AN5KM8QGEF)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-yorozu-notary}
DIST=dist
APP="$DIST/Yorozu.app"
DMG="$DIST/Yorozu.dmg"
SOURCE_SHA=$(git rev-parse HEAD)

if [ "$PUBLISH" = 1 ] && [ -n "$(git status --porcelain)" ]; then
    echo "Refusing to publish from a dirty tree: candidate.json names the commit." >&2
    exit 1
fi

rm -rf "$DIST" && mkdir -p "$DIST"
tuist generate --no-open --path apps/ios
# The app's entitlements need a macOS provisioning profile that does not exist for to.yumi.yorozu (build_native.sh);
# Xcode signs the embedded Sparkle framework and its helpers with the same identity.
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS -configuration Release \
    -destination 'platform=macOS' -derivedDataPath .build/xcode-release -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -quiet MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUNDLE_VERSION" \
    YOROZU_BUILD="$BUILD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
ditto .build/xcode-release/Build/Products/Release/YorozuIOS.app "$APP"
# Xcode signs Sparkle.framework but not its nested helpers, which keep Sparkle's own signature: notarization rejects
# them. Sign them inside out (Sparkle's "Sandboxing" guide), then the framework and the app again.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$APP"; do
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$IDENTITY" "$item"
done
codesign --verify --deep --strict "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = to.yumi.yorozu ] \
    || { echo "The Mac app must be to.yumi.yorozu, or Sparkle cannot replace 0.5" >&2; exit 1; }
[ -f "$APP/Contents/Resources/openclaw-channel/openclaw.plugin.json" ] \
    || { echo "The OpenClaw plugin is missing from the bundle" >&2; exit 1; }

STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Yorozu -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$APP"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
# Apple's notary service fails now and then; three tries, as Home Assistant does.
for try in 1 2 3; do
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait && break
    [ "$try" = 3 ] && exit 1
    sleep 60
done
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

GENERATE=$(find .build/xcode-packages/artifacts -name generate_appcast -type f -perm -u+x | head -1)
[ -n "$GENERATE" ] || { echo "Sparkle's generate_appcast is missing from .build/xcode-packages" >&2; exit 1; }
set -- --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/"
[ -z "${SPARKLE_ED_KEY_FILE:-}" ] || set -- "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"
"$GENERATE" "$@" "$DIST"
grep -q "<sparkle:version>$BUNDLE_VERSION</sparkle:version>" "$DIST/appcast.xml" \
    || { echo "appcast.xml does not carry build $BUNDLE_VERSION" >&2; exit 1; }

cat > "$DIST/candidate.json" <<JSON
{"schema":1,"tag":"$TAG","version":"$VERSION","build":"$BUNDLE_VERSION","source_branch":"main","source_sha":"$SOURCE_SHA","mac":{"asset":"Yorozu.dmg"}}
JSON
echo "Built Yorozu $VERSION ($BUILD), CFBundleVersion $BUNDLE_VERSION, in $DIST/"

if [ "$PUBLISH" = 1 ]; then
    gh release create "$TAG" --repo "$REPO" --target "$SOURCE_SHA" --prerelease --latest=false --title "$TAG" \
        --notes "Yorozu $VERSION ($BUILD), beta." "$DMG" "$DIST/appcast.xml" "$DIST/candidate.json"
    echo "Published $TAG."
fi
