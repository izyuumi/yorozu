#!/bin/sh
# Builds the Mac release into dist/: Yorozu.dmg (Developer ID signed, notarized, stapled), appcast.xml (Sparkle, EdDSA
# signed) and candidate.json, the assets of the v<version>-beta GitHub prerelease, which each build replaces.
# yorozu.yumi.to/beta and /beta/appcast.xml serve the newest release, prereleases included; /mac and /appcast.xml the
# latest stable one (apps/web). Stable is the beta the owner checked, promoted unchanged when version.txt moves on
# (release-mac.yml). Release notes come from the Conventional Commits since the last stable release (release_notes.sh).
#   scripts/release_mac.sh                      build only; BUILD=<n> sets the visible build, else the beta's plus 1
#   scripts/release_mac.sh --publish            also publishes it as v<version>-beta, replacing the last beta, which
#                                               Macs with beta updates on install within the hour
#   scripts/release_mac.sh --promote <version> <build>
#                                               republishes v<version>-beta, if it is still that build, as
#                                               v<version>, the latest release, which every Mac installs within the
#                                               hour; stable tags can be neither moved nor deleted, so each version
#                                               has one stable release
# Needs: the "Developer ID Application" identity; a notarytool keychain profile (NOTARY_PROFILE, default yorozu-notary);
# Sparkle's EdDSA key in the login Keychain, or SPARKLE_ED_KEY_FILE; gh signed in, for --publish and --promote.
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-izyuumi/yorozu}
# The visible build of the v<version>-beta release, or nothing.
beta_build() {
    gh release download "v$1-beta" --repo "$REPO" --pattern candidate.json --output - 2>/dev/null \
        | jq -r '.build | tonumber % 1000' || true
}

if [ "${1:-}" = "--promote" ]; then
    OLD=${2:?Usage: scripts/release_mac.sh --promote <version> <build>}
    if gh release view "v$OLD" --repo "$REPO" >/dev/null 2>&1; then
        echo "v$OLD is already released; nothing to promote."
        exit 0
    fi
    # The build the owner checked, named in the bump PR: a later merge may have replaced it with a newer, unchecked one.
    N=${3:-}
    case "$N" in ''|*[!0-9]*) echo "Name the checked build of v$OLD-beta to promote (got '$N')" >&2; exit 1 ;; esac
    BETA=$(beta_build "$OLD")
    [ "$BETA" = "$N" ] || { echo "v$OLD-beta is build ${BETA:-missing}, not the checked $N: check it, then name it" >&2; exit 1; }
    FILES=$(mktemp -d)
    gh release download "v$OLD-beta" --repo "$REPO" --dir "$FILES"
    # The same DMG and signature; the appcast points at this release's copy, so the beta can go.
    sed -i '' "s|/releases/download/v$OLD-beta/|/releases/download/v$OLD/|" "$FILES/appcast.xml"
    SHA=$(jq -r .source_sha "$FILES/candidate.json")
    { echo "Yorozu $OLD ($N)."; echo; scripts/release_notes.sh "$SHA"; } > "$FILES.md"
    gh release create "v$OLD" --repo "$REPO" --target "$SHA" --latest --title "v$OLD" --notes-file "$FILES.md" "$FILES"/*
    echo "Published v$OLD. Submit the iOS build for $OLD to the App Store in App Store Connect."
    exit 0
fi

PUBLISH=0; [ "${1:-}" = "--publish" ] && PUBLISH=1
VERSION=$(tr -d '[:space:]' < version.txt)
if [ -z "${BUILD:-}" ]; then
    previous=$(beta_build "$VERSION")
    BUILD=$((${previous:-0} + 1))
fi
TAG="v$VERSION-beta"
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
    { echo "Yorozu $VERSION ($BUILD), beta."; echo; scripts/release_notes.sh "$SOURCE_SHA"; } > "$DIST/notes.md"
    # One beta per version: the new build replaces the last one, tag included (the tag ruleset leaves *-beta alone).
    gh release delete "$TAG" --repo "$REPO" --cleanup-tag --yes 2>/dev/null || true
    gh release create "$TAG" --repo "$REPO" --target "$SOURCE_SHA" --prerelease --latest=false --title "$TAG" \
        --notes-file "$DIST/notes.md" "$DMG" "$DIST/appcast.xml" "$DIST/candidate.json"
    echo "Published $TAG."
fi
