#!/bin/sh
# Builds the Mac release into dist/: Yorozu.dmg (Developer ID signed, notarized, stapled), appcast.xml (Sparkle, EdDSA
# signed) and candidate.json, the assets of the v<version> GitHub release that yorozu.yumi.to/appcast.xml and /mac serve
# (releases/latest; main's apps/web). docs/upgrade-from-0.5.md has the plan.
#   scripts/release_mac.sh             build only; BUILD=<n> sets the visible build, else the published one plus 1
#   scripts/release_mac.sh --publish   also replaces the v<version> release and makes it the latest, which every Mac
#                                      installs within the hour; it cannot be taken back
# Needs: the "Developer ID Application" identity; a notarytool keychain profile (NOTARY_PROFILE, default yorozu-notary);
# Sparkle's EdDSA key in the login Keychain, or SPARKLE_ED_KEY_FILE; gh signed in, for --publish.
set -eu
cd "$(dirname "$0")/.."
PUBLISH=0; [ "${1:-}" = "--publish" ] && PUBLISH=1
VERSION=$(tr -d '[:space:]' < version.txt)
TAG="v$VERSION"
REPO=${REPO:-izyuumi/yorozu}
# One v<version> release per version, replaced by each build (as on main before): the next build follows the one
# it replaces.
if [ -z "${BUILD:-}" ]; then
    previous=$(gh release download "$TAG" --repo "$REPO" --pattern candidate.json --output - 2>/dev/null | jq -r .build) || previous=
    base=$(($(scripts/build-number.sh "$VERSION" 1) - 1))
    case "$previous" in ''|*[!0-9]*) BUILD=1 ;; *) BUILD=$((previous > base ? previous - base + 1 : 1)) ;; esac
fi
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
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
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
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag
    gh release create "$TAG" --repo "$REPO" --target "$SOURCE_SHA" --latest --title "$TAG" \
        --notes "Yorozu $VERSION ($BUILD)." "$DMG" "$DIST/appcast.xml" "$DIST/candidate.json"
    echo "Published $TAG. Assign the iOS build to the TestFlight groups now (docs/upgrade-from-0.5.md#release-order)."
fi
