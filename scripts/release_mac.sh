#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
REPO=${REPO:-izyuumi/yorozu}
# The one beta release: v<version>-beta.<build> (older ones: v<version>-beta).
beta_tag() {
    gh release list --repo "$REPO" --limit 100 --json tagName,isPrerelease -q '.[] | select(.isPrerelease) | .tagName' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-beta(\.[0-9]+)?$' | head -1 || true
}
beta_build() {
    gh release download "$1" --repo "$REPO" --pattern candidate.json --output - 2>/dev/null \
        | jq -r '.build | tonumber % 1000' || true
}

if [ "${1:-}" = "--promote" ]; then
    N=${2:-}
    case "$N" in ''|*[!0-9]*) echo "Usage: scripts/release_mac.sh --promote <checked beta build>" >&2; exit 64 ;; esac
    BETA=$(beta_tag)
    [ -n "$BETA" ] || { echo "There is no beta to promote" >&2; exit 1; }
    OLD=${BETA#v}; OLD=${OLD%%-*}
    if gh release view "v$OLD" --repo "$REPO" >/dev/null 2>&1; then
        echo "v$OLD is already released; nothing to promote."
        exit 0
    fi
    [ "$(beta_build "$BETA")" = "$N" ] || { echo "$BETA is not build $N: check it, then name it" >&2; exit 1; }
    FILES=$(mktemp -d)
    gh release download "$BETA" --repo "$REPO" --dir "$FILES"
    sed -i '' "s|/releases/download/$BETA/|/releases/download/v$OLD/|" "$FILES/appcast.xml"
    SHA=$(jq -r .source_sha "$FILES/candidate.json")
    { echo "Yorozu $OLD ($N)."; echo; scripts/release_notes.sh "$SHA"; } > "$FILES.md"
    gh release create "v$OLD" --repo "$REPO" --target "$SHA" --latest --title "v$OLD" --notes-file "$FILES.md" "$FILES"/*
    gh release delete "$BETA" --repo "$REPO" --cleanup-tag --yes
    echo "Published v$OLD. Submit the iOS build for $OLD to the App Store in App Store Connect."
    exit 0
fi

PUBLISH=0; [ "${1:-}" = "--publish" ] && PUBLISH=1
VERSION=${VERSION:-$(scripts/version.sh)}
BETA=$(beta_tag)
if [ -z "${BUILD:-}" ]; then
    case "$BETA" in "v$VERSION-beta"*) previous=$(beta_build "$BETA") ;; *) previous=0 ;; esac
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
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS -configuration Release \
    -destination 'platform=macOS' -derivedDataPath .build/xcode-release -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -quiet MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUNDLE_VERSION" \
    YOROZU_BUILD="$BUILD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_ENTITLEMENTS=Resources/MacHardenedRuntime.entitlements CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
ditto .build/xcode-release/Build/Products/Release/YorozuIOS.app "$APP"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$APP"; do
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$IDENTITY" "$item"
done
codesign --verify --deep --strict "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = to.yumi.yorozu ] \
    || { echo "The Mac app must be to.yumi.yorozu, the id Sparkle updates" >&2; exit 1; }
[ -f "$APP/Contents/Resources/openclaw-channel/openclaw.plugin.json" ] \
    || { echo "The OpenClaw plugin is missing from the bundle" >&2; exit 1; }

STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Yorozu -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$APP"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
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
    [ -z "$BETA" ] || gh release delete "$BETA" --repo "$REPO" --cleanup-tag --yes
    gh release create "$TAG" --repo "$REPO" --target "$SOURCE_SHA" --prerelease --latest=false --title "$TAG" \
        --notes-file "$DIST/notes.md" "$DMG" "$DIST/appcast.xml" "$DIST/candidate.json"
    echo "Published $TAG."
    scripts/release_pr.sh "$VERSION" "$BUILD" "$SOURCE_SHA"
fi
